;;; test-k8s-fs.el --- Live-cluster tests for k8s-fs -*- lexical-binding: t -*-
;;
;; Mirrors the docker-side integration tests: pick any running pod with
;; a working shell, run the listing script in it, assert reasonable
;; entries.  Skips silently if no kubeconfig / no pods are around.

(require 'ert)
(require 'cl-lib)
(require 'k8s-api)
(require 'k8s-fs)
(require 'k8s-pods)

(defun test-k8s-fs--first-shell-pod (conn)
  "Return (NS . NAME) for any Running pod with a working `sh',
or nil.  Iterates the default namespace first; falls back to
walking every namespace.  Used to keep these tests opt-in."
  (cl-loop for ns in (or (and (k8s-list-pods conn "default") '("default"))
                         (mapcar #'k8s--resource-name
                                 (append (k8s-list-namespaces conn) nil)))
           thereis
           (cl-loop for pod across (or (k8s-list-pods conn ns) [])
                    for name = (k8s--resource-name pod)
                    for phase = (cdr (assq 'phase (cdr (assq 'status pod))))
                    when (equal phase "Running")
                    thereis
                    (let ((r (ignore-errors
                               (k8s-exec conn ns name nil
                                         '("sh" "-c" "echo ok")))))
                      (and r (eql 0 (k8s-exec-result-exit-code r))
                           (equal "ok\n" (k8s-exec-result-stdout r))
                           (cons ns name))))))

(ert-deftest k8s-fs/list-root-of-live-pod ()
  "Live-cluster: list `/' in any Running pod with `sh'."
  (let* ((path (ignore-errors (expand-file-name "~/.kube/config")))
         (conn (and path (file-readable-p path)
                    (ignore-errors (k8s-connection-open path))))
         (target (and conn (test-k8s-fs--first-shell-pod conn))))
    (skip-unless target)
    (let* ((entries (k8s-fs-list conn (car target) (cdr target) nil "/"))
           (names (mapcar #'eltainer-fs-entry-name entries)))
      (should (> (length entries) 0))
      (should (cl-some (lambda (n) (member n names))
                       '("etc" "bin" "usr" "var" "tmp" "proc"))))))

(ert-deftest k8s-fs/cat-etc-hostname ()
  "Live-cluster: cat `/etc/hostname' in a Running pod."
  (let* ((path (ignore-errors (expand-file-name "~/.kube/config")))
         (conn (and path (file-readable-p path)
                    (ignore-errors (k8s-connection-open path))))
         (target (and conn (test-k8s-fs--first-shell-pod conn))))
    (skip-unless target)
    (let ((bytes (k8s-fs-cat conn (car target) (cdr target) nil "/etc/hostname")))
      (should (stringp bytes))
      (should (> (length bytes) 0)))))

(provide 'test-k8s-fs)
;;; test-k8s-fs.el ends here
