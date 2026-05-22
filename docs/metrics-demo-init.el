;;; metrics-demo-init.el --- Scripted metrics demo of eltainer -*- lexical-binding: t -*-
;;
;; Drives an asciinema-recordable tour of the resource-metrics gauges:
;;
;;   1. `M-x eltainer'  -> dashboard
;;   2. `c'             -> docker containers
;;   3. TAB `eltainer-load' -> live CPU / memory / network gauges
;;   4. `M'             -> the focused per-container metrics buffer
;;   5. `k'             -> kubernetes pods (kind cluster)
;;   6. TAB `flux-box'  -> CPU / memory / disk gauges + network sparkline
;;   7. node-metrics view -> per-node CPU / memory / filesystem
;;   8. kill emacs so asciinema's `rec --command' terminates
;;
;; Invoked by `docs/record-demo.sh metrics'.

(setq package-load-list '(all))
(package-initialize)

(defconst demo--this-dir
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst demo--repo-root
  (file-name-directory (directory-file-name demo--this-dir)))
(add-to-list 'load-path demo--repo-root)
(require 'eltainer)

;; The kind cluster carries the `flux-box' sentinel.  Poll metrics fast
;; (every 3s instead of 15s) so the gauges populate within the demo.
(setq k8s-kubeconfig-path (expand-file-name "~/.kube/configs/config-kind"))
(setq k8s-context-override "kind-eltainer-test")
(setq docker-metrics-refresh-interval 3
      k8s-metrics-refresh-interval 3)

(setq inhibit-startup-screen t
      ring-bell-function 'ignore
      use-dialog-box nil)
(when (fboundp 'menu-bar-mode) (menu-bar-mode -1))
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(when (fboundp 'blink-cursor-mode) (blink-cursor-mode -1))
(ignore-errors (load-theme 'dracula t))

(defun demo--press (key &optional pause)
  "Press KEY in the selected window, then pause."
  (execute-kbd-macro (kbd key))
  (sit-for (or pause 0.6)))

(defun demo--goto-container (name)
  "Move point to the `docker-container' section named NAME."
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
  "Move point to the k8s `pod' section named NAME."
  (goto-char (point-min))
  (let (target)
    (while (and (not target) (not (eobp)))
      (let ((sec (get-text-property (point) 'magit-section)))
        (when (and sec (eq (oref sec type) 'pod))
          (let ((val (ignore-errors (oref sec value))))
            (when (equal (cdr (assq 'name (cdr (assq 'metadata val)))) name)
              (setq target (point))))))
      (forward-line 1))
    (when target (goto-char target))
    target))

(defun demo--metrics-run ()
  (condition-case err
      (progn
        ;; --- Docker container metrics --------------------------------
        (eltainer)
        (sit-for 1.8)
        (demo--press "c" 1.5)                  ; -> docker containers
        (pop-to-buffer "*docker:containers*")
        (when (demo--goto-container "eltainer-load")
          (sit-for 0.6)
          (demo--press "TAB" 0.6)              ; expand -> gauges
          (sit-for 9.0))                       ; ~3 polls fill + refresh
        (demo--press "M" 0.5)                  ; per-container metrics buffer
        (sit-for 4.5)
        (demo--press "q" 0.6)                  ; back to the containers view
        ;; --- Kubernetes pod metrics ----------------------------------
        (eltainer)
        (sit-for 1.2)
        (demo--press "k" 0.5)                  ; -> k8s pods (kind cluster)
        (let ((deadline (+ (float-time) 8.0)) buf)
          (while (and (< (float-time) deadline)
                      (not (setq buf (get-buffer "*k8s:pods*"))))
            (sit-for 0.1))
          (when buf
            (pop-to-buffer buf)
            (sit-for 1.0)
            (when (demo--goto-pod "flux-box")
              (sit-for 0.6)
              (demo--press "TAB" 0.6)          ; expand -> gauges + net spark
              (sit-for 10.0))
            ;; --- Node metrics view ----------------------------------
            (k8s-nodes-metrics)
            (sit-for 5.0)))
        (kill-emacs 0))
    (error
     (message "metrics demo: aborting on error: %S" err)
     (sit-for 1.5)
     (kill-emacs 1))))

;; Hard deadline so a hung demo can't park asciinema forever.
(run-at-time 120 nil
             (lambda ()
               (message "metrics demo: hard timeout, killing")
               (kill-emacs 2)))

(run-at-time 0.3 nil #'demo--metrics-run)

;;; metrics-demo-init.el ends here
