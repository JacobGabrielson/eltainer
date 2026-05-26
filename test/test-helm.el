;;; test-helm.el --- Tests for k8s-helm release decoding -*- lexical-binding: t -*-
;;
;; We hand-construct a Helm 3 release Secret on the fly (encode the
;; same way helm/pkg/storage/driver/util.go does — base64 outside,
;; gzip + base64 inside the data.release field) and verify the
;; decoder round-trips back to the original alist.  No live cluster
;; required.

(require 'ert)
(require 'cl-lib)
(require 'k8s-helm)

;;; ---------------------------------------------------------------------------
;;; Encoder mirror (test-only — we never call this from production)

(defun test-helm--gzip-string (bytes)
  "Return BYTES gzipped, using the standard `gzip' command via a
process.  Only used to construct fixtures."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert bytes)
    (call-process-region (point-min) (point-max) "gzip" t t nil "-c")
    (buffer-string)))

(defun test-helm--encode-release (release-alist)
  "Encode RELEASE-ALIST the way Helm 3 stores it on the wire.
Returns the `data.release' value an API server would emit."
  (let* ((json-encoding-pretty-print nil)
         (json (json-encode release-alist))
         (gz   (test-helm--gzip-string json))
         (inner (base64-encode-string gz t))
         (outer (base64-encode-string inner t)))
    outer))

(defun test-helm--secret-fixture (release-alist
                                  &optional ns name)
  "Return a synthetic K8s Secret alist embedding RELEASE-ALIST."
  (let ((ns (or ns "default"))
        (name (or name "sh.helm.release.v1.test.v1")))
    `((apiVersion . "v1")
      (kind . "Secret")
      (type . "helm.sh/release.v1")
      (metadata . ((name . ,name)
                   (namespace . ,ns)
                   (creationTimestamp . "2026-05-25T10:00:00Z")
                   (labels . ((owner . "helm")
                              (name  . "test")
                              (status . "deployed")
                              (version . "1")))))
      (data . ((release . ,(test-helm--encode-release release-alist)))))))

;;; ---------------------------------------------------------------------------
;;; Tests

(defconst test-helm--sample-release
  '((name . "test")
    (namespace . "default")
    (version . 1)
    (info . ((status . "deployed")
             (notes . "Thanks for installing test!")
             (first_deployed . "2026-05-25T10:00:00Z")))
    (chart . ((metadata . ((name . "test-chart")
                           (version . "1.0.0")
                           (appVersion . "v1.2.3")))))
    (config . ((replicas . 3)
               (image . ((repo . "nginx")
                         (tag . "1.27")))))
    (manifest . "apiVersion: v1\nkind: Service\nmetadata:\n  name: test\n"))
  "Compact synthetic helm release used by the tests.")

