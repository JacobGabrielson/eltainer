;;; docker-logs.el --- Container log viewing and tailing -*- lexical-binding: t -*-
;;
;; Stream and view container logs.  A log buffer is associated with a
;; single container and reuses a single async `docker logs' process.
;;
;; Usage:
;;   (docker-logs cfg "my-container")            ; tail with -f
;;   (docker-logs cfg "my-container" :tail 200)  ; show last 200 then follow
;;
;; M-x docker-logs-at-point in a container view streams the container
;; at point.

(require 'cl-lib)
(require 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Customization

(defcustom docker-logs-default-tail 200
  "Default number of lines to show when opening a log buffer."
  :type '(choice (const :tag "All history" nil) integer)
  :group 'docker-api)

(defcustom docker-logs-follow t
  "Non-nil to stream new log lines as they arrive (docker logs -f)."
  :type 'boolean
  :group 'docker-api)

(defcustom docker-logs-timestamps nil
  "Non-nil to include per-line timestamps."
  :type 'boolean
  :group 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Buffer-local state

(defvar-local docker-logs--container nil
  "Container name this log buffer is following.")

(defvar-local docker-logs--process nil
  "The async `docker logs' process for this buffer.")

(defvar-local docker-logs--config nil
  "`docker-config' used to start this log buffer.")

;;; ---------------------------------------------------------------------------
;;; Mode

(defvar-keymap docker-logs-mode-map
  "q" #'quit-window
  "g" #'docker-logs-restart
  "k" #'docker-logs-stop
  "G" #'end-of-buffer)

(define-derived-mode docker-logs-mode special-mode "Docker:Logs"
  "Mode for streaming Docker container logs.

\\{docker-logs-mode-map}"
  :group 'docker
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook #'docker-logs--cleanup nil t))

;;; ---------------------------------------------------------------------------
;;; Process management

(defun docker-logs--buffer-name (container)
  "Return the canonical log buffer name for CONTAINER."
  (format "*docker:logs:%s*" container))

(defun docker-logs--cleanup ()
  "Kill any associated log process when the buffer dies."
  (when (process-live-p docker-logs--process)
    (delete-process docker-logs--process)))

(defun docker-logs--insert (proc string)
  "Process filter: insert STRING from PROC at end of its buffer."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (at-end (= (point) (point-max))))
          (save-excursion
            (goto-char (point-max))
            (insert string))
          (when at-end
            (goto-char (point-max))))))))

(cl-defun docker-logs-start (cfg container &key tail follow timestamps)
  "Open a log buffer for CONTAINER and start streaming.
CFG is a `docker-config'.  TAIL, FOLLOW, TIMESTAMPS default to the
matching `docker-logs-*' customs.  Returns the buffer."
  (let* ((tail (or tail docker-logs-default-tail))
         (follow (if (eq follow 'unset) docker-logs-follow follow))
         (timestamps (if (eq timestamps 'unset) docker-logs-timestamps timestamps))
         (buf (get-buffer-create (docker-logs--buffer-name container))))
    (with-current-buffer buf
      (docker-logs-mode)
      (setq docker-logs--container container
            docker-logs--config cfg)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "docker logs %s\n\n" container)
                            'font-lock-face 'shadow)))
      (docker-logs--cleanup)
      (let* ((args (append (docker--tls-flags cfg)
                           (list "logs")
                           (when follow '("--follow"))
                           (when timestamps '("--timestamps"))
                           (when tail (list "--tail" (number-to-string tail)))
                           (list container)))
             (proc (apply #'start-process
                          (format "docker-logs-%s" container)
                          buf
                          (or docker-cli-path "docker")
                          args)))
        (set-process-coding-system proc 'utf-8 'utf-8)
        (set-process-filter proc #'docker-logs--insert)
        (setq docker-logs--process proc)))
    buf))

;;; ---------------------------------------------------------------------------
;;; Interactive commands

(defun docker-logs-restart ()
  "Restart the log stream in the current buffer."
  (interactive)
  (unless (and docker-logs--container docker-logs--config)
    (user-error "Not a docker logs buffer"))
  (docker-logs-start docker-logs--config docker-logs--container))

(defun docker-logs-stop ()
  "Stop the log stream without closing the buffer."
  (interactive)
  (docker-logs--cleanup)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert (propertize "\n[stream stopped]\n" 'font-lock-face 'shadow)))))

;;;###autoload
(cl-defun docker-logs (cfg container &key tail (follow 'unset) (timestamps 'unset))
  "Open a log buffer for CONTAINER streaming via CFG.
TAIL is the number of historical lines.  FOLLOW and TIMESTAMPS
override the customs when non-`unset'."
  (let ((buf (docker-logs-start cfg container
                                :tail tail
                                :follow follow
                                :timestamps timestamps)))
    (pop-to-buffer buf)
    buf))

(provide 'docker-logs)
;;; docker-logs.el ends here
