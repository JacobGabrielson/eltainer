;;; run-tests.el --- Batch entry point for ERT  -*- lexical-binding: t -*-
;;
;; Usage:
;;   emacs -Q --batch -l test/run-tests.el unit       # pure-elisp only
;;   emacs -Q --batch -l test/run-tests.el integration  # + docker / k8s suites
;;
;; The `integration' mode loads everything under test/, test/docker/
;; and test/k8s/.  Live-daemon tests `skip-unless' a working daemon /
;; cluster so they no-op cleanly when the box doesn't have one.

(let ((repo-root (file-name-directory
                  (directory-file-name
                   (file-name-directory (or load-file-name buffer-file-name))))))
  (dolist (d '("." "docker" "k8s" "test"))
    (add-to-list 'load-path (expand-file-name d repo-root))))

(let ((elpa (expand-file-name "~/.emacs.d/elpa")))
  (when (file-directory-p elpa)
    (dolist (p (directory-files elpa t "^[a-z]"))
      (when (file-directory-p p) (add-to-list 'load-path p)))))

(require 'ert)

(defun eltainer--load-tests-in (dir)
  (dolist (f (directory-files dir t "^test-.*\\.el\\'"))
    (load f)))

(let* ((mode (or (getenv "ELTAINER_TEST_MODE") "unit"))
       (test-dir (expand-file-name "test"
                                   (file-name-directory
                                    (directory-file-name
                                     (file-name-directory
                                      (or load-file-name buffer-file-name)))))))
  (message "eltainer tests: mode=%s test-dir=%s" mode test-dir)
  (eltainer--load-tests-in test-dir)
  (when (member mode '("integration" "all"))
    (eltainer--load-tests-in (expand-file-name "docker" test-dir))
    (eltainer--load-tests-in (expand-file-name "k8s" test-dir)))
  (ert-run-tests-batch-and-exit))