(ert-deftest helm/decoder-round-trip ()
  "Encode the sample release the way helm does, then decode it back
and check the key fields survive intact."
  (let* ((wire (test-helm--encode-release test-helm--sample-release))
         (rel  (k8s-helm--decode-release wire)))
    (should (equal "test" (cdr (assq 'name rel))))
    (should (equal "default" (cdr (assq 'namespace rel))))
    (should (= 1 (cdr (assq 'version rel))))
    (let ((info (cdr (assq 'info rel))))
      (should (equal "deployed" (cdr (assq 'status info))))
      (should (string-match-p "Thanks" (cdr (assq 'notes info)))))
    (let* ((chart (cdr (assq 'chart rel)))
           (meta  (cdr (assq 'metadata chart))))
      (should (equal "test-chart" (cdr (assq 'name meta))))
      (should (equal "1.0.0" (cdr (assq 'version meta))))
      (should (equal "v1.2.3" (cdr (assq 'appVersion meta)))))))

(ert-deftest helm/decode-secret-extracts-data-release ()
  "Given a synthetic Secret alist, return the decoded release."
  (let* ((secret (test-helm--secret-fixture test-helm--sample-release))
         (rel    (k8s-helm--decode-secret secret)))
    (should rel)
    (should (equal "test" (cdr (assq 'name rel))))))

(ert-deftest helm/decode-secret-non-helm-returns-nil ()
  "A Secret without the `owner=helm' label is not Helm — skip it
silently rather than mis-decoding it."
  (let* ((bogus
          `((apiVersion . "v1")
            (kind . "Secret")
            (metadata . ((name . "credentials")
                         (namespace . "default")
                         (labels . ((purpose . "tls")))))
            (data . ((release . "AAAA"))))))
    (should-not (k8s-helm--decode-secret bogus))))

(ert-deftest helm/decode-secret-bad-payload-warns-not-crashes ()
  "If the data.release field is corrupt, return nil and emit a
message — don't tear the whole listing down."
  (let* ((corrupt
          `((apiVersion . "v1")
            (kind . "Secret")
            (metadata . ((name . "sh.helm.release.v1.broken.v1")
                         (namespace . "default")
                         (labels . ((owner . "helm")))))
            (data . ((release . "not-base64!@#")))))
         (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (should-not (k8s-helm--decode-secret corrupt))
      (should (cl-find-if (lambda (m)
                            (string-match-p "failed to decode" m))
                          messages)))))

(ert-deftest helm/active-label-selector-shape ()
  "The cluster-wide selector returns only the LIVE revision per release."
  (should (string-match-p "owner=helm" k8s-helm--active-label-selector))
  (should (string-match-p "status!=superseded"
                          k8s-helm--active-label-selector)))

(ert-deftest helm/field-accessors ()
  "The convenience accessors line up with the release schema."
  (let ((rel test-helm--sample-release))
    (should (equal "test" (k8s-helm--rel-name rel)))
    (should (= 1 (k8s-helm--rel-version rel)))
    (should (equal "deployed" (k8s-helm--rel-status rel)))
    (should (equal "test-chart" (k8s-helm--rel-chart-name rel)))
    (should (equal "1.0.0" (k8s-helm--rel-chart-version rel)))
    (should (equal "v1.2.3" (k8s-helm--rel-chart-app-version rel)))
    (should (consp (k8s-helm--rel-values rel)))
    (should (stringp (k8s-helm--rel-manifest rel)))))

;;; --- New helpers (compose-selector + manifest-summary) ---------------------

(ert-deftest helm/compose-selector-no-user-filter ()
  "Without a user-set label filter, the helm baseline rides alone."
  (should (equal k8s-helm--active-label-selector
                 (k8s-helm--compose-selector nil)))
  (should (equal k8s-helm--active-label-selector
                 (k8s-helm--compose-selector ""))))

(ert-deftest helm/compose-selector-with-user-filter ()
  "User filter AND'd onto the baseline via comma."
  (should (equal "owner=helm,status!=superseded,tier=frontend"
                 (k8s-helm--compose-selector "tier=frontend"))))

(ert-deftest helm/manifest-summary-counts-kinds ()
  "Each `kind:' line bumps its kind's count.  Result is sorted
count-desc then alpha."
  (let* ((manifest "---
apiVersion: v1
kind: Service
metadata:
  name: web
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web
---
apiVersion: v1
kind: Service
metadata:
  name: api
")
         (summary (k8s-helm--manifest-summary manifest)))
    (should (equal '(("Service" . 2)
                     ("ConfigMap" . 1)
                     ("Deployment" . 1))
                   summary))))

(ert-deftest helm/manifest-summary-empty ()
  (should-not (k8s-helm--manifest-summary nil))
  (should-not (k8s-helm--manifest-summary "")))

(ert-deftest helm/manifest-resources-extracts-names ()
  "Parses kind + metadata.name per document; nested name fields
\(spec.template.metadata.name, spec.ports[].name) don't leak in."
  (let* ((manifest "---
apiVersion: v1
kind: Service
metadata:
  name: web
  labels:
    app: web
spec:
  ports:
  - name: http
    port: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  template:
    metadata:
      labels:
        app: web
      name: should-not-be-captured
    spec:
      containers:
      - name: nginx
        image: nginx
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-conf
")
         (resources (k8s-helm--manifest-resources manifest)))
    (should (equal '("web") (cdr (assoc "Service" resources))))
    (should (equal '("web") (cdr (assoc "Deployment" resources))))
    (should (equal '("web-conf") (cdr (assoc "ConfigMap" resources))))))

(ert-deftest helm/decode-secret-attaches-secret-metadata ()
  "Decoded release carries the source secret's metadata so the
view can render age etc."
  (let* ((secret (test-helm--secret-fixture test-helm--sample-release))
         (rel    (k8s-helm--decode-secret secret))
         (smeta  (cdr (assq 'secret-metadata rel))))
    (should smeta)
    (should (equal "default" (cdr (assq 'namespace smeta))))
    (should (equal "2026-05-25T10:00:00Z"
                   (cdr (assq 'creationTimestamp smeta))))))

(provide 'test-helm)
;;; test-helm.el ends here
