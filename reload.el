;;; reload.el --- Dev helper: byte-compile + reload all modules -*- lexical-binding: t -*-
;;
;; Eval-buffer this file (or `M-x eldocker-reload') to rebuild and
;; re-`load' every eldocker module in dependency order.  Handy during
;; development so you don't have to track which buffer changed.

(require 'cl-lib)
(require 'bytecomp)

(defconst eldocker-modules
  '("docker-config"
    "docker-api"
    "docker-ps"
    "docker-images"
    "docker-logs"
    "docker-daemon"
    "docker")
  "Eldocker modules in load order (dependencies first).")

(defconst eldocker--source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this `reload.el' file (captured at load time).")

(defun eldocker-reload ()
  "Byte-compile and reload every eldocker module."
  (interactive)
  (let ((load-path (cons eldocker--source-dir load-path)))
    (dolist (mod eldocker-modules)
      (let ((src (expand-file-name (concat mod ".el") eldocker--source-dir)))
        (unless (file-exists-p src)
          (user-error "eldocker-reload: missing %s" src))
        (byte-compile-file src)
        (setq features (delq (intern mod) features))
        (load (file-name-sans-extension src) nil 'nomessage)))
    (message "eldocker-reload: reloaded %d modules"
             (length eldocker-modules))))

(provide 'reload)
;;; reload.el ends here
