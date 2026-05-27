;;; k8s-portforward.el --- TCP port-forward via the K8s API -*- lexical-binding: t -*-
;;
;; Status: **experimental**.  The wire protocol is implemented and the
;; local listener binds, but live verification against a running pod
;; has not yet succeeded — batch-mode emacs lacks the event loop
;; that would naturally drive the back-and-forth, and an interactive
;; smoke-test is the next step.  Use at your own risk; expect
;; debugging.
;;
;; `P' on a Pod row (or `M-x k8s-portforward') prompts for ports and
;; opens a local TCP listener that tunnels through the API server's
;; `/pods/<n>/portforward' WebSocket endpoint.  No `kubectl' CLI is
;; involved — eltainer's own WebSocket framing (from k8s-exec.el)
;; handles the wire protocol.
;;
;; Wire protocol (`Sec-WebSocket-Protocol: portforward.k8s.io'):
;; - For each forwarded port, the server allocates two channels:
;;   2*i (data) and 2*i+1 (error) where i is the index of the port in
;;   the `ports=' query string.
;; - The FIRST message on each channel is a 2-byte little-endian
;;   uint16 of the port number — an announcement we drop.
;; - After that, channel 2*i carries the bidirectional byte stream
;;   for port i, and 2*i+1 carries error text from the server.
;; - To send bytes upstream, prepend the channel byte to the payload
;;   and wrap in a WebSocket binary frame.

(require 'cl-lib)
(require 'k8s-api)
(require 'k8s-exec)                     ; WS framing primitives
(require 'k8s-marks)

(defgroup k8s-portforward nil
  "Port-forwarding into Kubernetes pods via the API."
  :group 'k8s
  :prefix "k8s-portforward-")

;;; ---------------------------------------------------------------------------
;;; Session struct + registry

(cl-defstruct (k8s-portforward-session
               (:constructor k8s-portforward-session--new)
               (:copier nil))
  conn             ; k8s-connection
  ns
  pod
  local-port
  remote-port
  server           ; the local-side TCP listener process
  ;; List of (CLIENT-PROC . WS-PROC) for every currently-open
  ;; connection through this listener.  WS lifecycle is bound to the
  ;; client; closing one closes the other.
  pairs
  created-at)

(defvar k8s-portforward--sessions nil
  "Alist (ID . SESSION) of every active port-forward in this Emacs.
The listing buffer reads this; the dashboard's `P' adds to it.")

(defvar k8s-portforward--next-id 1)

(defun k8s-portforward--register (sess)
  (let ((id (cl-incf k8s-portforward--next-id)))
    (push (cons id sess) k8s-portforward--sessions)
    id))

(defun k8s-portforward--unregister (id)
  (setq k8s-portforward--sessions
        (assq-delete-all id k8s-portforward--sessions)))

;;; ---------------------------------------------------------------------------
;;; WebSocket open + framing

(defun k8s-portforward--ws-path (ns pod port)
  "Return the WS URL path for forwarding PORT into NS/POD."
  (format "/api/v1/namespaces/%s/pods/%s/portforward?ports=%d"
          ns pod port))

(defun k8s-portforward--ws-headers (host ws-key token)
  "Return the HTTP/1.1 GET headers for the portforward WS handshake."
  (concat
   "Upgrade: websocket\r\n"
   "Connection: Upgrade\r\n"
   (format "Host: %s\r\n" host)
   (format "Sec-WebSocket-Key: %s\r\n" ws-key)
   "Sec-WebSocket-Version: 13\r\n"
   "Sec-WebSocket-Protocol: portforward.k8s.io\r\n"
   (when token (format "Authorization: Bearer %s\r\n" token))
   "User-Agent: eltainer/0.1\r\n"
   "\r\n"))

(defun k8s-portforward--encode-data (channel bytes)
  "Encode BYTES on CHANNEL as one WebSocket binary frame.
The first byte of the payload is CHANNEL; the rest is BYTES."
  (k8s-exec--encode-frame
   #x2                                  ; binary opcode
   (concat (unibyte-string channel) bytes)))

;;; ---------------------------------------------------------------------------
;;; Per-connection state
;;
;; A "pair" is one local TCP client connected through one WebSocket.
;; The WS does TLS termination, the WS process-filter routes incoming
;; bytes into the client process, and the client's process-filter
;; routes outbound bytes onto channel 0 of the WS.

(cl-defstruct (k8s-portforward--pair
               (:constructor k8s-portforward--pair-new)
               (:copier nil))
  client                        ; accepted local TCP process
  ws                            ; WS network process
  ws-raw                        ; accumulated bytes pre-handshake / partial frame
  headers-done                  ; t after HTTP/1.1 101 \r\n\r\n
  announces-seen                ; how many channel-port-number announces we've eaten
  pending-outbound              ; bytes from client received before handshake done
  closed)                       ; non-nil once teardown is in progress

(defun k8s-portforward--close-pair (pair)
  "Tear down both sides of a PAIR (idempotent)."
  (unless (k8s-portforward--pair-closed pair)
    (setf (k8s-portforward--pair-closed pair) t)
    (let ((c (k8s-portforward--pair-client pair))
          (w (k8s-portforward--pair-ws pair)))
      (ignore-errors (and c (process-live-p c) (delete-process c)))
      (ignore-errors (and w (process-live-p w) (delete-process w))))))

(defun k8s-portforward--client-filter (_sess pair _proc bytes)
  "Forward outbound BYTES from the local TCP client to channel 0.
Until the WS handshake completes, buffer bytes in
`pending-outbound' (curl sends its HTTP request immediately on
connect, often before our handshake's 101 has been parsed).  The
handshake-completion path flushes."
  (cond
   ((k8s-portforward--pair-headers-done pair)
    (when (process-live-p (k8s-portforward--pair-ws pair))
      (process-send-string
       (k8s-portforward--pair-ws pair)
       (k8s-portforward--encode-data 0 bytes))))
   (t
    (setf (k8s-portforward--pair-pending-outbound pair)
          (concat (k8s-portforward--pair-pending-outbound pair) bytes)))))

(defun k8s-portforward--flush-pending (pair)
  "After the WS handshake completes, ship any buffered client bytes."
  (let ((pending (k8s-portforward--pair-pending-outbound pair)))
    (when (and pending (> (length pending) 0)
               (process-live-p (k8s-portforward--pair-ws pair)))
      (process-send-string
       (k8s-portforward--pair-ws pair)
       (k8s-portforward--encode-data 0 pending))
      (setf (k8s-portforward--pair-pending-outbound pair) ""))))

(defun k8s-portforward--client-sentinel (_sess pair _proc _event)
  "Local client disappeared (closed connection) — close the WS too."
  (k8s-portforward--close-pair pair))

(defun k8s-portforward--handle-payload (pair payload)
  "Route one decoded WS payload (channel byte + data) to the right place."
  (when (> (length payload) 0)
    (let ((ch (aref payload 0))
          (rest (substring payload 1)))
      (cond
       ;; The very first messages on each channel announce the port
       ;; number (2 bytes LE) — drop them.
       ((and (< (k8s-portforward--pair-announces-seen pair) 2)
             (= (length rest) 2))
        (cl-incf (k8s-portforward--pair-announces-seen pair)))
       ;; Data channel (0): forward to the local client.
       ((= ch 0)
        (let ((c (k8s-portforward--pair-client pair)))
          (when (and c (process-live-p c))
            (process-send-string c rest))))
       ;; Error channel (1): log + close.
       ((= ch 1)
        (message "k8s-portforward: remote error: %s" rest)
        (k8s-portforward--close-pair pair))))))

(defun k8s-portforward--ws-filter (_sess pair _proc data)
  "Drive the WS state machine for one PAIR.
Consume any handshake bytes first, then decode frames."
  (setf (k8s-portforward--pair-ws-raw pair)
        (concat (k8s-portforward--pair-ws-raw pair) data))
  ;; Eat HTTP/1.1 101 ... \r\n\r\n once.
  (unless (k8s-portforward--pair-headers-done pair)
    (let* ((raw (k8s-portforward--pair-ws-raw pair))
           (sep (string-search "\r\n\r\n" raw)))
      (when sep
        (let* ((headers (substring raw 0 sep))
               (code-line (car (split-string headers "\r\n"))))
          (cond
           ((string-match-p "\\` *HTTP/1\\.1 101" code-line)
            (setf (k8s-portforward--pair-headers-done pair) t)
            (setf (k8s-portforward--pair-ws-raw pair)
                  (substring raw (+ sep 4)))
            (k8s-portforward--flush-pending pair))
           (t
            (message "k8s-portforward: handshake failed: %s" code-line)
            (k8s-portforward--close-pair pair)))))))
  ;; Once past the handshake, parse complete frames out of the buffer.
  (when (k8s-portforward--pair-headers-done pair)
    (let ((pos 0)
          (raw (k8s-portforward--pair-ws-raw pair)))
      (catch 'incomplete
        (while (< pos (length raw))
          (let ((frame (k8s-exec--parse-frame raw pos)))
            (unless frame (throw 'incomplete nil))
            (pcase-let ((`(,_fin ,opcode ,payload ,end) frame))
              (cond
               ((= opcode #x2)            ; binary
                (k8s-portforward--handle-payload pair payload))
               ((= opcode #x8)            ; close
                (k8s-portforward--close-pair pair)
                (throw 'incomplete nil))
               ((= opcode #x9)            ; ping
                (process-send-string
                 (k8s-portforward--pair-ws pair)
                 (k8s-exec--encode-frame #xA payload))))
              (setq pos end)))))
      (setf (k8s-portforward--pair-ws-raw pair) (substring raw pos)))))

(defun k8s-portforward--ws-sentinel (_sess pair _proc event)
  (unless (k8s-portforward--pair-closed pair)
    (message "k8s-portforward: WS closed (%s)" (string-trim event))
    (k8s-portforward--close-pair pair)))

(defun k8s-portforward--open-ws-for-client (sess client)
  "Open a fresh WebSocket for one accepted local CLIENT.
Hooks up bidirectional filters."
  (let* ((conn (k8s-portforward-session-conn sess))
         (ns (k8s-portforward-session-ns sess))
         (pod (k8s-portforward-session-pod sess))
         (rport (k8s-portforward-session-remote-port sess))
         (host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (path (k8s-portforward--ws-path ns pod rport))
         (token (k8s-user-token (k8s-connection-user conn)))
         (ws-key (k8s-exec--ws-key))
         (buf (generate-new-buffer " *k8s-portforward*"))
         (ws (condition-case err
                 (k8s-exec--open-tls "k8s-portforward" buf conn)
               (error
                (kill-buffer buf)
                (error "k8s-portforward: TLS connect failed: %s"
                       (error-message-string err)))))
         (pair (k8s-portforward--pair-new
                :client client
                :ws ws
                :ws-raw ""
                :headers-done nil
                :announces-seen 0
                :pending-outbound ""
                :closed nil)))
    (set-process-coding-system ws 'binary 'binary)
    (set-process-query-on-exit-flag ws nil)
    (set-process-coding-system client 'binary 'binary)
    (set-process-query-on-exit-flag client nil)
    (set-process-filter ws
                        (lambda (p d)
                          (k8s-portforward--ws-filter sess pair p d)))
    (set-process-sentinel ws
                          (lambda (p e)
                            (k8s-portforward--ws-sentinel sess pair p e)))
    (set-process-filter client
                        (lambda (p d)
                          (k8s-portforward--client-filter sess pair p d)))
    (set-process-sentinel client
                          (lambda (p e)
                            (k8s-portforward--client-sentinel sess pair p e)))
    ;; Send HTTP/1.1 GET upgrade.
    (process-send-string
     ws
     (concat (format "GET %s HTTP/1.1\r\n" path)
             (k8s-portforward--ws-headers
              (format "%s:%d" host port) ws-key token)))
    (push (cons client ws) (k8s-portforward-session-pairs sess))
    pair))

;;; ---------------------------------------------------------------------------
;;; Local listener

(defun k8s-portforward--accept-fn (sess)
  "Return a `:filter' / `:server'-accept function for SESS's local listener."
  (lambda (server-proc client _msg)
    (ignore server-proc)
    (k8s-portforward--open-ws-for-client sess client)))

(defun k8s-portforward--start-listener (sess)
  "Open the local TCP server for SESS."
  (let* ((local-port (k8s-portforward-session-local-port sess))
         (name (format "k8s-portforward:%d->%s/%s:%d"
                       local-port
                       (k8s-portforward-session-ns sess)
                       (k8s-portforward-session-pod sess)
                       (k8s-portforward-session-remote-port sess)))
         (server
          (make-network-process
           :name name
           :buffer nil
           :family 'ipv4
           :service local-port
           :host 'local
           :server t
           :coding 'binary
           :log (lambda (server-proc client _msg)
                  (ignore server-proc)
                  (k8s-portforward--open-ws-for-client sess client)))))
    (set-process-query-on-exit-flag server nil)
    (setf (k8s-portforward-session-server sess) server)
    server))

;;; ---------------------------------------------------------------------------
;;; Public entry + listing buffer

;;;###autoload
(defun k8s-portforward (conn ns pod remote-port &optional local-port)
  "Start a port-forward into NS/POD's REMOTE-PORT via CONN.
LOCAL-PORT defaults to REMOTE-PORT.  Returns the session id."
  (let* ((local (or local-port remote-port))
         (sess (k8s-portforward-session--new
                :conn conn :ns ns :pod pod
                :local-port local :remote-port remote-port
                :pairs nil
                :created-at (float-time))))
    (k8s-portforward--start-listener sess)
    (let ((id (k8s-portforward--register sess)))
      (message "k8s-portforward: localhost:%d -> %s/%s:%d (id %d)"
               local ns pod remote-port id)
      (k8s-portforward-list)
      id)))

;;;###autoload
(defun k8s-portforward-at-point ()
  "`P' on a Pod row: prompt for the remote port and start a forward.
Local port defaults to the remote port; numeric prefix arg sets the
local port directly."
  (interactive)
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (pod (and sec (oref sec value))))
    (unless (and pod (eq type 'pod))
      (user-error "Not on a Pod row"))
    (let* ((ns (k8s--resource-namespace pod))
           (name (k8s--resource-name pod))
           ;; Surface the pod's declared container ports as completion
           ;; candidates.
           (declared-ports
            (cl-loop for c across (or (cdr (assq 'containers
                                                  (cdr (assq 'spec pod))))
                                      [])
                     append
                     (cl-loop for p across (or (cdr (assq 'ports c)) [])
                              for n = (cdr (assq 'containerPort p))
                              when n collect (number-to-string n))))
           (default (or (car declared-ports) "8080"))
           (rport-str (completing-read
                       (format "Forward to %s/%s remote port (default %s): "
                               ns name default)
                       declared-ports nil nil nil nil default))
           (rport (string-to-number rport-str))
           (lport (if (and current-prefix-arg
                           (numberp current-prefix-arg))
                      current-prefix-arg
                    rport)))
      (k8s-portforward (k8s--ensure-connection) ns name rport lport))))

;;; --- listing buffer ---

(defun k8s-portforward--insert-row (id sess)
  (insert
   (propertize
    (format "  %3d  localhost:%-5d -> %s/%s:%-5d  %d active conn%s\n"
            id
            (k8s-portforward-session-local-port sess)
            (k8s-portforward-session-ns sess)
            (k8s-portforward-session-pod sess)
            (k8s-portforward-session-remote-port sess)
            (length (k8s-portforward-session-pairs sess))
            (if (= 1 (length (k8s-portforward-session-pairs sess))) "" "s"))
    'k8s-portforward-id id)))

(defun k8s-portforward-list ()
  "Pop a buffer listing every active port-forward.  `k' kills the
forward on the current row; `g' refreshes."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:port-forwards*")))
    (with-current-buffer buf
      (k8s-portforward-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Active port-forwards\n\n"
                            'font-lock-face 'eltainer-section-heading))
        (if (null k8s-portforward--sessions)
            (insert (propertize "  (none)\n" 'font-lock-face 'k8s-dim))
          (insert (propertize
                   "   ID  LOCAL          ->  POD                                 ACTIVE\n"
                   'font-lock-face 'k8s-section-heading))
          (dolist (entry k8s-portforward--sessions)
            (k8s-portforward--insert-row (car entry) (cdr entry))))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

(defun k8s-portforward-kill-at-point ()
  "Kill the port-forward on the current row of `*k8s:port-forwards*'."
  (interactive)
  (let ((id (get-text-property (point) 'k8s-portforward-id)))
    (unless id (user-error "Not on a port-forward row"))
    (let ((sess (cdr (assq id k8s-portforward--sessions))))
      (when sess
        (let ((server (k8s-portforward-session-server sess)))
          (ignore-errors (and server (process-live-p server)
                              (delete-process server))))
        (dolist (p (k8s-portforward-session-pairs sess))
          (ignore-errors (delete-process (car p)))
          (ignore-errors (delete-process (cdr p))))
        (k8s-portforward--unregister id)
        (message "k8s-portforward: killed forward %d" id)
        (k8s-portforward-list)))))

(defvar k8s-portforward-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'k8s-portforward-list)
    (define-key m (kbd "k") #'k8s-portforward-kill-at-point)
    (define-key m (kbd "q") #'quit-window)
    m)
  "Keymap for `k8s-portforward-mode'.")

(define-derived-mode k8s-portforward-mode special-mode "K8s:PF"
  "Listing of active port-forwards.

\\{k8s-portforward-mode-map}"
  :interactive nil
  :group 'k8s-portforward)

(provide 'k8s-portforward)
;;; k8s-portforward.el ends here
