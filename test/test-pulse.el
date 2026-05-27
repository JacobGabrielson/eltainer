;;; test-pulse.el --- Tests for cluster-pulse aggregation -*- lexical-binding: t -*-

(require 'ert)
(require 'k8s-pulse)

;;; ---------------------------------------------------------------------------
;;; Pod phase counts

(defun test-pulse--pod (phase)
  `((status . ((phase . ,phase)))))

(ert-deftest pulse/phase-counts ()
  (let* ((pods (list (test-pulse--pod "Running")
                     (test-pulse--pod "Running")
                     (test-pulse--pod "Pending")
                     (test-pulse--pod "Failed")
                     (test-pulse--pod "Running")))
         (counts (k8s-pulse--pod-phase-counts pods)))
    (should (= 3 (cdr (assoc "Running" counts))))
    (should (= 1 (cdr (assoc "Pending" counts))))
    (should (= 1 (cdr (assoc "Failed" counts))))
    ;; Sorted by count desc, alpha-tied; Running should be first.
    (should (equal "Running" (caar counts)))))

(ert-deftest pulse/phase-counts-unknown-phase ()
  (let ((counts (k8s-pulse--pod-phase-counts
                 (list '((status . ((phase . nil))))))))
    (should (= 1 (cdr (assoc "Unknown" counts))))))

;;; ---------------------------------------------------------------------------
;;; Node Ready counts

(defun test-pulse--node (ready-status)
  `((status . ((conditions . [((type . "MemoryPressure") (status . "False"))
                              ((type . "Ready") (status . ,ready-status))])))))

(ert-deftest pulse/node-ready-counts ()
  (let ((counts (k8s-pulse--node-ready-counts
                 (list (test-pulse--node "True")
                       (test-pulse--node "True")
                       (test-pulse--node "False")))))
    (should (equal '(2 . 1) counts))))

(ert-deftest pulse/node-ready-no-conditions-counts-as-notready ()
  (let ((counts (k8s-pulse--node-ready-counts
                 (list '((status . ()))))))
    (should (equal '(0 . 1) counts))))

;;; ---------------------------------------------------------------------------
;;; Event filtering

(defun test-pulse--event (type secs-ago &optional reason)
  (let ((iso (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                  (time-subtract (current-time) secs-ago)
                                  t)))
    `((type . ,type)
      (reason . ,(or reason "Whatever"))
      (lastTimestamp . ,iso))))

(ert-deftest pulse/filter-recent-warnings ()
  "Drops Normal events and those outside the window."
  (let* ((events (vector (test-pulse--event "Warning" 30)
                         (test-pulse--event "Normal" 30)
                         (test-pulse--event "Warning" 5000)
                         (test-pulse--event "Warning" 60 "FailedPullImage")))
         (recent (k8s-pulse--filter-recent-warnings events 600)))
    ;; Two warnings inside 600s — Normal dropped, 5000s-ago dropped.
    (should (= 2 (length recent)))
    ;; Newest-first ordering.
    (should (string> (k8s-pulse--event-iso-time (car recent))
                     (k8s-pulse--event-iso-time (cadr recent))))))

;;; ---------------------------------------------------------------------------
;;; Top-by

(ert-deftest pulse/top-by ()
  (let ((rows (list (list :ns "a" :pod "p1" :cpu 10 :mem 100)
                    (list :ns "b" :pod "p2" :cpu 50 :mem 200)
                    (list :ns "c" :pod "p3" :cpu 30 :mem 300))))
    (let ((top2 (k8s-pulse--top-by rows :cpu 2)))
      (should (= 2 (length top2)))
      (should (equal "p2" (plist-get (car top2) :pod)))
      (should (equal "p3" (plist-get (cadr top2) :pod))))
    (let ((topmem (k8s-pulse--top-by rows :mem 1)))
      (should (equal "p3" (plist-get (car topmem) :pod))))))

;;; ---------------------------------------------------------------------------
;;; rank-pods-by-cpu — verifies the inner-hash sum

(ert-deftest pulse/rank-pods-by-cpu ()
  (let* ((tbl (make-hash-table :test 'equal))
         (inner-a (make-hash-table :test 'equal))
         (inner-b (make-hash-table :test 'equal)))
    (puthash "main" (cons 100 1000) inner-a)
    (puthash "sidecar" (cons 50 500) inner-a)
    (puthash "main" (cons 25 250) inner-b)
    (puthash "default/app-a" inner-a tbl)
    (puthash "default/app-b" inner-b tbl)
    (let ((ranked (k8s-pulse--top-by
                    (k8s-pulse--rank-pods-by-cpu tbl) :cpu 2)))
      (should (equal "app-a" (plist-get (car ranked) :pod)))
      (should (= 150 (plist-get (car ranked) :cpu)))
      (should (= 1500 (plist-get (car ranked) :mem)))
      (should (equal "app-b" (plist-get (cadr ranked) :pod)))
      (should (= 25 (plist-get (cadr ranked) :cpu))))))

(provide 'test-pulse)
;;; test-pulse.el ends here
