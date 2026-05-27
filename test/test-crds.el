;;; test-crds.el --- Tests for k8s-crds JSONPath subset -*- lexical-binding: t -*-

(require 'ert)
(require 'k8s-crds)

;;; ---------------------------------------------------------------------------
;;; Tokenizer

(ert-deftest crds/tokenize-dotted ()
  (should (equal '((key "metadata") (key "name"))
                 (k8s-crds--tokenize ".metadata.name")))
  (should (equal '((key "spec") (key "replicas"))
                 (k8s-crds--tokenize ".spec.replicas"))))

(ert-deftest crds/tokenize-index ()
  (should (equal '((key "status") (key "addresses") (index 0) (key "address"))
                 (k8s-crds--tokenize ".status.addresses[0].address"))))

(ert-deftest crds/tokenize-filter ()
  (should (equal '((key "status")
                   (key "conditions")
                   (filter "type" "==" "Ready")
                   (key "status"))
                 (k8s-crds--tokenize
                  ".status.conditions[?(@.type==\"Ready\")].status"))))

(ert-deftest crds/tokenize-rejects-unknown ()
  (should-not (k8s-crds--tokenize ".status.foo[*]"))
  (should-not (k8s-crds--tokenize ".bogus()sytax")))

;;; ---------------------------------------------------------------------------
;;; Evaluator

(defconst crds-test--obj
  '((metadata . ((name . "my-pod") (creationTimestamp . "2026-05-25T10:00:00Z")))
    (spec . ((replicas . 3)
             (addresses . [((address . "10.0.0.1")) ((address . "10.0.0.2"))])))
    (status . ((conditions . [((type . "Initialized") (status . "True"))
                              ((type . "Ready")       (status . "False")
                               (message . "ContainersNotReady"))])))))

(ert-deftest crds/eval-dotted ()
  (should (equal "my-pod"
                 (k8s-crds--eval-jsonpath ".metadata.name" crds-test--obj)))
  (should (= 3 (k8s-crds--eval-jsonpath ".spec.replicas" crds-test--obj))))

(ert-deftest crds/eval-array-index ()
  (should (equal "10.0.0.2"
                 (k8s-crds--eval-jsonpath
                  ".spec.addresses[1].address" crds-test--obj))))

(ert-deftest crds/eval-filter ()
  "Equality filter resolves to the right struct, then keeps drilling."
  (should (equal "False"
                 (k8s-crds--eval-jsonpath
                  ".status.conditions[?(@.type==\"Ready\")].status"
                  crds-test--obj)))
  (should (equal "ContainersNotReady"
                 (k8s-crds--eval-jsonpath
                  ".status.conditions[?(@.type==\"Ready\")].message"
                  crds-test--obj))))

(ert-deftest crds/eval-missing-path-returns-nil ()
  (should-not (k8s-crds--eval-jsonpath ".spec.nope" crds-test--obj))
  (should-not (k8s-crds--eval-jsonpath
               ".status.conditions[?(@.type==\"Unknown\")].status"
               crds-test--obj)))

;;; ---------------------------------------------------------------------------
;;; Cell renderer

(ert-deftest crds/render-cell-date ()
  "`type: date' renders through the age formatter."
  (let* ((col '((name . "Age") (type . "date")
                (jsonPath . ".metadata.creationTimestamp")))
         (txt (substring-no-properties
               (k8s-crds--render-cell col crds-test--obj))))
    ;; Should end in d/h/m/s (e.g., \"2d\").
    (should (string-match-p "[dhms]\\'" txt))))

(ert-deftest crds/render-cell-string ()
  (let ((col '((name . "Name") (type . "string")
               (jsonPath . ".metadata.name"))))
    (should (equal "my-pod"
                   (k8s-crds--render-cell col crds-test--obj)))))

(ert-deftest crds/render-cell-nil-becomes-empty ()
  (let ((col '((name . "Foo") (type . "string") (jsonPath . ".no.way"))))
    (should (equal "" (k8s-crds--render-cell col crds-test--obj)))))

(provide 'test-crds)
;;; test-crds.el ends here
