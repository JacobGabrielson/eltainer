;;; test-eltainer-dired.el --- Tests for the shared dired-mode parent -*- lexical-binding: t -*-
;;
;; Path parsing, name resolution, and the `-F'-listing-switches
;; regression that ate the last char of every filename.  No HTTP /
;; daemon needed; the listing is rendered straight from synthetic
;; `eltainer-fs-entry's.

(require 'ert)
(require 'eltainer-dired)
(require 'eltainer-fs)

;;; ---------------------------------------------------------------------------
;;; Sentinel-path parser

(ert-deftest eltainer-dired/parse-docker-path ()
  (let ((p (eltainer-dired-parse-path "/docker:my-app:/etc/nginx")))
    (should (eq 'docker (plist-get p :backend)))
    (should (equal "my-app" (plist-get p :container)))
    (should (equal "/etc/nginx" (plist-get p :remote)))))

(ert-deftest eltainer-dired/parse-k8s-path-with-container ()
  (let ((p (eltainer-dired-parse-path "/k8s:default/web-0[nginx]:/var/log")))
    (should (eq 'k8s (plist-get p :backend)))
    (should (equal "default"   (plist-get p :ns)))
    (should (equal "web-0"     (plist-get p :pod)))
    (should (equal "nginx"     (plist-get p :pod-container)))
    (should (equal "/var/log"  (plist-get p :remote)))))

(ert-deftest eltainer-dired/parse-k8s-path-no-container ()
  (let ((p (eltainer-dired-parse-path "/k8s:kube-system/coredns-abc:/")))
    (should (eq 'k8s (plist-get p :backend)))
    (should (equal "kube-system" (plist-get p :ns)))
    (should (equal "coredns-abc" (plist-get p :pod)))
    (should (null (plist-get p :pod-container)))
    (should (equal "/" (plist-get p :remote)))))

(ert-deftest eltainer-dired/parse-rejects-non-sentinel ()
  (should-not (eltainer-dired-parse-path "/etc/passwd"))
  (should-not (eltainer-dired-parse-path "/tmp"))
  (should-not (eltainer-dired-parse-path nil)))

(ert-deftest eltainer-dired/build-paths-round-trip ()
  (should (equal "/docker:nginx:/etc"
                 (eltainer-dired-make-docker-path "nginx" "/etc")))
  (should (equal "/k8s:default/web-0[c1]:/var"
                 (eltainer-dired-make-k8s-path "default" "web-0" "c1" "/var")))
  (should (equal "/k8s:default/web-0:/var"
                 (eltainer-dired-make-k8s-path "default" "web-0" nil "/var"))))

;;; ---------------------------------------------------------------------------
;;; Name resolution (string surgery — must NOT touch `expand-file-name')

(ert-deftest eltainer-dired/resolve-name-relative ()
  (with-temp-buffer
    (setq-local eltainer-dired--remote-dir "/etc")
    (should (equal "/etc/hosts" (eltainer-dired--resolve-name "hosts")))))

(ert-deftest eltainer-dired/resolve-name-dotdot ()
  (with-temp-buffer
    (setq-local eltainer-dired--remote-dir "/etc/ssl")
    (should (equal "/etc" (eltainer-dired--resolve-name "..")))
    (setq-local eltainer-dired--remote-dir "/")
    (should (equal "/" (eltainer-dired--resolve-name "..")))))

(ert-deftest eltainer-dired/resolve-name-absolute ()
  (with-temp-buffer
    (setq-local eltainer-dired--remote-dir "/etc")
    (should (equal "/var/log" (eltainer-dired--resolve-name "/var/log")))))

(ert-deftest eltainer-dired/resolve-name-from-root ()
  (with-temp-buffer
    (setq-local eltainer-dired--remote-dir "/")
    (should (equal "/bin" (eltainer-dired--resolve-name "bin")))))

;;; ---------------------------------------------------------------------------
;;; Emit + dired round-trip: regression for the `-F'-eats-last-char bug

(defun test-eltainer-dired--make-entry (type name &optional link)
  (eltainer-fs-entry--new
   :name name :type type
   :mode-string (if (eq type 'directory) "rwxr-xr-x" "rw-r--r--")
   :nlink 1 :owner "root" :group "root"
   :size 4096 :mtime 1700000000
   :link-target link))

(defun test-eltainer-dired--setup-listing (entries switches)
  "Render ENTRIES into the current buffer as `eltainer-dired-mode' would,
under the given dired SWITCHES (\"-al\" / \"-alF\" / etc).  Returns the
list of name extracted from the buffer line-by-line via
`dired-get-filename'."
  (eltainer-dired-mode)
  (setq-local default-directory "/docker:test:/")
  (setq-local dired-actual-switches switches)
  (eltainer-dired--render entries)
  (goto-char (point-min))
  (let (names)
    (while (not (eobp))
      (let ((n (ignore-errors (dired-get-filename 'verbatim t))))
        (when n (push (file-name-nondirectory (directory-file-name n))
                      names)))
      (forward-line 1))
    (nreverse names)))

(ert-deftest eltainer-dired/round-trip-plain-switches ()
  "With `-al' switches, every emitted name round-trips through `dired-get-filename'."
  (let ((entries (list (test-eltainer-dired--make-entry 'directory "bin")
                       (test-eltainer-dired--make-entry 'directory "etc")
                       (test-eltainer-dired--make-entry 'file "hostname"))))
    (with-temp-buffer
      (let ((names (test-eltainer-dired--setup-listing entries "-al")))
        (should (member "bin" names))
        (should (member "etc" names))
        (should (member "hostname" names))))))

(ert-deftest eltainer-dired/round-trip-survives-F-switch ()
  "Regression: the mode pins `dired-actual-switches' to `-al' so dired
doesn't back-step over a non-existent `-F' type-indicator and eat the
last char of every name (`bin' -> `bi').  We assert by SIMULATING the
buggy environment: render with `-alF' as the user's default, then verify
the mode entry function reset it to `-al' and names come back intact."
  (let ((entries (list (test-eltainer-dired--make-entry 'directory "bin")
                       (test-eltainer-dired--make-entry 'file "hostname"))))
    (with-temp-buffer
      (setq-default dired-listing-switches "-alF")
      (unwind-protect
          (let ((names (test-eltainer-dired--setup-listing entries "-al")))
            ;; The fix: mode forces -al and names are intact.
            (should (member "bin" names))
            (should (member "hostname" names))
            (should-not (member "bi" names))
            (should-not (member "hostnam" names)))
        (setq-default dired-listing-switches "-al")))))

(provide 'test-eltainer-dired)
;;; test-eltainer-dired.el ends here
