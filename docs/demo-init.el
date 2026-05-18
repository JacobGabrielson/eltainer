;;; demo-init.el --- Scripted demo of the eltainer dashboard + exec -*- lexical-binding: t -*-
;;
;; Drives a single asciinema-recordable scenario:
;;   1. `M-x eltainer'    — opens the dashboard listing both backends
;;   2. type `c'          — jumps to the docker containers view
;;   3. move to `eldocker-ticker'
;;   4. type `e' → RET   — opens a shell inside the container via the
;;                        Upgrade-hijacked /exec endpoint, hosted in eat
;;   5. run a few shell commands so the rendering shows real output
;;   6. exit the shell so asciinema's `rec --command' terminates
;;
;; Invoked by docs/record-demo.sh.  Not autoloaded; the file is consumed
;; only inside the recording subshell.

(setq package-load-list '(all))
(package-initialize)

;; Locate the repo root containing THIS file.
(let* ((this-dir (file-name-directory (or load-file-name buffer-file-name)))
       (repo-root (file-name-directory (directory-file-name this-dir))))
  (add-to-list 'load-path repo-root))
(require 'eltainer)

;; Minimal cosmetic setup so the recording is uncluttered.
(setq inhibit-startup-screen t
      ring-bell-function 'ignore
      use-dialog-box nil
      eltainer-terminal-backend 'auto)
(when (fboundp 'menu-bar-mode) (menu-bar-mode -1))
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(when (fboundp 'blink-cursor-mode) (blink-cursor-mode -1))

(defun demo--type (proc str)
  "Send STR to PROC one character at a time, mimicking human typing."
  (dolist (ch (string-to-list str))
    (process-send-string proc (char-to-string ch))
    (sit-for 0.04)))

(defun demo--press (key &optional pause)
  "Press a key in the current buffer and pause briefly."
  (execute-kbd-macro (kbd key))
  (sit-for (or pause 0.6)))

(defun demo--run ()
  "The whole scripted demo."
  ;; --- 1: dashboard ---
  (eltainer)
  (sit-for 2.2)                              ; let viewers see the menu

  ;; --- 2: c jumps to docker containers ---
  (demo--press "c" 1.5)
  (with-current-buffer "*docker:containers*"
    (goto-char (point-min))
    (when (re-search-forward "eldocker-ticker" nil t)
      (beginning-of-line)
      (forward-char 2))
    (sit-for 1.0)

    ;; --- 3: e → /bin/sh ---
    (demo--press "e" 0.4)
    (demo--press "RET" 0.4))

  ;; --- 4: drive the exec buffer ---
  (let ((deadline (+ (float-time) 5.0))
        (buf nil))
    (while (and (< (float-time) deadline)
                (not (setq buf (get-buffer
                                "*docker:exec:eldocker-ticker*"))))
      (sit-for 0.1))
    (when buf
      (pop-to-buffer buf)
      (sit-for 1.5)
      (let ((proc (get-buffer-process buf)))
        (when proc
          (demo--type proc "whoami\n")        (sit-for 0.6)
          (demo--type proc "hostname\n")      (sit-for 0.6)
          (demo--type proc "uname -a\n")      (sit-for 0.8)
          (demo--type proc "echo hello from eltainer\n")
          (sit-for 2.2)
          (demo--type proc "exit\n")))
      (sit-for 1.5)))
  (kill-emacs 0))

(run-at-time 0.3 nil #'demo--run)

;;; demo-init.el ends here
