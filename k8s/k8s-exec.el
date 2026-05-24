;;; k8s-exec.el --- Pure-Elisp WebSocket exec for Kubernetes -*- lexical-binding: t -*-
;;
;; Run a command inside a Kubernetes pod via the API server's WebSocket
;; exec endpoint, with no kubectl and no shelling out.  Implements just
;; enough of RFC 6455 (client side, masked) and the v4.channel.k8s.io
;; subprotocol for one-shot synchronous execs.
;;
;; Usage:
;;   (let ((conn (k8s-connection-open k8s-kubeconfig-path)))
;;     (k8s-exec conn "default" "mypod" nil '("ls" "-la" "/")))
;;
;; CONTAINER may be nil for single-container pods.  Returns a
;; `k8s-exec-result' struct with raw unibyte STDOUT and STDERR plus the
;; remote process's EXIT-CODE, STATUS, and MESSAGE.

(require 'cl-lib)
(require 'gnutls)
(require 'json)
(require 'url-util)
(require 'docker-config)
(require 'k8s-config)
(require 'k8s-api)

;;; ---------------------------------------------------------------------------
;;; TLS connection helper
;;
;; `open-network-stream :type 'tls' silently returns nil when the GnuTLS
;; handshake fails (no client cert presented during a 1.3 handshake bites
;; us here, even with `gnutls-algorithm-priority' bound).  We mirror the
;; pattern in `docker-http--connect': `make-network-process' with
;; explicit `:tls-parameters' built from `gnutls-boot-parameters', and
;; `:keylist' in (KEY CERT) order (reversing yields TLS error -56).

(defun k8s-exec--open-tls (name buf conn)
  "Open a TLS network process named NAME with BUF, using CONN's TLS params."
  (let* ((host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (cfg (k8s-connection-docker-cfg conn))
         (ca-file (docker-config-tls-ca-cert cfg))
         (cert-file (docker-config-tls-cert cfg))
         (key-file  (docker-config-tls-key  cfg))
         (priority (docker-config-tls-priority cfg))
         (gnutls-algorithm-priority (or priority gnutls-algorithm-priority))
         ;; Self-signed cluster certs: skip chain/SAN verification.  The
         ;; client cert is what we authenticate with.
         (gnutls-verify-error nil))
    (make-network-process
     :name name
     :buffer buf
     :host host
     :service port
     :coding '(binary . binary)
     :nowait nil
     :tls-parameters
     (cons 'gnutls-x509pki
           (gnutls-boot-parameters
            :type 'gnutls-x509pki
            :hostname host
            :trustfiles (when ca-file (list ca-file))
            :keylist (when (and cert-file key-file)
                       (list (list key-file cert-file))))))))

;;; ---------------------------------------------------------------------------
;;; Result struct

(cl-defstruct (k8s-exec-result
               (:constructor k8s-exec-result--new)
               (:copier nil))
  stdout                  ; unibyte string
  stderr                  ; unibyte string
  exit-code               ; integer, or nil if unparseable
  status                  ; "Success" / "Failure" / nil
  message)                ; failure message, or nil

;;; ---------------------------------------------------------------------------
;;; WebSocket primitives (RFC 6455, client side)

(defconst k8s-exec--ws-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "Magic GUID used to derive Sec-WebSocket-Accept from Sec-WebSocket-Key.")

(defun k8s-exec--random-bytes (n)
  "Return N random bytes as a unibyte string."
  (apply #'unibyte-string (cl-loop repeat n collect (random 256))))

(defun k8s-exec--ws-key ()
  "Return a fresh Sec-WebSocket-Key value (base64 of 16 random bytes)."
  (base64-encode-string (k8s-exec--random-bytes 16) t))

(defun k8s-exec--ws-accept (key)
  "Return the Sec-WebSocket-Accept value the server should send for KEY."
  (base64-encode-string
   (secure-hash 'sha1 (concat key k8s-exec--ws-guid) nil nil t)
   t))

(defun k8s-exec--mask (payload mask)
  "Return PAYLOAD XOR'd with 4-byte MASK (a unibyte string)."
  (apply #'unibyte-string
         (cl-loop for i below (length payload)
                  collect (logxor (aref payload i)
                                  (aref mask (mod i 4))))))

(defun k8s-exec--encode-frame (opcode payload)
  "Encode a single WebSocket frame from client to server.
FIN bit is set, payload is masked per RFC 6455."
  (let* ((mask (k8s-exec--random-bytes 4))
         (masked (k8s-exec--mask payload mask))
         (len (length payload))
         (header
          (cond
           ((< len 126)
            (unibyte-string (logior #x80 opcode)
                            (logior #x80 len)))
           ((< len 65536)
            (unibyte-string (logior #x80 opcode)
                            (logior #x80 126)
                            (logand (ash len -8) #xFF)
                            (logand len #xFF)))
           (t
            (apply #'unibyte-string
                   (logior #x80 opcode)
                   (logior #x80 127)
                   (cl-loop for i from 7 downto 0
                            collect (logand (ash len (* -8 i)) #xFF)))))))
    (concat header mask masked)))

(defun k8s-exec--parse-frame (data start)
  "Try to parse one WebSocket frame from DATA starting at START.
Return (FIN OPCODE PAYLOAD END-POS) on success, nil if incomplete."
  (let ((len (length data)))
    (catch 'incomplete
      (unless (>= len (+ start 2)) (throw 'incomplete nil))
      (let* ((b0 (aref data start))
             (b1 (aref data (1+ start)))
             (fin (/= (logand b0 #x80) 0))
             (opcode (logand b0 #x0F))
             (masked (/= (logand b1 #x80) 0))
             (raw-len (logand b1 #x7F))
             (pos (+ start 2))
             payload-len)
        (cond
         ((< raw-len 126)
          (setq payload-len raw-len))
         ((= raw-len 126)
          (unless (>= len (+ pos 2)) (throw 'incomplete nil))
          (setq payload-len (+ (ash (aref data pos) 8)
                               (aref data (1+ pos))))
          (setq pos (+ pos 2)))
         (t
          (unless (>= len (+ pos 8)) (throw 'incomplete nil))
          (setq payload-len 0)
          (dotimes (i 8)
            (setq payload-len (+ (ash payload-len 8) (aref data (+ pos i)))))
          (setq pos (+ pos 8))))
        (let (mask)
          (when masked
            (unless (>= len (+ pos 4)) (throw 'incomplete nil))
            (setq mask (substring data pos (+ pos 4)))
            (setq pos (+ pos 4)))
          (unless (>= len (+ pos payload-len)) (throw 'incomplete nil))
          (let ((payload (substring data pos (+ pos payload-len))))
            (when masked
              (setq payload (k8s-exec--mask payload mask)))
            (list fin opcode payload (+ pos payload-len))))))))

;;; ---------------------------------------------------------------------------
;;; K8s exec channel demux (v4.channel.k8s.io)
;;
;; Each frame's payload[0] is the channel:
;;   0  stdin (we never receive)
;;   1  stdout
;;   2  stderr
;;   3  error (JSON v1.Status sent when the remote process exits)
;;   4  resize (we don't use)

(cl-defstruct (k8s-exec--session
               (:constructor k8s-exec--session-new)
               (:copier nil))
  process
  raw                ; accumulated unibyte bytes from process
  headers-done       ; non-nil after HTTP/1.1 101 \r\n\r\n consumed
  status-code        ; HTTP status from handshake reply
  stdout-chunks      ; list of unibyte strings, reverse order
  stderr-chunks
  error-payload      ; raw JSON string from channel 3
  done-p)            ; t when close frame received or peer closed

(defun k8s-exec--handle-frame (sess opcode payload)
  "Dispatch a single WebSocket frame for SESS."
  (cond
   ;; Close frame
   ((= opcode #x8)
    (setf (k8s-exec--session-done-p sess) t))
   ;; Ping — echo as pong
   ((= opcode #x9)
    (process-send-string (k8s-exec--session-process sess)
                         (k8s-exec--encode-frame #xA payload)))
   ;; Pong — ignore
   ((= opcode #xA) nil)
   ;; Binary (the only data frame k8s sends)
   ((= opcode #x2)
    (when (> (length payload) 0)
      (let ((channel (aref payload 0))
            (body (substring payload 1)))
        (cond
         ((= channel 1)
          (push body (k8s-exec--session-stdout-chunks sess)))
         ((= channel 2)
          (push body (k8s-exec--session-stderr-chunks sess)))
         ((= channel 3)
          (setf (k8s-exec--session-error-payload sess)
                (concat (or (k8s-exec--session-error-payload sess) "") body)))))))))

(defun k8s-exec--filter (sess _proc data)
  "Process filter: feed DATA into SESS's parser."
  (setf (k8s-exec--session-raw sess)
        (concat (k8s-exec--session-raw sess) data))
  ;; Consume HTTP handshake response headers if not yet done.
  (unless (k8s-exec--session-headers-done sess)
    (let* ((raw (k8s-exec--session-raw sess))
           (sep (string-search "\r\n\r\n" raw)))
      (when sep
        (let ((headers (substring raw 0 sep)))
          (when (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\)" headers)
            (setf (k8s-exec--session-status-code sess)
                  (string-to-number (match-string 1 headers)))))
        (setf (k8s-exec--session-raw sess)
              (substring (k8s-exec--session-raw sess) (+ sep 4)))
        (setf (k8s-exec--session-headers-done sess) t))))
  ;; Then parse as many WebSocket frames as possible from the remainder.
  (when (k8s-exec--session-headers-done sess)
    (let ((pos 0)
          (raw (k8s-exec--session-raw sess))
          stop)
      (while (not stop)
        (let ((parsed (k8s-exec--parse-frame raw pos)))
          (if (null parsed)
              (setq stop t)
            (cl-destructuring-bind (_fin opcode payload end) parsed
              (k8s-exec--handle-frame sess opcode payload)
              (setq pos end)))))
      (setf (k8s-exec--session-raw sess) (substring raw pos)))))

(defun k8s-exec--sentinel (sess _proc _event)
  "Process sentinel: mark session done when peer closes."
  (setf (k8s-exec--session-done-p sess) t))

;;; ---------------------------------------------------------------------------
;;; Public API

(defcustom k8s-exec-default-timeout 10
  "Default timeout in seconds for a `k8s-exec' call."
  :type 'number
  :group 'k8s)

(defcustom k8s-exec-shell-candidates
  '("/bin/sh"
    "/bin/bash"
    "/bin/ash"
    "/busybox/sh"
    "/usr/bin/sh"
    "/usr/bin/bash")
  "Shell paths probed in order when the user picks `e' on a pod.
The first candidate whose `<shell> -c true' returns exit 0 is used.
Distroless / scratch images have *no* shell at any of these paths;
`k8s-exec-find-shell' returns nil for those.  Customize to bias the
list (e.g. put `/bin/bash' first for bash-only images)."
  :type '(repeat string)
  :group 'k8s)

(defun k8s-exec-find-shell (conn ns pod container)
  "Probe CONTAINER in POD/NS for a working shell.
Returns the first path from `k8s-exec-shell-candidates' that
successfully runs `<path> -c true', or nil if none do.  Each probe
is a full WebSocket exec round-trip, so this can take a second
or two for distroless images where every candidate must be tried."
  (cl-some
   (lambda (path)
     (let ((res (ignore-errors
                  (k8s-exec conn ns pod container
                            (list path "-c" "true") 5))))
       (and res
            (k8s-exec-result-exit-code res)
            (= (k8s-exec-result-exit-code res) 0)
            path)))
   k8s-exec-shell-candidates))

(defun k8s-exec--build-path (ns pod container command)
  "Build the K8s exec URL path with query params."
  (let ((cmd-params
         (mapconcat (lambda (arg)
                      (concat "command=" (url-hexify-string arg)))
                    command "&"))
        (container-param
         (if container
             (concat "&container=" (url-hexify-string container))
           "")))
    (format "/api/v1/namespaces/%s/pods/%s/exec?%s%s&stdout=true&stderr=true"
            (url-hexify-string ns)
            (url-hexify-string pod)
            cmd-params
            container-param)))

(defun k8s-exec (conn ns pod container command &optional timeout)
  "Run COMMAND inside POD in NS via CONN, returning a `k8s-exec-result'.
COMMAND is a list of strings (no shell interpolation).
CONTAINER may be nil for single-container pods.
TIMEOUT is in seconds (default `k8s-exec-default-timeout').
Signals an error if the connection or WebSocket handshake fails."
  (unless command
    (error "k8s-exec: command must be a non-empty list of strings"))
  (let* ((host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (path (k8s-exec--build-path ns pod container command))
         (token (k8s-user-token (k8s-connection-user conn)))
         (ws-key (k8s-exec--ws-key))
         (buf (generate-new-buffer " *k8s-exec*"))
         (proc (condition-case err
                   (k8s-exec--open-tls "k8s-exec" buf conn)
                 (error
                  (kill-buffer buf)
                  (error "k8s-exec: failed to connect to %s:%d (%s)"
                         host port (error-message-string err)))))
         (sess (k8s-exec--session-new
                :process proc
                :raw ""
                :stdout-chunks nil
                :stderr-chunks nil)))
    (set-process-coding-system proc 'binary 'binary)
    (set-process-query-on-exit-flag proc nil)
    (set-process-filter proc (lambda (p d) (k8s-exec--filter sess p d)))
    (set-process-sentinel proc (lambda (p e) (k8s-exec--sentinel sess p e)))
    ;; Send the WebSocket upgrade handshake (plain HTTP, not framed).
    (let ((req (concat
                (format "GET %s HTTP/1.1\r\n" path)
                (format "Host: %s:%d\r\n" host port)
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                (format "Sec-WebSocket-Key: %s\r\n" ws-key)
                "Sec-WebSocket-Version: 13\r\n"
                "Sec-WebSocket-Protocol: v4.channel.k8s.io\r\n"
                (when token
                  (format "Authorization: Bearer %s\r\n" token))
                "User-Agent: eltainer/0.1\r\n"
                "\r\n")))
      (process-send-string proc req))
    ;; Spin until the session ends or we hit the timeout.
    (let ((deadline (+ (float-time) (or timeout k8s-exec-default-timeout))))
      (while (and (not (k8s-exec--session-done-p sess))
                  (process-live-p proc)
                  (< (float-time) deadline))
        (accept-process-output proc 0.1)))
    (ignore-errors (delete-process proc))
    (ignore-errors (kill-buffer buf))
    (let* ((status-code (k8s-exec--session-status-code sess))
           (stdout (apply #'concat
                          (nreverse (k8s-exec--session-stdout-chunks sess))))
           (stderr (apply #'concat
                          (nreverse (k8s-exec--session-stderr-chunks sess))))
           (err-payload (k8s-exec--session-error-payload sess))
           (err-json (and err-payload
                          (ignore-errors
                            (let ((json-object-type 'alist)
                                  (json-array-type 'vector)
                                  (json-key-type 'symbol))
                              (json-read-from-string err-payload)))))
           (status (cdr (assq 'status err-json)))
           (message (cdr (assq 'message err-json)))
           (exit-code
            (when err-json
              (let* ((details (cdr (assq 'details err-json)))
                     (causes (cdr (assq 'causes details)))
                     (c (seq-find (lambda (cause)
                                    (equal (cdr (assq 'reason cause))
                                           "ExitCode"))
                                  (or causes []))))
                (and c (string-to-number
                        (or (cdr (assq 'message c)) "")))))))
      (unless (k8s-exec--session-headers-done sess)
        (error "k8s-exec: connection closed before handshake completed"))
      (when (and status-code (/= status-code 101))
        (error "k8s-exec: handshake failed (HTTP %d): %s"
               status-code (or stderr stdout "")))
      (k8s-exec-result--new
       :stdout stdout
       :stderr stderr
       :exit-code (cond (exit-code exit-code)
                        ((equal status "Success") 0)
                        (t nil))
       :status status
       :message message))))

;;; ---------------------------------------------------------------------------
;;; Interactive TTY exec
;;
;; Like `k8s-exec' but bidirectional: opens an `eltainer-terminal'
;; buffer, streams the pod's stdout / stderr into it, and ships every
;; keystroke back over channel 0.  Resize is sent on channel 4 as
;; JSON `{Width, Height}'.  Reuses the WebSocket framing primitives
;; above; the only new bits are the filter (which feeds bytes to the
;; terminal instead of accumulating them) and the input-fn override.

(require 'eltainer-terminal)

(cl-defstruct (k8s-exec--itty
               (:constructor k8s-exec--itty-new)
               (:copier nil))
  process            ; network process (TLS-wrapped)
  buffer             ; eltainer-terminal buffer
  raw                ; accumulated wire bytes (pre-handshake / partial frames)
  headers-done       ; t once HTTP/1.1 101 response is consumed
  exec-id-conn       ; k8s-connection (needed if we add resize-on-window)
  closed)            ; t once peer disconnects / status frame received

(defun k8s-exec-interactive--encode-stdin (str)
  "Encode STR as a channel-0 (stdin) WebSocket binary frame."
  (k8s-exec--encode-frame #x2 (concat (unibyte-string 0) str)))

(defun k8s-exec-interactive--encode-resize (h w)
  "Encode an (H, W) terminal resize as a channel-4 frame."
  (let ((payload (concat (unibyte-string 4)
                         (json-serialize `((Width . ,w) (Height . ,h))
                                         :null-object nil
                                         :false-object :false))))
    (k8s-exec--encode-frame #x2 payload)))

(defun k8s-exec-interactive--filter (itty _proc data)
  "Wire-bytes filter: strip the HTTP 101, then route WS frames to the terminal."
  (setf (k8s-exec--itty-raw itty)
        (concat (k8s-exec--itty-raw itty) data))
  ;; First, consume the upgrade response (HTTP/1.1 101 …\r\n\r\n).
  (unless (k8s-exec--itty-headers-done itty)
    (let* ((raw (k8s-exec--itty-raw itty))
           (sep (string-search "\r\n\r\n" raw)))
      (when sep
        (let ((status (and (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\)" raw)
                           (string-to-number (match-string 1 raw)))))
          (unless (and status (= status 101))
            (message "k8s exec: handshake failed (HTTP %s)" (or status "?"))))
        (setf (k8s-exec--itty-raw itty) (substring raw (+ sep 4))
              (k8s-exec--itty-headers-done itty) t))))
  ;; Then pump as many frames as we can.
  (when (k8s-exec--itty-headers-done itty)
    (let ((pos 0)
          (raw (k8s-exec--itty-raw itty))
          stop)
      (while (not stop)
        (let ((parsed (k8s-exec--parse-frame raw pos)))
          (if (null parsed)
              (setq stop t)
            (cl-destructuring-bind (_fin opcode payload end) parsed
              (k8s-exec-interactive--handle itty opcode payload)
              (setq pos end)))))
      (setf (k8s-exec--itty-raw itty) (substring raw pos)))))

(defun k8s-exec-interactive--handle (itty opcode payload)
  "Dispatch a single WS frame for an interactive session."
  (cond
   ;; Close frame.
   ((= opcode #x8)
    (setf (k8s-exec--itty-closed itty) t))
   ;; Ping → pong.
   ((= opcode #x9)
    (process-send-string (k8s-exec--itty-process itty)
                         (k8s-exec--encode-frame #xA payload)))
   ;; Pong: ignore.
   ((= opcode #xA) nil)
   ;; Binary (the only data frame k8s sends).
   ((= opcode #x2)
    (when (> (length payload) 0)
      (let ((channel (aref payload 0))
            (body (substring payload 1)))
        (cond
         ;; channels 1 (stdout) and 2 (stderr) both go into the
         ;; terminal — TTY mode means the pod isn't multiplexing them
         ;; itself, but the API server still tags the side it's
         ;; coming from.  We render both as terminal output.
         ((or (= channel 1) (= channel 2))
          (eltainer-terminal-feed (k8s-exec--itty-buffer itty) body))
         ;; channel 3 = exec status (success/failure JSON).
         ((= channel 3)
          (k8s-exec-interactive--render-status itty body))))))))

(defun k8s-exec-interactive--render-status (itty body)
  "Render the channel-3 status JSON BODY at the end of ITTY's buffer.
Parses the v1.Status object; for Success we say so quietly, for
Failure we extract the human message and call out the
no-shell-in-the-image case specifically."
  (when (buffer-live-p (k8s-exec--itty-buffer itty))
    (let* ((status (ignore-errors
                     (let ((json-object-type 'alist)
                           (json-array-type 'vector)
                           (json-key-type 'symbol))
                       (json-read-from-string body))))
           (st  (cdr (assq 'status  status)))
           (msg (cdr (assq 'message status)))
           (rendered
            (cond
             ((null status)
              (format "[k8s exec: %s]" body))
             ((equal st "Success")
              "[k8s exec: process exited 0]")
             ((and msg
                   (or (string-match-p "executable file not found" msg)
                       (string-match-p "no such file or directory" msg)
                       (string-match-p "starting container process" msg)))
              (concat
               "[k8s exec: no shell found in this container image]\n"
               "  → looks distroless / scratch — there's no `/bin/sh' (or any\n"
               "    of `k8s-exec-shell-candidates') to exec into.  Workarounds:\n"
               "      1. exec a real binary the image *does* ship (C-u e)\n"
               "      2. attach a sidecar shell:\n"
               "         kubectl debug --image=busybox -it <pod> --target=<container>\n"
               "  raw: " msg))
             (msg
              (format "[k8s exec: %s]" msg))
             (t
              (format "[k8s exec: %s]" body)))))
      (with-current-buffer (k8s-exec--itty-buffer itty)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize (concat "\n" rendered "\n")
                              'font-lock-face 'eltainer-dim)))))))

(defun k8s-exec-interactive--sentinel (itty _proc _event)
  "Mark ITTY closed when the underlying network process exits."
  (setf (k8s-exec--itty-closed itty) t)
  (when (buffer-live-p (k8s-exec--itty-buffer itty))
    (with-current-buffer (k8s-exec--itty-buffer itty)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize "\n[stream closed]\n"
                              'font-lock-face 'eltainer-dim)))))))

(defvar k8s-exec-interactive--processes nil
  "List of (BUFFER . PROCESS) so the resize hook can find them.")

(defun k8s-exec-interactive--maybe-resize (buf last-dim)
  "Send a channel-4 resize frame if BUF's window dimensions changed.
LAST-DIM is the buffer-local previous (H . W) cons or nil."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((dim (eltainer-terminal-window-size buf))
            (proc (cdr (assq buf k8s-exec-interactive--processes))))
        (when (and proc (process-live-p proc)
                   (not (equal dim (symbol-value last-dim))))
          (set last-dim dim)
          (eltainer-terminal-resize buf (car dim) (cdr dim))
          (process-send-string
           proc (k8s-exec-interactive--encode-resize
                 (car dim) (cdr dim))))))))

(defun k8s-exec-interactive--window-size-change (frame)
  "`window-size-change-functions' hook: resize every active TTY exec."
  (dolist (win (window-list frame))
    (let ((buf (window-buffer win)))
      (when (assq buf k8s-exec-interactive--processes)
        (with-current-buffer buf
          (k8s-exec-interactive--maybe-resize
           buf 'k8s-exec-interactive--last-dim))))))

(defvar-local k8s-exec-interactive--last-dim nil
  "Last (H . W) sent to the remote pod via channel-4 resize.")

(defun k8s-exec-interactive--build-path (ns pod container command)
  "Build the K8s exec URL with stdin+tty enabled."
  (let* ((cmd-params
          (mapconcat (lambda (arg)
                       (concat "command=" (url-hexify-string arg)))
                     command "&"))
         (container-param
          (if container
              (concat "&container=" (url-hexify-string container))
            "")))
    (format
     "/api/v1/namespaces/%s/pods/%s/exec?%s%s&stdin=true&stdout=true&stderr=true&tty=true"
     (url-hexify-string ns)
     (url-hexify-string pod)
     cmd-params
     container-param)))

;;;###autoload
(defun k8s-exec-interactive (conn ns pod container &optional command)
  "Open an interactive TTY exec into POD in NS via CONN.
COMMAND is a list of strings; defaults to `(\"/bin/sh\")'.  CONTAINER
may be nil for single-container pods.  Opens an `eltainer-terminal'
buffer; the WebSocket connection drives both display and stdin."
  (interactive)
  (let* ((command (or command '("/bin/sh")))
         (host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (path (k8s-exec-interactive--build-path ns pod container command))
         (token (k8s-user-token (k8s-connection-user conn)))
         (ws-key (k8s-exec--ws-key))
         (bufname (format "*k8s:exec:%s/%s%s*" ns pod
                          (if container (format ":%s" container) "")))
         (term-buf (eltainer-terminal-open bufname))
         ;; Use a separate hidden buffer for the raw network process —
         ;; the eltainer-terminal buffer is where rendered output goes.
         (sock-buf (generate-new-buffer " *k8s-exec-itty*"))
         (proc (condition-case err
                   (k8s-exec--open-tls "k8s-exec-itty" sock-buf conn)
                 (error
                  (kill-buffer sock-buf)
                  (error "k8s-exec-interactive: failed to connect to %s:%d (%s)"
                         host port (error-message-string err)))))
         (itty (k8s-exec--itty-new
                :process proc
                :buffer term-buf
                :raw ""
                :exec-id-conn conn)))
    (set-process-coding-system proc 'binary 'binary)
    (set-process-query-on-exit-flag proc nil)
    (set-process-filter   proc (lambda (p d) (k8s-exec-interactive--filter itty p d)))
    (set-process-sentinel proc (lambda (p e) (k8s-exec-interactive--sentinel itty p e)))
    ;; Send the WebSocket upgrade request.
    (process-send-string
     proc (concat
           (format "GET %s HTTP/1.1\r\n" path)
           (format "Host: %s:%d\r\n" host port)
           "Upgrade: websocket\r\n"
           "Connection: Upgrade\r\n"
           (format "Sec-WebSocket-Key: %s\r\n" ws-key)
           "Sec-WebSocket-Version: 13\r\n"
           "Sec-WebSocket-Protocol: v4.channel.k8s.io\r\n"
           (when token
             (format "Authorization: Bearer %s\r\n" token))
           "User-Agent: eltainer/0.1\r\n"
           "\r\n"))
    ;; Wire keystrokes from the terminal buffer back through channel 0.
    (eltainer-terminal-set-input-fn
     term-buf
     (lambda (str)
       (when (process-live-p proc)
         (process-send-string proc (k8s-exec-interactive--encode-stdin str)))))
    ;; Track this session for the global resize hook.
    (push (cons term-buf proc) k8s-exec-interactive--processes)
    (add-hook 'window-size-change-functions
              #'k8s-exec-interactive--window-size-change)
    (with-current-buffer term-buf
      (setq-local k8s-exec-interactive--last-dim nil)
      ;; Tear down the network process and forget the buffer mapping on close.
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (setq k8s-exec-interactive--processes
                        (assq-delete-all term-buf
                                         k8s-exec-interactive--processes))
                  (when (process-live-p proc) (delete-process proc))
                  (when (buffer-live-p sock-buf) (kill-buffer sock-buf)))
                nil t))
    (pop-to-buffer term-buf)
    ;; Best-effort initial resize once the buffer is in a window.
    (k8s-exec-interactive--maybe-resize term-buf 'k8s-exec-interactive--last-dim)
    term-buf))

(provide 'k8s-exec)
;;; k8s-exec.el ends here
