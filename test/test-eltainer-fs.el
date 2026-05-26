;;; test-eltainer-fs.el --- Tests for the shared FS-listing primitives -*- lexical-binding: t -*-
;;
;; Pure-elisp tests: exercise the parsers, the rwx-bitmap conversion
;; and the distroless-detection branch of `eltainer-fs-check-failure'
;; without touching any HTTP seam.

(require 'ert)
(require 'eltainer-fs)

;;; ---------------------------------------------------------------------------
;;; Parsers

(ert-deftest eltainer-fs/parse-list-line-regular ()
  "One regular-file line round-trips into an `eltainer-fs-entry'."
  (let* ((raw (concat "regular file\t755\t1234\t1700000000\t"
                      "root\troot\t1\t/etc/hosts\t\n"))
         (entries (eltainer-fs-parse-list-output raw))
         (e (car entries)))
    (should (= 1 (length entries)))
    (should (eq 'file (eltainer-fs-entry-type e)))
    (should (equal "rwxr-xr-x" (eltainer-fs-entry-mode-string e)))
    (should (= 1234 (eltainer-fs-entry-size e)))
    (should (= 1700000000 (eltainer-fs-entry-mtime e)))
    (should (equal "root" (eltainer-fs-entry-owner e)))
    (should (equal "hosts" (eltainer-fs-entry-name e))) ; basename-only for list
    (should (null (eltainer-fs-entry-link-target e)))))

(ert-deftest eltainer-fs/parse-list-symlink ()
  "Symlink line populates `link-target'."
  (let* ((raw (concat "symbolic link\t777\t7\t1700000000\t"
                      "root\troot\t1\t/bin\tusr/bin\n"))
         (e (car (eltainer-fs-parse-list-output raw))))
    (should (eq 'symlink (eltainer-fs-entry-type e)))
    (should (equal "rwxrwxrwx" (eltainer-fs-entry-mode-string e)))
    (should (equal "usr/bin" (eltainer-fs-entry-link-target e)))))

(ert-deftest eltainer-fs/parse-list-multiple-and-empty-lines ()
  "Multiple entries; trailing blank line tolerated."
  (let* ((raw (concat "regular file\t644\t0\t1\troot\troot\t1\t/a\t\n"
                      "directory\t755\t4096\t2\troot\troot\t2\t/b\t\n"
                      "\n"))
         (entries (eltainer-fs-parse-list-output raw)))
    (should (= 2 (length entries)))
    (should (eq 'file      (eltainer-fs-entry-type (nth 0 entries))))
    (should (eq 'directory (eltainer-fs-entry-type (nth 1 entries))))))

(ert-deftest eltainer-fs/parse-stat-keeps-full-path ()
  "Stat output preserves the full path in :name (vs basename-only for list)."
  (let* ((raw (concat "directory\t755\t4096\t1700000000\t"
                      "root\troot\t3\t/var/log\t\n"))
         (e (eltainer-fs-parse-stat-output raw)))
    (should (eq 'directory (eltainer-fs-entry-type e)))
    (should (equal "/var/log" (eltainer-fs-entry-name e)))))

(ert-deftest eltainer-fs/parse-list-malformed-raises ()
  "A short-of-9-fields line raises rather than producing a half-entry."
  (should-error (eltainer-fs-parse-list-output "too\tfew\tfields\n")))

;;; ---------------------------------------------------------------------------
;;; Distroless detection

(ert-deftest eltainer-fs/check-failure-distroless ()
  "Distroless-style runtime error gets the friendly message, not OCI noise."
  (let ((err (should-error
              (eltainer-fs-check-failure
               "list /"
               :exit-code nil
               :message (concat "OCI runtime exec failed: exec failed: "
                                "unable to start container process: "
                                "exec: \"sh\": executable file not found "
                                "in $PATH: unknown"))
              :type 'error)))
    (should (string-match-p "distroless or scratch image"
                            (cadr err)))))

(ert-deftest eltainer-fs/check-failure-generic ()
  "A non-distroless failure surfaces the stderr verbatim, trimmed."
  (let ((err (should-error
              (eltainer-fs-check-failure
               "list /bogus"
               :exit-code 1
               :stderr "  eltainer-fs: not a directory: /bogus\n")
              :type 'error)))
    (should (string-match-p "not a directory: /bogus" (cadr err)))))

(ert-deftest eltainer-fs/check-failure-success ()
  "Exit-code 0 (docker) and status \"Success\" (k8s) both no-op."
  (should-not (eltainer-fs-check-failure "ok-docker" :exit-code 0))
  (should-not (eltainer-fs-check-failure "ok-k8s"    :status "Success")))

(provide 'test-eltainer-fs)
;;; test-eltainer-fs.el ends here
