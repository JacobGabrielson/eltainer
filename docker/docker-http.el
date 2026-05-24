;;; docker-http.el --- HTTP/1.1 client for the Docker engine API -*- lexical-binding: t -*-
;;
;; Speaks HTTP/1.1 to a Docker daemon over a Unix domain socket, plain
;; TCP, or TLS-wrapped TCP.  This is the transport for the no-CLI
;; rewrite: every module that needs to talk to docker eventually routes
;; through here.  See docs/direct-daemon-rewrite.md.
;;
;; Hard requirements (the rewrite is Emacs 30+ only):
;; - Native JSON parser (`json-parse-string').  Checked at load time.
;; - GnuTLS — checked lazily, only when a TLS-requiring `docker-config'
;;   is actually used.  Unix-socket and plain-TCP daemons need no TLS.
;;
;; Public API:
;;   (docker-http-request CFG METHOD PATH &key headers body query)
;;     → `docker-http-response'
;;   (docker-http-json RESPONSE) → decoded JSON
;;
;; Streaming (`docker-http-stream') is deferred to a later phase.

(require 'cl-lib)
(require 'gnutls)
(require 'url-util)
(require 'docker-config)

;; Load-time capability check: native JSON.
(unless (fboundp 'json-parse-string)
  (error "eltainer requires native JSON support (Emacs built --with-json)"))

(defgroup docker-http nil
  "HTTP transport for the Docker engine API."
  :group 'docker)

(defcustom docker-http-default-tcp-port 2375
  "Default TCP port for plain (non-TLS) `tcp://' daemons."
  :type 'integer
  :group 'docker-http)

(defcustom docker-http-default-tls-port 2376
  "Default TCP port for TLS-wrapped `tcp://' daemons."
  :type 'integer
  :group 'docker-http)

;;; ---------------------------------------------------------------------------
;;; Response type

(cl-defstruct (docker-http-response
               (:constructor docker-http-response--new)
               (:copier nil))
  "An HTTP response from the Docker engine."
  status     ; integer HTTP status code
  reason     ; status reason phrase
  headers    ; alist of (LOWERCASE-NAME . VALUE) strings
  body)      ; raw body string after transfer-encoding decode

(define-error 'docker-http-error "Docker HTTP error")

;;; ---------------------------------------------------------------------------
;;; Connection

(defun docker-http--require-tls (host)
  "Refuse if GnuTLS is unavailable but HOST is a TLS endpoint."
  (unless (gnutls-available-p)
    (error
     "eltainer: TLS required for %s but Emacs lacks GnuTLS — rebuild --with-gnutls"
     host)))

(defun docker-http--connect (cfg)
  "Open a network process to the daemon described by CFG.
Returns a live process whose buffer accumulates the raw response.

CFG's `tls-priority' slot, if set, is bound to
`gnutls-algorithm-priority' during the TLS handshake — k8s clusters
need a TLS-1.2 priority because Emacs' GnuTLS doesn't reliably present
client certificates in a 1.3 handshake."
  (let* ((host (docker-config-host cfg))
         (port (docker-config-port cfg))
         (socket-path (docker-config-socket-path cfg))
         ;; `tls' is the modern flag; `tls-verify=t' with no explicit `tls'
         ;; still means "use TLS" for backward-compat with old docker configs.
         (tls (or (docker-config-tls cfg)
                  (docker-config-tls-verify cfg)))
         (strict-verify (docker-config-tls-verify cfg))
         (tls-priority (docker-config-tls-priority cfg))
         (gnutls-algorithm-priority (or tls-priority gnutls-algorithm-priority))
         ;; Relax GnuTLS chain/hostname verification when the caller opted
         ;; out (k8s clusters often present self-signed certs with no SAN
         ;; that matches the local-loopback address we use).
         (gnutls-verify-error (and strict-verify gnutls-verify-error))
         (buf (generate-new-buffer " *docker-http*")))
    (condition-case err
        (cond
         (socket-path
          (make-network-process
           :name "docker-http"
           :buffer buf
           :family 'local
           :service socket-path
           :coding '(binary . binary)
           :nowait nil))
         ((and host tls)
          (docker-http--require-tls host)
          (make-network-process
           :name "docker-http"
           :buffer buf
           :host host
           :service (or port docker-http-default-tls-port)
           :coding '(binary . binary)
           :nowait nil
           :tls-parameters
           (cons 'gnutls-x509pki
                 (gnutls-boot-parameters
                  :type 'gnutls-x509pki
                  :hostname host
                  :trustfiles (when (docker-config-tls-ca-cert cfg)
                                (list (docker-config-tls-ca-cert cfg)))
                  ;; gnutls-boot-parameters :keylist takes (KEY CERT), not
                  ;; (CERT KEY) — and gets a TLS error -56 when reversed.
                  :keylist (when (and (docker-config-tls-cert cfg)
                                      (docker-config-tls-key cfg))
                             (list (list (docker-config-tls-key cfg)
                                         (docker-config-tls-cert cfg))))))))
         (host
          (make-network-process
           :name "docker-http"
           :buffer buf
           :host host
           :service (or port docker-http-default-tcp-port)
           :coding '(binary . binary)
           :nowait nil))
         (t
          (error "docker-http: docker-config has neither socket-path nor host")))
      (error
       (when (buffer-live-p buf) (kill-buffer buf))
       (signal (car err) (cdr err))))))

;;; ---------------------------------------------------------------------------
;;; Request building

(defun docker-http--encode-query (alist)
  "Encode ALIST of (KEY . VALUE) pairs as a URL query string."
  (mapconcat (lambda (p)
               (concat (url-hexify-string (format "%s" (car p)))
                       "="
                       (url-hexify-string (format "%s" (cdr p)))))
             alist "&"))

(defun docker-http--merge-headers (defaults overrides)
  "Combine DEFAULTS and OVERRIDES, letting OVERRIDES win by header name."
  (let ((seen (mapcar (lambda (h) (downcase (car h))) overrides)))
    (append (cl-remove-if (lambda (h)
                            (member (downcase (car h)) seen))
                          defaults)
            overrides)))

(defun docker-http--build-request (method path headers body query)
  "Build a raw HTTP/1.1 request string.
HEADERS take precedence over the per-name defaults; pass e.g.
`((\"Connection\" . \"Upgrade\"))' to override `Connection: close'."
  (let* ((qs (when query (docker-http--encode-query query)))
         (full-path (if (and qs (> (length qs) 0)) (concat path "?" qs) path))
         (default-headers
          (append `(("Host" . "localhost")
                    ("User-Agent" . "eltainer/0.1")
                    ("Accept" . "application/json")
                    ("Connection" . "close"))
                  (when body
                    `(("Content-Length" . ,(number-to-string
                                            (string-bytes body)))))))
         (all-headers (docker-http--merge-headers default-headers headers))
         (header-block
          (mapconcat (lambda (h) (format "%s: %s" (car h) (cdr h)))
                     all-headers "\r\n")))
    (concat method " " full-path " HTTP/1.1\r\n"
            header-block "\r\n\r\n"
            (or body ""))))

;;; ---------------------------------------------------------------------------
;;; Response parsing (also exported for unit testing)

(defun docker-http--parse-status-line (line)
  "Parse \"HTTP/1.1 200 OK\" → (CODE . REASON)."
  (unless (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\) ?\\(.*\\)\\'" line)
    (signal 'docker-http-error (list "malformed status line" line)))
  (cons (string-to-number (match-string 1 line))
        (match-string 2 line)))

(defun docker-http--parse-headers (header-block)
  "Parse HEADER-BLOCK (CRLF-separated, no trailing CRLFCRLF) into an alist.
Header names are lower-cased; values are trimmed."
  (mapcar (lambda (line)
            (let ((c (string-search ":" line)))
              (unless c
                (signal 'docker-http-error (list "malformed header" line)))
              (cons (downcase (string-trim (substring line 0 c)))
                    (string-trim (substring line (1+ c))))))
          (split-string header-block "\r\n" t)))

(defun docker-http--decode-chunked (body)
  "Decode HTTP/1.1 chunked-transfer BODY into the raw payload string."
  (let ((pos 0) (len (length body)) (chunks nil))
    (while (< pos len)
      (let ((eol (string-search "\r\n" body pos)))
        (unless eol
          (signal 'docker-http-error (list "malformed chunk header at" pos)))
        (let* ((size-hex (substring body pos eol))
               (size (string-to-number
                      (replace-regexp-in-string ";.*\\'" "" size-hex) 16)))
          (setq pos (+ eol 2))
          (if (zerop size)
              (setq pos len)
            (push (substring body pos (+ pos size)) chunks)
            (setq pos (+ pos size 2))))))
    (apply #'concat (nreverse chunks))))

(defun docker-http--decode-body (headers raw-body)
  "Decode RAW-BODY per Transfer-Encoding / Content-Length in HEADERS."
  (cond
   ((string= (alist-get "transfer-encoding" headers nil nil #'string=) "chunked")
    (docker-http--decode-chunked raw-body))
   (t raw-body)))

(defun docker-http--split-response (raw)
  "Split RAW response bytes into (STATUS-LINE HEADERS-BLOCK BODY)."
  (let ((sep (string-search "\r\n\r\n" raw)))
    (unless sep
      (signal 'docker-http-error '("no header/body separator")))
    (let* ((head (substring raw 0 sep))
           (body (substring raw (+ sep 4)))
           (lines (split-string head "\r\n"))
           (status-line (car lines))
           (header-block (mapconcat #'identity (cdr lines) "\r\n")))
      (list status-line header-block body))))

;;; ---------------------------------------------------------------------------
;;; Connection pool (HTTP/1.1 keep-alive)
;;
;; Sockets used by `docker-http-request' used to be opened, used for one
;; request, and closed.  TLS handshakes alone are ~100ms (more over
;; LAN/WAN); for K8s-side bursts (list pods, then describe each, then
;; events) we paid that per request.
;;
;; Now: after a response, if it didn't carry `Connection: close', the
;; socket goes back to a per-cfg pool keyed by host+port+TLS material.
;; Next `docker-http-request' for the same cfg pops an idle socket
;; first.  Streaming callers (logs, events, watches, exec) still open
;; their own long-lived sockets — they're not pooled.
;;
;; To disable: set `docker-http-pool-max' to 0 — acquire always misses
;; and release always closes, restoring the close-per-request behaviour.

(defcustom docker-http-pool-max 4
  "Max idle keep-alive sockets kept per cfg in the connection pool.
Set to 0 to disable pooling entirely (close after every request)."
  :type 'integer
  :group 'docker-http)

(defcustom docker-http-pool-idle-seconds 25
  "Drop a pooled socket if it has been idle longer than this many seconds.
Most servers (nginx, Apache, K8s apiserver, Docker daemon) keep
sockets open for at least 30s; 25s leaves margin so we never
hand the caller a half-closed socket."
  :type 'number
  :group 'docker-http)

(defvar docker-http--pool (make-hash-table :test 'equal)
  "Connection pool.
Key: signature from `docker-http--pool-key'.  Value: list of
\(PROC . LAST-RELEASED-FLOAT-TIME) with the most-recently-released
at the head -- those are least likely to have been closed by the
server since we let go.")

(defun docker-http--pool-key (cfg)
  "Return a stable equality key for CFG's connection params."
  (list (docker-config-socket-path cfg)
        (docker-config-host cfg)
        (docker-config-port cfg)
        (and (or (docker-config-tls cfg)
                 (docker-config-tls-verify cfg)) t)
        (docker-config-tls-ca-cert cfg)
        (docker-config-tls-cert cfg)
        (docker-config-tls-key cfg)))

(defun docker-http--idle-discard (_proc _data)
  "Process filter for pooled idle sockets — silently drops unexpected bytes."
  nil)

(defun docker-http--pool-acquire (cfg)
  "Pop a live, fresh pooled socket for CFG, or nil if none usable.
Walks the per-cfg list head-to-tail (MRU first), discarding dead or
stale entries, and returns the first viable one."
  (when (> docker-http-pool-max 0)
    (let ((key (docker-http--pool-key cfg))
          (now (float-time))
          result kept)
      (dolist (entry (gethash key docker-http--pool))
        (let ((proc (car entry))
              (last (cdr entry)))
          (cond
           (result (push entry kept))                       ; already have one
           ((not (process-live-p proc)))                    ; server closed, drop
           ((> (- now last) docker-http-pool-idle-seconds)  ; stale, kill
            (ignore-errors (delete-process proc)))
           (t (setq result proc)))))
      (puthash key (nreverse kept) docker-http--pool)
      result)))

(defun docker-http--pool-release (cfg proc)
  "Return PROC to CFG's pool if alive and the pool isn't full.
Sets `docker-http--idle-discard' as the filter so stray bytes don't
land in the process buffer between requests."
  (cond
   ((not (process-live-p proc))
    nil)
   ((<= docker-http-pool-max 0)
    (ignore-errors (delete-process proc)))
   (t
    (let* ((key (docker-http--pool-key cfg))
           (entries (gethash key docker-http--pool)))
      (cond
       ((>= (length entries) docker-http-pool-max)
        (ignore-errors (delete-process proc)))
       (t
        (set-process-filter proc #'docker-http--idle-discard)
        (puthash key (cons (cons proc (float-time)) entries)
                 docker-http--pool)))))))

(defun docker-http-pool-flush ()
  "Close every pooled socket and clear the pool.
Useful after a network change or when debugging connection issues."
  (interactive)
  (let ((n 0))
    (maphash (lambda (_k entries)
               (dolist (entry entries)
                 (let ((proc (car entry)))
                   (when (process-live-p proc)
                     (ignore-errors (delete-process proc))
                     (cl-incf n)))))
             docker-http--pool)
    (clrhash docker-http--pool)
    (message "docker-http: flushed %d pooled socket%s"
             n (if (= n 1) "" "s"))))

;;; ---------------------------------------------------------------------------
;;; Incremental response detection (drives the sync request's poll loop)

(defun docker-http--try-decode-chunked (scratch start)
  "Try to decode a chunked body in SCRATCH starting at buffer pos START.
Returns the decoded body string if complete (saw the 0-size
terminator), else nil for \"need more bytes\".  Read-only — does
not consume the buffer."
  (when (buffer-live-p scratch)
    (with-current-buffer scratch
      (save-excursion
        (let ((pos start) chunks complete)
          (catch 'incomplete
            (while (and (not complete) (< pos (point-max)))
              (goto-char pos)
              (let ((eol (and (search-forward "\r\n" nil t)
                              (- (point) 2))))
                (unless eol (throw 'incomplete nil))
                (let* ((size-hex (buffer-substring-no-properties pos eol))
                       (size (string-to-number
                              (replace-regexp-in-string ";.*\\'" "" size-hex)
                              16))
                       (body-start (+ eol 2)))
                  (if (zerop size)
                      (setq complete t)
                    (when (> (+ body-start size 2) (point-max))
                      (throw 'incomplete nil))
                    (push (buffer-substring-no-properties
                           body-start (+ body-start size))
                          chunks)
                    (setq pos (+ body-start size 2)))))))
          (when complete (apply #'concat (nreverse chunks))))))))

(defun docker-http--try-parse-response (scratch)
  "If SCRATCH contains a complete HTTP response, return it parsed; else nil.
Knows about Content-Length and Transfer-Encoding: chunked.  Without
either header it returns nil — the caller falls back to \"wait for
EOF\", matching HTTP/1.0 bodyless-by-close framing."
  (when (buffer-live-p scratch)
    (with-current-buffer scratch
      (save-excursion
        (goto-char (point-min))
        (let ((sep (and (search-forward "\r\n\r\n" nil t)
                        (- (point) 4))))
          (when sep
            (let* ((head (buffer-substring-no-properties (point-min) sep))
                   (lines (split-string head "\r\n"))
                   (status-line (car lines))
                   (header-block (mapconcat #'identity (cdr lines) "\r\n"))
                   (status (docker-http--parse-status-line status-line))
                   (headers (docker-http--parse-headers header-block))
                   (body-start (+ sep 4))
                   (body-bytes (- (point-max) body-start))
                   (clen (alist-get "content-length"
                                    headers nil nil #'string=))
                   (te (alist-get "transfer-encoding"
                                  headers nil nil #'string=)))
              (cond
               (clen
                (let ((n (string-to-number clen)))
                  (when (>= body-bytes n)
                    (docker-http-response--new
                     :status (car status) :reason (cdr status)
                     :headers headers
                     :body (buffer-substring-no-properties
                            body-start (+ body-start n))))))
               ((and te (string= (downcase te) "chunked"))
                (when-let ((decoded (docker-http--try-decode-chunked
                                     scratch body-start)))
                  (docker-http-response--new
                   :status (car status) :reason (cdr status)
                   :headers headers :body decoded)))
               (t nil)))))))))

(defun docker-http--keep-alive-p (response)
  "Return non-nil when RESPONSE leaves the socket reusable.
HTTP/1.1 default is keep-alive unless `Connection: close'."
  (let ((c (alist-get "connection"
                      (docker-http-response-headers response)
                      nil nil #'string=)))
    (not (and c (string-match-p "close" (downcase c))))))

;;; ---------------------------------------------------------------------------
;;; Public: sync request

(cl-defun docker-http-request (cfg method path &key headers body query)
  "Send METHOD PATH (an engine-API path) over CFG.
Return a `docker-http-response'.

QUERY is an alist of (KEY . VALUE) pairs URL-encoded into the path.
HEADERS is an alist of extra request headers (merged on top of defaults).
BODY is a string (typically pre-`json-serialize'd); set this *and*
add a `Content-Type: application/json' header for JSON requests."
  (let* ((acquired (docker-http--pool-acquire cfg))
         (proc (or acquired (docker-http--connect cfg)))
         ;; Default to keep-alive when the pool is enabled; caller can
         ;; still override via their own Connection header (e.g. the
         ;; TTY-exec path wants `Connection: Upgrade').
         (conn-default (if (> docker-http-pool-max 0) "keep-alive" "close"))
         (request-headers (docker-http--merge-headers
                           `(("Connection" . ,conn-default))
                           headers))
         (merged-headers (docker-http--merge-headers
                          (docker-config-default-headers cfg)
                          request-headers))
         (request (docker-http--build-request method path
                                              merged-headers body query))
         ;; Collect bytes in a hidden unibyte buffer; insert is O(chunk)
         ;; instead of the O(n²) of `(setq received (concat received
         ;; data))'.  The *process* buffer isn't reused for this —
         ;; Emacs's default filter writes a "Process X connection
         ;; broken by remote peer\n" trailer there on TLS close, which
         ;; would tail-corrupt the response and confuse the parser.
         (scratch (docker-http--make-scratch "docker-http-request"))
         (response nil)
         (pooled nil))
    (set-process-filter proc (lambda (_p data)
                               (when (buffer-live-p scratch)
                                 (with-current-buffer scratch
                                   (goto-char (point-max))
                                   (insert data)))))
    (unwind-protect
        (progn
          (process-send-string proc request)
          ;; Incremental wait: stop as soon as we can parse a complete
          ;; response (Content-Length / chunked).  Falling back on
          ;; "process died" handles HTTP/1.0 bodyless-by-close framing.
          (catch 'done
            (while t
              (setq response (docker-http--try-parse-response scratch))
              (when response (throw 'done t))
              (unless (process-live-p proc)
                ;; Socket closed mid-response — try a final best-effort
                ;; parse against whatever bytes did arrive.
                (let ((raw (with-current-buffer scratch
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
                  (when (> (length raw) 0)
                    (setq response
                          (condition-case nil
                              (let* ((parts (docker-http--split-response raw))
                                     (status (docker-http--parse-status-line
                                              (nth 0 parts)))
                                     (h* (docker-http--parse-headers
                                          (nth 1 parts)))
                                     (b* (docker-http--decode-body
                                          h* (nth 2 parts))))
                                (docker-http-response--new
                                 :status (car status) :reason (cdr status)
                                 :headers h* :body b*))
                            (error nil)))))
                (throw 'done t))
              (accept-process-output proc 1.0)))
          (cond
           ((and response
                 (docker-http--keep-alive-p response)
                 (process-live-p proc))
            (docker-http--pool-release cfg proc)
            (setq pooled t))
           ((process-live-p proc)
            (ignore-errors (delete-process proc))))
          (or response
              (signal 'docker-http-error
                      (list "no response" method path))))
      (when (buffer-live-p scratch) (kill-buffer scratch))
      ;; Pooled procs keep their process-buffer alive (still owned by
      ;; the proc).  Only kill it when we've actually dropped the proc.
      (unless pooled
        (when (process-live-p proc) (ignore-errors (delete-process proc)))
        (let ((buf (process-buffer proc)))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

;;; ---------------------------------------------------------------------------
;;; Public: streaming request
;;;
;; Send a request and hand the response off to user-supplied filter
;; callbacks rather than buffering the whole body.  The process the
;; caller gets back is owned by them: kill it to abort the stream.

(cl-defstruct (docker-http--stream-state
               (:constructor docker-http--stream-state--new))
  scratch      ; unibyte buffer object for incremental parsing
  headers-seen ; t once we've parsed the status line + headers
  chunked      ; t if Transfer-Encoding: chunked
  on-headers
  on-chunk
  on-close)

(defun docker-http--make-scratch (name)
  "Create a hidden unibyte scratch buffer named NAME for stream parsing."
  (let ((buf (generate-new-buffer (concat " *" name "*") t)))
    (with-current-buffer buf
      (set-buffer-multibyte nil))
    buf))

(defun docker-http--stream-pump-body (state new)
  "Pump NEW bytes into STATE's scratch buffer; deliver decoded chunks.
Replaces the previous string-concat accumulator: bytes are appended
to a unibyte scratch buffer in O(chunk), and consumed prefixes are
`delete-region'd, so total work stays O(n) regardless of chunk
size pattern."
  (let ((scratch (docker-http--stream-state-scratch state)))
    (unless (buffer-live-p scratch) (cl-return-from docker-http--stream-pump-body))
    (with-current-buffer scratch
      (goto-char (point-max))
      (when (and new (> (length new) 0)) (insert new))
      (cond
       ((docker-http--stream-state-chunked state)
        (goto-char (point-min))
        (let (out)
          (catch 'incomplete
            (while (< (point) (point-max))
              (let ((eol (save-excursion
                           (and (search-forward "\r\n" nil t)
                                (- (point) 2)))))
                (unless eol (throw 'incomplete nil))
                (let* ((size-hex (buffer-substring-no-properties (point) eol))
                       (size (string-to-number
                              (replace-regexp-in-string ";.*\\'" "" size-hex)
                              16))
                       (body-start (+ eol 2)))
                  (when (zerop size)
                    ;; trailer + close — drop everything we've buffered.
                    (delete-region (point-min) (point-max))
                    (throw 'incomplete nil))
                  (let ((body-end (+ body-start size)))
                    (if (> (+ body-end 2) (point-max))
                        (throw 'incomplete nil)
                      (push (buffer-substring-no-properties body-start body-end)
                            out)
                      ;; Consume "size-hex\r\nbody\r\n" from the head.
                      (delete-region (point-min) (+ body-end 2))
                      (goto-char (point-min))))))))
          (dolist (c (nreverse out))
            (funcall (docker-http--stream-state-on-chunk state) c))))
       (t
        (let ((all (buffer-substring-no-properties (point-min) (point-max))))
          (delete-region (point-min) (point-max))
          (when (> (length all) 0)
            (funcall (docker-http--stream-state-on-chunk state) all))))))))

(defun docker-http--stream-filter (state)
  "Return a process filter closed over STATE."
  (lambda (proc data)
    (if (docker-http--stream-state-headers-seen state)
        (docker-http--stream-pump-body state data)
      (let ((scratch (docker-http--stream-state-scratch state)))
        (when (buffer-live-p scratch)
          (with-current-buffer scratch
            (goto-char (point-max))
            (when (and data (> (length data) 0)) (insert data))
            (goto-char (point-min))
            (let ((sep (save-excursion
                         (and (search-forward "\r\n\r\n" nil t)
                              (- (point) 4)))))
              (when sep
                (let* ((head (buffer-substring-no-properties (point-min) sep))
                       (rest (buffer-substring-no-properties
                              (+ sep 4) (point-max)))
                       (lines (split-string head "\r\n"))
                       (status-line (car lines))
                       (header-block (mapconcat #'identity (cdr lines) "\r\n"))
                       (status (docker-http--parse-status-line status-line))
                       (headers (docker-http--parse-headers header-block))
                       (chunked (string= (alist-get "transfer-encoding"
                                                    headers nil nil #'string=)
                                         "chunked")))
                  (setf (docker-http--stream-state-headers-seen state) t)
                  (setf (docker-http--stream-state-chunked state) chunked)
                  (delete-region (point-min) (point-max))
                  (when (docker-http--stream-state-on-headers state)
                    (funcall (docker-http--stream-state-on-headers state)
                             (car status) (cdr status) headers))
                  (docker-http--stream-pump-body state rest)))))))
      (ignore proc))))

(defun docker-http--stream-sentinel (state)
  "Return a process sentinel for STATE.
On EOF fires on-close (if set), then kills the scratch buffer so
it doesn't outlive the stream."
  (lambda (proc _event)
    (unless (process-live-p proc)
      (when (docker-http--stream-state-on-close state)
        (funcall (docker-http--stream-state-on-close state)))
      (let ((scratch (docker-http--stream-state-scratch state)))
        (when (buffer-live-p scratch)
          (kill-buffer scratch))))))

(cl-defun docker-http-stream (cfg method path
                                  &key headers body query
                                       on-headers on-chunk on-close)
  "Send METHOD PATH and stream the body via callbacks.
Returns the live process so the caller can `delete-process' to abort.
HEADERS, BODY, QUERY behave like in `docker-http-request'.
Callbacks:
  ON-HEADERS  (lambda (STATUS REASON HEADERS-ALIST))
  ON-CHUNK    (lambda (BYTES))  — invoked for each whole decoded chunk
  ON-CLOSE    (lambda ())       — invoked once when the daemon closes"
  (unless on-chunk
    (error "docker-http-stream: on-chunk is required"))
  (let* ((proc (docker-http--connect cfg))
         (headers (docker-http--merge-headers
                   (docker-config-default-headers cfg) headers))
         (state (docker-http--stream-state--new
                 :scratch (docker-http--make-scratch "docker-http-stream")
                 :headers-seen nil
                 :chunked nil
                 :on-headers on-headers
                 :on-chunk on-chunk
                 :on-close on-close))
         (req (docker-http--build-request method path headers body query)))
    (set-process-filter proc (docker-http--stream-filter state))
    (set-process-sentinel proc (docker-http--stream-sentinel state))
    (process-send-string proc req)
    proc))

;;; ---------------------------------------------------------------------------
;;; Parallel-async coordination
;;
;; Generic structured-concurrency primitives.  They live here, the
;; lowest layer both halves of eltainer share, so neither side needs
;; to depend on the other to fan out N independent HTTP calls.

(defcustom docker-http-parallel-timeout 15
  "Default seconds `docker-http-fan-out-sync' waits before giving up."
  :type 'integer
  :group 'docker)

(defun docker-http-fan-out (specs callback)
  "Run every spec in SPECS in parallel; call CALLBACK once they all return.
Each spec is a unary function (LAMBDA (DONE-CB)) that initiates an
async operation and calls DONE-CB with its result.  CALLBACK
receives a list of results in the same order as SPECS.
Returns immediately."
  (let* ((n (length specs))
         (results (make-vector n nil))
         (counter (cons n nil)))
    (if (zerop n)
        (funcall callback nil)
      (cl-loop for spec in specs
               for i from 0
               do (let ((idx i))
                    (funcall spec
                             (lambda (result)
                               (aset results idx result)
                               (cl-decf (car counter))
                               (when (zerop (car counter))
                                 (funcall callback
                                          (append results nil))))))))))

(defun docker-http-fan-out-sync (specs &optional timeout)
  "Run SPECS in parallel and block until all return (or TIMEOUT lapses).
Returns the list of results in SPECS order.  TIMEOUT defaults to
`docker-http-parallel-timeout'; on timeout, returns whatever has
been collected so far with trailing nils for missing slots.

Despite blocking, the ops do run concurrently — N HTTP calls
finish in roughly the slowest one's latency, not N times it."
  (let ((done nil)
        (results nil))
    (docker-http-fan-out specs
                         (lambda (rs) (setq results rs done t)))
    (let ((deadline (+ (float-time) (or timeout docker-http-parallel-timeout))))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    results))

(cl-defun docker-http-get-async (cfg path callback &key query)
  "Send GET PATH against CFG asynchronously.
Invokes CALLBACK with the response body as a *string*, or with nil
on any failure (non-2xx, malformed framing, connection error).
QUERY is the same alist `docker-http-stream' accepts.

This is the lowest-level async primitive — higher layers (k8s, prom)
wrap it to parse JSON, build their own URLs, and fan out N calls in
parallel.  Under the hood it goes through `docker-http-stream' and
collects chunks into a list, joining once on close (avoids the
O(n²) of `(concat acc bytes)' on every chunk)."
  (let* ((chunks nil)
         (failed nil)
         (fired nil)
         (finish (lambda ()
                   (unless fired
                     (setq fired t)
                     (funcall callback
                              (and (not failed) chunks
                                   (apply #'concat (nreverse chunks))))))))
    (condition-case _err
        (docker-http-stream
         cfg "GET" path
         :query query
         :on-headers (lambda (status _reason _hs)
                       (unless (and (>= status 200) (< status 300))
                         (setq failed t)))
         :on-chunk (lambda (bytes) (unless failed (push bytes chunks)))
         :on-close finish)
      (error (funcall callback nil)))))

(defun docker-http-ok-p (response)
  "Return non-nil when RESPONSE is a 2xx status."
  (let ((s (docker-http-response-status response)))
    (and (>= s 200) (< s 300))))

(defun docker-http-json (response)
  "Parse RESPONSE's body as JSON, returning alists/lists per house style.
Returns nil for an empty body.  Signals `docker-http-error' on malformed JSON."
  (let ((body (docker-http-response-body response)))
    (when (and body (> (length body) 0))
      (condition-case err
          (json-parse-string body
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object :false)
        (error (signal 'docker-http-error
                       (list "JSON parse failed" (error-message-string err))))))))

(provide 'docker-http)
;;; docker-http.el ends here
