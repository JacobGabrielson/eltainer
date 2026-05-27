;;; test-traffic.el --- Tests for k8s-traffic aggregation -*- lexical-binding: t -*-

(require 'ert)
(require 'eltainer-ui)
(require 'k8s-traffic)

;;; ---------------------------------------------------------------------------
;;; bytes-rate formatter

(ert-deftest traffic/bytes-rate-units ()
  (should (equal "500B/s"   (eltainer-ui-bytes-rate 500)))
  (should (equal "1.0KB/s"  (eltainer-ui-bytes-rate 1000)))
  (should (equal "1.5KB/s"  (eltainer-ui-bytes-rate 1500)))
  (should (equal "1.0MB/s"  (eltainer-ui-bytes-rate 1000000)))
  (should (equal "2.50GB/s" (eltainer-ui-bytes-rate 2500000000))))

(ert-deftest traffic/bytes-rate-nil-and-non-numeric ()
  (should (equal "?" (eltainer-ui-bytes-rate nil)))
  (should (equal "?" (eltainer-ui-bytes-rate "junk"))))

;;; ---------------------------------------------------------------------------
;;; Selector matcher

(ert-deftest traffic/selector-matches-when-all-labels-match ()
  (let ((selector '((app . "web") (tier . "frontend")))
        (pod      '((metadata . ((name . "p1")
                                  (labels . ((app . "web")
                                             (tier . "frontend")
                                             (version . "1"))))))))
    (should (k8s-traffic--selector-matches-p selector pod))))

(ert-deftest traffic/selector-rejects-when-a-label-mismatches ()
  (let ((selector '((app . "web") (tier . "frontend")))
        (pod      '((metadata . ((labels . ((app . "web") (tier . "api"))))))))
    (should-not (k8s-traffic--selector-matches-p selector pod))))

(ert-deftest traffic/selector-rejects-when-label-missing ()
  (let ((selector '((app . "web") (tier . "frontend")))
        (pod      '((metadata . ((labels . ((app . "web"))))))))
    (should-not (k8s-traffic--selector-matches-p selector pod))))

(ert-deftest traffic/selector-empty-or-nil ()
  "Selectorless Service / ExternalName: no pods should match."
  (should-not (k8s-traffic--selector-matches-p
               nil '((metadata . ((labels . ((app . "x"))))))))
  (should-not (k8s-traffic--selector-matches-p
               '() '((metadata . ((labels . ((app . "x")))))))))

;;; ---------------------------------------------------------------------------
;;; Sum-pods

(defconst traffic-test--pod-web1
  '((metadata . ((name . "web-1") (labels . ((app . "web")))))))
(defconst traffic-test--pod-web2
  '((metadata . ((name . "web-2") (labels . ((app . "web")))))))
(defconst traffic-test--pod-api1
  '((metadata . ((name . "api-1") (labels . ((app . "api")))))))

(defconst traffic-test--summaries
  ;; alist of pod-name -> Summary entry
  `(("web-1" . ((network . ((rxBytes . 1000) (txBytes . 200)))))
    ("web-2" . ((network . ((rxBytes . 3000) (txBytes . 400)))))
    ("api-1" . ((network . ((rxBytes . 9999) (txBytes . 8888)))))))

(ert-deftest traffic/sum-pods-sums-matching ()
  (let ((result (k8s-traffic--sum-pods
                 '((app . "web"))
                 (vector traffic-test--pod-web1
                         traffic-test--pod-web2
                         traffic-test--pod-api1)
                 traffic-test--summaries)))
    (should (equal '(4000 600 2) result))))

(ert-deftest traffic/sum-pods-no-matches ()
  (let ((result (k8s-traffic--sum-pods
                 '((app . "ghost"))
                 (vector traffic-test--pod-web1)
                 traffic-test--summaries)))
    (should (equal '(0 0 0) result))))

(ert-deftest traffic/sum-pods-skips-pods-without-summary ()
  "A pod that matches the selector but has no entry in the Summary
\(metrics not flowing for it yet) should be tolerated, not error."
  (let* ((pod-no-summary
          '((metadata . ((name . "web-3") (labels . ((app . "web")))))))
         (result (k8s-traffic--sum-pods
                  '((app . "web"))
                  (vector traffic-test--pod-web1 pod-no-summary)
                  traffic-test--summaries)))
    (should (equal '(1000 200 1) result))))

;;; ---------------------------------------------------------------------------
;;; Selector → string

(ert-deftest traffic/selector-to-string ()
  (should (equal "app=web,tier=frontend"
                 (k8s-traffic--selector->string
                  '((app . "web") (tier . "frontend"))))))

;;; ---------------------------------------------------------------------------
;;; History fold + column render

(ert-deftest traffic/fold-into-history-uses-shared-rate-math ()
  "Two ticks should produce a rate; first tick has no delta yet."
  (let* ((history (make-hash-table :test 'equal))
         (t0 100.0)
         (t1 110.0)  ;; 10 seconds later
         (now-fn (lambda (tval) tval)))
    ;; Tick 1: cumulative 1000 bytes — no rate yet
    (k8s-traffic-fold-into-history
     history `(("web" . (:rx 1000 :tx 100 :pod-count 1))) t0)
    (should-not (plist-get (gethash "web" history) :rx-hist))
    ;; Tick 2: cumulative 2000 bytes — should compute rate=100/s
    (k8s-traffic-fold-into-history
     history `(("web" . (:rx 2000 :tx 200 :pod-count 1))) t1)
    (let ((e (gethash "web" history)))
      (should e)
      (should (= 100.0 (plist-get e :rx-rate)))
      (should (= 10.0  (plist-get e :tx-rate)))
      (should (plist-get e :rx-hist)))))

(ert-deftest traffic/render-columns-placeholder-then-rate ()
  "Before any sample lands the cells show `—'; after a sample lands
the rates render."
  (let ((history (make-hash-table :test 'equal)))
    (let ((s (k8s-traffic-render-columns "web" history)))
      (should (string-match-p "—" s)))
    ;; Drop one entry with a recorded rate.
    (puthash "web" '(:rx-rate 1500 :tx-rate 200 :rx-hist [1 2 3])
             history)
    (let ((s (k8s-traffic-render-columns "web" history)))
      (should (string-match-p "1\\.5KB/s" s)))))

(provide 'test-traffic)
;;; test-traffic.el ends here
