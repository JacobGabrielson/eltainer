;;; demo-init.el --- Scripted demo of eltainer (docker + k8s) -*- lexical-binding: t -*-
;;
;; Drives a single asciinema-recordable scenario that exercises BOTH
;; backends in one Emacs session:
;;
;;   1. `M-x eltainer'    — dashboard listing both backends
;;   2. `c'               — docker containers view
;;   3. move to eldocker-ticker, `e' → RET → /bin/sh in the container
;;   4. run a few shell commands; exit the shell
;;   5. switch back to the dashboard
;;   6. `k'               — kubernetes pods view (against the test kind cluster)
;;   7. let the page render so the magit-section pods listing is visible
;;   8. kill emacs so asciinema's `rec --command' terminates
;;
;; Invoked by docs/record-demo.sh.

(setq package-load-list '(all))
(package-initialize)

;; Locate the repo root containing THIS file.
(defconst demo--this-dir
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst demo--repo-root
  (file-name-directory (directory-file-name demo--this-dir)))

(add-to-list 'load-path demo--repo-root)
(require 'eltainer)

;; Point the k8s side at the test cluster fixture so we don't depend on
;; the user's real kubeconfig.
(setq k8s-kubeconfig-path
      (expand-file-name "test/k8s/test-kubeconfig.yaml" demo--repo-root))

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

(defun demo--docker-segment ()
  "Phase 1: dashboard → containers → exec."
  (eltainer)                                ; dashboard
  (sit-for 2.0)
  (demo--press "c" 1.5)                     ; → docker containers
  (with-current-buffer "*docker:containers*"
    (goto-char (point-min))
    (when (re-search-forward "eldocker-ticker" nil t)
      (beginning-of-line)
      (forward-char 2))
    (sit-for 0.8)
    (demo--press "e" 0.4)                   ; exec into container
    (demo--press "RET" 0.4))                ; accept "/bin/sh" default
  (let ((deadline (+ (float-time) 5.0))
        (buf nil))
    (while (and (< (float-time) deadline)
                (not (setq buf (get-buffer
                                "*docker:exec:eldocker-ticker*"))))
      (sit-for 0.1))
    (when buf
      (pop-to-buffer buf)
      (sit-for 1.2)
      (let ((proc (get-buffer-process buf)))
        (when proc
          (demo--type proc "whoami\n")            (sit-for 0.5)
          (demo--type proc "hostname\n")          (sit-for 0.5)
          (demo--type proc "echo hello from eltainer\n")
          (sit-for 1.4)
          (demo--type proc "exit\n")))
      (sit-for 1.0)
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer buf))))))

(defun demo--k8s-segment ()
  "Phase 2: dashboard → k8s pods."
  (eltainer)                                ; back to dashboard
  (sit-for 1.4)
  (demo--press "k" 0.4)                     ; → k8s pods
  (let ((deadline (+ (float-time) 8.0))
        (buf nil))
    (while (and (< (float-time) deadline)
                (not (setq buf (get-buffer "*k8s:pods*"))))
      (sit-for 0.1))
    (when buf
      (with-current-buffer buf
        (goto-char (point-min))
        (sit-for 2.8))))                    ; let viewer read the pods
  (sit-for 0.5))

(defun demo--run ()
  (demo--docker-segment)
  (demo--k8s-segment)
  (kill-emacs 0))

(run-at-time 0.3 nil #'demo--run)

;;; demo-init.el ends here
