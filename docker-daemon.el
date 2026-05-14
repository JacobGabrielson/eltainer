;;; docker-daemon.el --- Direct-to-daemon trial (Phase 4 spike) -*- lexical-binding: t -*-
;;
;; Exploratory: bypass the docker CLI and speak HTTP directly to the
;; daemon over the Unix socket.  Intentionally scoped to a SINGLE
;; endpoint, `GET /containers/json', so we can see what the
;; emak8s-style code path feels like before committing to it.
;;
;; Try it: M-x docker-daemon-ps
;;
;; Caveats: no TLS support, no chunked-transfer decoding beyond the
;; common case, no streaming.  This is a feel-it-out spike, not a
;; production client.

(require 'cl-lib)
(require 'json)
(require 'docker-config)

(defcustom docker-daemon-socket "/var/run/docker.sock"
  "Path to the Docker daemon's Unix domain socket."
  :type 'file
  :group 'docker)

;;; ---------------------------------------------------------------------------
;;; Bare-minimum HTTP/1.1 over the Unix socket

(defun docker-daemon--request (path)
  "Send `GET PATH HTTP/1.1' to the daemon and return the raw response string."
  (let* ((buf (generate-new-buffer " *docker-daemon*"))
         (proc (make-network-process
                :name "docker-daemon"
                :buffer buf
                :family 'local
                :service docker-daemon-socket
                :coding '(binary . binary)
                :nowait nil)))
    (unwind-protect
        (progn
          (process-send-string
           proc
           (concat "GET " path " HTTP/1.1\r\n"
                   "Host: localhost\r\n"
                   "User-Agent: eldocker-daemon-spike/0.1\r\n"
                   "Accept: application/json\r\n"
                   "Connection: close\r\n"
                   "\r\n"))
          (while (process-live-p proc)
            (accept-process-output proc 0.1))
          (with-current-buffer buf (buffer-string)))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer buf))))

(defun docker-daemon--split-response (raw)
  "Split RAW HTTP response into (STATUS-LINE HEADERS BODY)."
  (let ((sep (string-search "\r\n\r\n" raw)))
    (unless sep
      (error "docker-daemon: no header/body separator in response"))
    (let* ((head (substring raw 0 sep))
           (body (substring raw (+ sep 4)))
           (lines (split-string head "\r\n" t))
           (status (car lines))
           (headers (mapcar (lambda (l)
                              (let ((c (string-search ":" l)))
                                (cons (downcase (string-trim (substring l 0 c)))
                                      (string-trim (substring l (1+ c))))))
                            (cdr lines))))
      (list status headers body))))

(defun docker-daemon--decode-chunked (body)
  "Decode HTTP/1.1 chunked-transfer BODY into the raw payload string."
  (let ((pos 0) (out "") (len (length body)))
    (while (< pos len)
      (let ((eol (string-search "\r\n" body pos)))
        (unless eol (error "docker-daemon: malformed chunk header"))
        (let* ((size-hex (substring body pos eol))
               (size (string-to-number
                      (replace-regexp-in-string ";.*\\'" "" size-hex)
                      16)))
          (setq pos (+ eol 2))
          (if (zerop size)
              (setq pos len)
            (setq out (concat out (substring body pos (+ pos size))))
            (setq pos (+ pos size 2))))))
    out))

(defun docker-daemon--body (status headers body)
  "Return the decoded BODY string, honoring HEADERS' transfer-encoding."
  (unless (string-match "\\` *HTTP/[0-9.]+ \\([0-9]+\\)" status)
    (error "docker-daemon: malformed status line: %s" status))
  (let ((code (string-to-number (match-string 1 status))))
    (unless (and (>= code 200) (< code 300))
      (error "docker-daemon: HTTP %d — %s" code body)))
  (if (string= (alist-get "transfer-encoding" headers nil nil #'string=)
               "chunked")
      (docker-daemon--decode-chunked body)
    body))

;;; ---------------------------------------------------------------------------
;;; The one endpoint we wired up

(defun docker-daemon-list-containers ()
  "Return a list of running containers via direct daemon GET /containers/json."
  (cl-destructuring-bind (status headers body)
      (docker-daemon--split-response
       (docker-daemon--request "/containers/json"))
    (let* ((payload (docker-daemon--body status headers body))
           (json-object-type 'alist)
           (json-array-type 'list)
           (json-key-type 'symbol))
      (json-read-from-string payload))))

;;;###autoload
(defun docker-daemon-ps ()
  "Print running container names by talking to the daemon directly."
  (interactive)
  (let* ((cs (docker-daemon-list-containers))
         (lines (mapcar (lambda (c)
                          (format "%-14s  %s  %s"
                                  (substring (or (alist-get 'Id c) "") 0 12)
                                  (alist-get 'Image c)
                                  (mapconcat #'identity
                                             (alist-get 'Names c)
                                             ",")))
                        cs)))
    (with-current-buffer (get-buffer-create "*docker-daemon:ps*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "GET unix://%s/containers/json\n\n"
                        docker-daemon-socket))
        (if lines
            (dolist (l lines) (insert l "\n"))
          (insert "(no running containers)\n")))
      (special-mode)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

(provide 'docker-daemon)
;;; docker-daemon.el ends here
