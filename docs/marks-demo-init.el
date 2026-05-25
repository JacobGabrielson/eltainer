;;; marks-demo-init.el --- Scripted marks + multilog demo -*- lexical-binding: t -*-
;;
;; Drives an asciinema-recordable tour of dired-style marks and the
;; stern-style multipod log tail:
;;
;;   1. `M-x eltainer'    -> dashboard
;;   2. `k'               -> k8s pods (kind cluster)
;;   3. point on a `chatty' pod -> `m' to mark + advance (x2)
;;   4. `L'               -> multi-pod multilog buffer (two colours)
;;   5. watch a few seconds of interleaved colored output
;;   6. kill emacs so asciinema's `rec --command' terminates
;;
;; Invoked by `docs/record-demo.sh marks'.

(setq package-load-list '(all))
(package-initialize)

(defconst demo--this-dir
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst demo--repo-root
  (file-name-directory (directory-file-name demo--this-dir)))
(add-to-list 'load-path demo--repo-root)
(require 'eltainer)

(setq k8s-kubeconfig-path (expand-file-name "~/.kube/configs/config-kind"))
(setq k8s-context-override "kind-eltainer-test")
;; Shorter tail so the multilog buffer starts producing within the
;; demo window.
(setq k8s-multilog-tail-lines 3)

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

(defun demo--goto-pod-matching (rx)
  "Move point to the first `pod' section whose name matches RX.
Returns the buffer position, or nil."
  (goto-char (point-min))
  (let (target)
    (while (and (not target) (not (eobp)))
      (let ((sec (get-text-property (point) 'magit-section)))
        (when (and sec (eq (oref sec type) 'pod))
          (let* ((val (ignore-errors (oref sec value)))
                 (name (cdr (assq 'name (cdr (assq 'metadata val))))))
            (when (and name (string-match-p rx name))
              (setq target (point))))))
      (forward-line 1))
    (when target (goto-char target))
    target))

(defun demo--marks-run ()
  (condition-case err
      (progn
        (eltainer)
        (sit-for 1.5)
        (demo--press "k" 0.6)                  ; -> k8s pods
        (let ((deadline (+ (float-time) 8.0)) buf)
          (while (and (< (float-time) deadline)
                      (not (setq buf (get-buffer "*k8s:pods*"))))
            (sit-for 0.1))
          (when buf
            (pop-to-buffer buf)
            (sit-for 1.2)
            ;; Mark the first chatty pod, advance, mark the next.
            (when (demo--goto-pod-matching "\\`chatty-")
              (sit-for 0.8)
              (demo--press "m" 0.7)            ; mark + advance to next pod
              (when (demo--goto-pod-matching "\\`chatty-")
                (sit-for 0.6)
                (demo--press "m" 0.7))         ; second mark
              (sit-for 1.0)
              ;; Fire the multipod tail.
              (demo--press "L" 1.0)
              ;; Let coloured lines interleave for a few seconds.
              (sit-for 10.0))))
        (kill-emacs 0))
    (error
     (message "marks demo: aborting on error: %S" err)
     (sit-for 1.5)
     (kill-emacs 1))))

;; Hard deadline so a hung demo can't park asciinema forever.
(run-at-time 60 nil
             (lambda ()
               (message "marks demo: hard timeout, killing")
               (kill-emacs 2)))

(run-at-time 0.3 nil #'demo--marks-run)

;;; marks-demo-init.el ends here
