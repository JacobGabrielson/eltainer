;;; docker-exec.el --- Run commands inside containers via the engine API -*- lexical-binding: t -*-
;;
;; Two-step exec like the daemon's API:
;;   1. POST /containers/{id}/exec        → returns an exec instance Id
;;   2. POST /exec/{id}/start             → hijacks the connection, raw bytes
;;
;; When called with TTY=t, the daemon returns one unmultiplexed stream
;; and we hand the network process off to `eltainer-terminal-feed' for
;; rendering.  Non-TTY exec demultiplexes stdout/stderr the same way
;; logs do.

(require 'cl-lib)
(require 'docker-api)
(require 'docker-http)
(require 'docker-stream)
(require 'eltainer-terminal)

(defun docker-exec--create (cfg container cmd tty)
  "POST /containers/{id}/exec, return the new exec instance Id.
CMD is a list of strings; we encode it as a JSON array."
  (let ((result (docker-engine-post
                 cfg (format "/containers/%s/exec" container)
                 :json `((AttachStdin . ,(if tty t :false))
                         (AttachStdout . t)
                         (AttachStderr . t)
                         (Tty . ,(if tty t :false))
                         (Cmd . ,(apply #'vector cmd))))))
    (alist-get 'Id result)))

(cl-defstruct (docker-exec-result
               (:constructor docker-exec-result--new)
               (:copier nil))
  "Result of a synchronous `docker-exec-run'.
Mirrors the shape of `k8s-exec-result' on the k8s side so the
shared `eltainer-fs-check-failure' can accept either one's
fields uniformly."
  exit-code   ; integer or nil — ExitCode from `/exec/{id}/json'
  stdout      ; unibyte string
  stderr)     ; unibyte string

(defcustom docker-exec-run-timeout 30
  "Seconds `docker-exec-run' waits before giving up on a stream.
Bumped past the K8s side's value because docker can be on the
other side of a slow daemon over TCP+TLS."
  :type 'integer
  :group 'docker)

;;;###autoload
(defun docker-exec-run (cfg container argv &optional timeout)
  "Run ARGV (list of strings) in CONTAINER via CFG, synchronously.
Returns a `docker-exec-result' carrying captured stdout / stderr
and the exit code from `GET /exec/{id}/json' after the stream
closes.  TIMEOUT (default `docker-exec-run-timeout') in seconds.

The docker counterpart of `k8s-exec' — the sync collector both
halves of eltainer's filesystem-browse layer plug into.  Output
is demultiplexed via `docker-stream-make-demux' (the same 8-byte
framer the logs view uses); stdout and stderr land in separate
byte buckets."
  (let* ((exec-id (docker-exec--create cfg container argv nil))
         (stdout-chunks nil)
         (stderr-chunks nil)
         (done nil)
         (demux (docker-stream-make-demux
                 (lambda (typ payload)
                   (pcase typ
                     ('stderr (push payload stderr-chunks))
                     (_       (push payload stdout-chunks))))))
         (proc (docker-exec--start-hijacked
                cfg exec-id nil
                (lambda (bytes) (funcall demux bytes))
                (lambda ()
                  (funcall demux 'cleanup)
                  (setq done t))))
         (deadline (+ (float-time) (or timeout docker-exec-run-timeout))))
    (unwind-protect
        (while (and (not done)
                    (process-live-p proc)
                    (< (float-time) deadline))
          (accept-process-output proc 0.1))
      (when (process-live-p proc)
        (ignore-errors (delete-process proc))))
    (unless done
      (error "docker-exec-run: %s timed out after %ds"
             (mapconcat #'identity argv " ")
             (or timeout docker-exec-run-timeout)))
    (let* ((info (ignore-errors
                   (docker-engine-get
                    cfg (format "/exec/%s/json" exec-id))))
           (exit (and info (alist-get 'ExitCode info))))
      (docker-exec-result--new
       :exit-code exit
       :stdout (apply #'concat (nreverse stdout-chunks))
       :stderr (apply #'concat (nreverse stderr-chunks))))))

(defun docker-exec--start-hijacked (cfg exec-id tty on-chunk on-close)
  "POST /exec/{id}/start, stream bytes back via ON-CHUNK.
With TTY=t we negotiate a real hijack (Upgrade: tcp), so the same
socket carries both the daemon's output (to ON-CHUNK) AND the user's
keystrokes (via `process-send-string' from the caller).  Without TTY
we let the daemon use chunked transfer for the multiplexed stream.
Returns the live network process; ON-CLOSE fires on EOF."
  (let* ((body (json-serialize
                `((Detach . :false) (Tty . ,(if tty t :false)))
                :null-object nil :false-object :false))
         (headers (if tty
                      '(("Content-Type" . "application/json")
                        ("Upgrade" . "tcp")
                        ("Connection" . "Upgrade"))
                    '(("Content-Type" . "application/json")))))
    (docker-http-stream
     cfg "POST"
     (format "%s/exec/%s/start" (docker--api-prefix cfg) exec-id)
     :headers headers
     :body body
     :on-chunk on-chunk
     :on-close on-close)))

;;;###autoload
(defun docker-exec-at-point (&optional cmd)
  "Exec a command in the container at point.  Prompts for CMD if not given.
With prefix arg, force non-TTY mode (capture output, no terminal emulator)."
  (interactive)
  (let* ((c (docker--container-at-point))
         (cname (docker-container-name c))
         (cfg (docker--ensure-config))
         (tty (not current-prefix-arg))
         (cmd (or cmd (read-shell-command
                       (format "Exec in %s: " cname)
                       (if tty "/bin/sh" "/bin/sh -c 'uname -a'"))))
         (argv (split-string-shell-command cmd))
         (exec-id (docker-exec--create cfg cname argv tty)))
    (if tty
        (docker-exec--start-tty cfg cname exec-id)
      (docker-exec--start-non-tty cfg cname exec-id))))

(defvar-local docker-exec--id nil
  "Engine exec instance Id for this buffer (used by the resize hook).")
(defvar-local docker-exec--config nil
  "Docker config for this exec buffer (used by the resize hook).")
(defvar-local docker-exec--last-dim nil
  "Last (HEIGHT . WIDTH) we posted to /exec/{id}/resize.")

(defun docker-exec--post-resize (cfg exec-id h w)
  "POST a resize for EXEC-ID to (H, W).  Errors are swallowed."
  (ignore-errors
    (docker-engine-post cfg (format "/exec/%s/resize" exec-id)
                        :query `(("h" . ,(format "%d" h))
                                 ("w" . ,(format "%d" w))))))

(defun docker-exec--maybe-resize (buf)
  "Post a resize if BUF's window size differs from the last one we sent.
Resizes both the local terminal emulator and the remote PTY."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and docker-exec--id docker-exec--config)
        (let* ((dim (eltainer-terminal-window-size buf))
               (h (car dim)) (w (cdr dim)))
          (unless (and docker-exec--last-dim
                       (equal docker-exec--last-dim (cons h w)))
            (setq docker-exec--last-dim (cons h w))
            (eltainer-terminal-resize buf h w)
            (docker-exec--post-resize docker-exec--config
                                      docker-exec--id h w)))))))

(defun docker-exec--window-size-change (frame)
  "`window-size-change-functions' hook: resize every visible exec buffer."
  (dolist (win (window-list frame))
    (let ((buf (window-buffer win)))
      (when (and (buffer-live-p buf)
                 (buffer-local-value 'docker-exec--id buf))
        (docker-exec--maybe-resize buf)))))

(defun docker-exec--start-tty (cfg cname exec-id)
  "Launch a TTY exec into CNAME and host it in the configured terminal backend.
The Upgrade hijack makes the same socket bidirectional: docker-http's
stream filter strips the response headers, `eltainer-terminal-feed'
pushes the decoded body bytes into the backend (eat / vterm / term),
and `eltainer-terminal-bind' routes the user's keystrokes back over
the same process.  A `window-size-change-functions' hook keeps the
remote PTY in sync with the Emacs window."
  (let* ((bufname (format "*docker:exec:%s*" cname))
         (buf (eltainer-terminal-open bufname))
         (deliver (lambda (bytes) (eltainer-terminal-feed buf bytes)))
         (proc (docker-exec--start-hijacked
                cfg exec-id t deliver nil)))
    (with-current-buffer buf
      (setq docker-exec--id exec-id
            docker-exec--config cfg
            docker-exec--last-dim nil))
    (eltainer-terminal-bind buf proc)
    (add-hook 'window-size-change-functions
              #'docker-exec--window-size-change)
    (pop-to-buffer buf)
    ;; Best-effort initial sync once the buffer is in a window so
    ;; `window-body-height/width' return real numbers.
    (docker-exec--maybe-resize buf)
    buf))

(defun docker-exec--start-non-tty (cfg cname exec-id)
  "Run a non-TTY exec, demultiplex into a buffer, return that buffer."
  (let* ((bufname (format "*docker:exec:%s*" cname))
         (buf (get-buffer-create bufname))
         (demux
          (docker-stream-make-demux
           (lambda (typ payload)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (let ((inhibit-read-only t)
                       (face (pcase typ
                               ('stderr 'docker-logs-stderr)
                               (_       'docker-logs-stdout))))
                   (goto-char (point-max))
                   (insert (propertize payload 'font-lock-face face)))))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (erase-buffer))
      (special-mode))
    (docker-exec--start-hijacked
     cfg exec-id nil
     (lambda (bytes) (funcall demux bytes))
     (lambda () (funcall demux 'cleanup)))
    (pop-to-buffer buf)
    buf))

(provide 'docker-exec)
;;; docker-exec.el ends here
