;;; reload.el --- Dev helper: byte-compile + reload all modules -*- lexical-binding: t -*-
;;
;; Eval-buffer this file (or `M-x eldocker-reload') to rebuild and
;; re-`load' every eldocker module in dependency order.  Handy during
;; development so you don't have to track which buffer changed.

(require 'cl-lib)
(require 'bytecomp)

(defconst eldocker-modules
  '("docker-config"
    "docker-http"
    "docker-stream"
    "docker-api"
    "docker-ps"
    "docker-images"
    "docker-networks"
    "docker-events"
    "docker-logs"
    "docker-terminal"
    "docker-exec"
    "docker-auth"
    "docker-pull"
    "docker")
  "Eldocker modules in load order (dependencies first).")

(defconst eldocker--source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this `reload.el' file (captured at load time).")

(defun eldocker-reload ()
  "Byte-compile and reload every eldocker module.
Also re-enters the major mode in any live `docker-*-mode' buffer so
freshly-bound keys land in already-open windows."
  (interactive)
  (let ((load-path (cons eldocker--source-dir load-path))
        (errors nil))
    (dolist (mod eldocker-modules)
      (let ((src (expand-file-name (concat mod ".el") eldocker--source-dir)))
        (unless (file-exists-p src)
          (user-error "eldocker-reload: missing %s" src))
        (let ((byte-compile-result (byte-compile-file src)))
          (unless byte-compile-result
            (push mod errors)))
        (setq features (delq (intern mod) features))
        (load (file-name-sans-extension src) nil 'nomessage)))
    ;; Re-enter modes in any existing eldocker buffer so a stale
    ;; local-map (or any post-mode-init state) gets rebuilt.
    (let ((rebound 0))
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and (symbolp major-mode)
                     (string-prefix-p "docker-" (symbol-name major-mode))
                     (string-suffix-p "-mode" (symbol-name major-mode))
                     (fboundp major-mode))
            (funcall major-mode)
            (cl-incf rebound))))
      (message "eldocker-reload: reloaded %d modules, refreshed %d buffer%s%s"
               (length eldocker-modules)
               rebound (if (= rebound 1) "" "s")
               (if errors
                   (format ", %d compile failure(s): %s"
                           (length errors) (mapconcat #'identity errors ", "))
                 "")))))

(provide 'reload)
;;; reload.el ends here
