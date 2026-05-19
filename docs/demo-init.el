;;; demo-init.el --- Scripted demo of eltainer (docker + k8s + switch) -*- lexical-binding: t -*-
;;
;; Drives a single asciinema-recordable scenario covering all three
;; pillars of the post-merge eltainer UI:
;;
;;   1. `M-x eltainer'    — dashboard listing both backends + active context
;;   2. `c'               — docker containers view
;;   3. move to eltainer-ticker, `e' → RET → /bin/sh in the container
;;   4. run a few shell commands; exit the shell
;;   5. back to the dashboard, press `b' to switch k8s context
;;   6. pick the kind cluster from the context picker
;;   7. press `k' — kubernetes pods view, now showing the kind cluster
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

;; Discovery already scans ~/.kube and ~/.kube/configs/ (see
;; `eltainer-kubeconfig-search-dirs').  Pin the initial context to
;; microk8s so the switch to kind-eltainer-test in the demo is visible.
(setq k8s-kubeconfig-path
      (expand-file-name "~/.kube/configs/config-microk8s"))
(setq k8s-context-override "microk8s")

;; Minimal cosmetic setup so the recording is uncluttered.
(setq inhibit-startup-screen t
      ring-bell-function 'ignore
      use-dialog-box nil)
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

(defun demo--goto-container (name)
  "Move point to the magit-section heading of the container named NAME.
Walks sections rather than text-searching the buffer so we land on
the actual `docker-container' section instead of, say, a `Command:'
line that happens to contain NAME."
  (goto-char (point-min))
  (let (target)
    (while (and (not target) (not (eobp)))
      (let ((sec (get-text-property (point) 'magit-section)))
        (when sec
          (let ((val (ignore-errors (oref sec value))))
            (when (and (docker-container-p val)
                       (equal (docker-container-name val) name))
              (setq target (point))))))
      (forward-line 1))
    (when target (goto-char target))
    target))

(defun demo--goto-pod (name)
  "Move point to the magit-section heading of the k8s pod named NAME."
  (goto-char (point-min))
  (let (target)
    (while (and (not target) (not (eobp)))
      (let ((sec (get-text-property (point) 'magit-section)))
        (when (and sec (eq (oref sec type) 'pod))
          (let ((val (ignore-errors (oref sec value))))
            (when (equal (cdr (assq 'name (cdr (assq 'metadata val))))
                         name)
              (setq target (point))))))
      (forward-line 1))
    (when target (goto-char target))
    target))

(defun demo--docker-segment ()
  "Phase 1: dashboard → containers → exec."
  (eltainer)                                ; dashboard
  (sit-for 2.0)
  (demo--press "c" 1.5)                     ; → docker containers
  (pop-to-buffer "*docker:containers*")
  (unless (demo--goto-container "eltainer-ticker")
    (error "demo: `eltainer-ticker' container not found in buffer"))
  (sit-for 0.8)
  (demo--press "e" 0.4)                     ; exec into container
  (demo--press "RET" 0.4)                   ; accept "/bin/sh" default
  (let ((deadline (+ (float-time) 5.0))
        (buf nil))
    (while (and (< (float-time) deadline)
                (not (setq buf (get-buffer
                                "*docker:exec:eltainer-ticker*"))))
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
  "Phase 2: dashboard shows current context → switch via `b' → pods view."
  (eltainer)                                ; back to dashboard
  (sit-for 1.6)                             ; viewer sees Context line
  ;; Press `b' to open the context picker; visible to the viewer.
  (demo--press "b" 1.0)
  (let ((picker (get-buffer "*eltainer:contexts*")))
    (when picker
      (pop-to-buffer picker)
      (with-current-buffer picker
        (goto-char (point-min))
        (when (re-search-forward "kind-eltainer-test" nil t)
          (beginning-of-line)))
      (sit-for 1.0)
      (demo--press "RET" 0.4)))
  (sit-for 1.8)                             ; viewer sees the new Context line
  (demo--press "k" 0.4)                     ; → k8s pods on the kind cluster
  (let ((deadline (+ (float-time) 8.0))
        (buf nil))
    (while (and (< (float-time) deadline)
                (not (setq buf (get-buffer "*k8s:pods*"))))
      (sit-for 0.1))
    (when buf
      (pop-to-buffer buf)
      (sit-for 1.5)                         ; viewer reads the pod list
      ;; Navigate to the log-ticker pod and stream its logs.
      (when (demo--goto-pod "log-ticker")
        (sit-for 0.6)
        (demo--press "l" 0.4)               ; tail logs
        (let ((dl (+ (float-time) 5.0)) lbuf)
          (while (and (< (float-time) dl)
                      (not (setq lbuf
                                 (cl-find-if
                                  (lambda (b)
                                    (string-prefix-p
                                     "*k8s:logs:default/log-ticker"
                                     (buffer-name b)))
                                  (buffer-list)))))
            (sit-for 0.1))
          (when lbuf
            (pop-to-buffer lbuf)
            (sit-for 3.5))                  ; let a few tick lines stream
          (demo--press "q" 0.6)))))         ; quit the log buffer
  (sit-for 0.5))

(defun demo--run ()
  (condition-case err
      (progn
        (demo--docker-segment)
        (demo--k8s-segment)
        (kill-emacs 0))
    (error
     (message "demo: aborting on error: %S" err)
     (sit-for 1.5)
     (kill-emacs 1))))

;; Hard deadline so a hung demo doesn't leave asciinema parked forever.
(run-at-time 60 nil
             (lambda ()
               (message "demo: hard timeout, killing")
               (kill-emacs 2)))

(run-at-time 0.3 nil #'demo--run)

;;; demo-init.el ends here
