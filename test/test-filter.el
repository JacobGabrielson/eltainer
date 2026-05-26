;;; test-filter.el --- Tests for the shared filter module -*- lexical-binding: t -*-

(require 'ert)
(require 'eltainer-filter)

(ert-deftest filter/empty-p-on-fresh ()
  (let ((f (eltainer-filter-make)))
    (should (eltainer-filter-empty-p f))))

(ert-deftest filter/empty-p-after-setting ()
  (let ((f (eltainer-filter-make)))
    (setf (eltainer-filter-label-selector f) "tier=frontend")
    (should-not (eltainer-filter-empty-p f))
    (setf (eltainer-filter-label-selector f) nil)
    (should (eltainer-filter-empty-p f))))

(ert-deftest filter/format-shows-both-when-set ()
  (let ((f (eltainer-filter-make)))
    (setf (eltainer-filter-label-selector f) "tier=frontend"
          (eltainer-filter-name-regex f) "^web-")
    (let ((s (eltainer-filter-format f)))
      (should (string-match-p "label:tier=frontend" s))
      (should (string-match-p "name:\\^web-" s)))))

(ert-deftest filter/format-empty-is-empty-string ()
  (should (equal "" (eltainer-filter-format (eltainer-filter-make))))
  (should (equal "" (eltainer-filter-format nil))))

(ert-deftest filter/name-match-with-no-regex-passes-everything ()
  (let ((f (eltainer-filter-make)))
    (should (eltainer-filter-match-name-p f "anything"))
    (should (eltainer-filter-match-name-p f ""))
    (should (eltainer-filter-match-name-p nil "anything"))))

(ert-deftest filter/name-match-regex-applied ()
  (let ((f (eltainer-filter-make)))
    (setf (eltainer-filter-name-regex f) "^web-")
    (should (eltainer-filter-match-name-p f "web-0"))
    (should-not (eltainer-filter-match-name-p f "api-0"))))

;;; --- k8s URL builder integration ------------------------------------------

(require 'k8s-api)

(ert-deftest filter/k8s--list-path-with-selector ()
  "`k8s--list-path' URL-encodes the selector and appends it as a query."
  (let ((path (k8s--list-path 'pods "default" "tier=frontend,env!=dev")))
    (should (string-match-p "/api/v1/namespaces/default/pods" path))
    (should (string-match-p "labelSelector=" path))
    ;; `=' and `,' get URL-encoded.
    (should (string-match-p "tier%3Dfrontend" path))
    (should (string-match-p "%2Cenv%21%3Ddev" path))))

(ert-deftest filter/k8s--list-path-no-selector ()
  "No selector ⇒ no `?labelSelector=' query in the URL."
  (let ((path (k8s--list-path 'pods "default")))
    (should-not (string-match-p "labelSelector" path))))

(provide 'test-filter)
;;; test-filter.el ends here
