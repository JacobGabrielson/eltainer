;;; k8s-pulse.el --- Cluster-pulse dashboard -*- lexical-binding: t -*-
;;
;; A one-buffer cluster health summary: pod phase counts, node Ready
;; status, workload totals, recent warning events, top CPU /
;; memory consumers.  Read-only.  Self-refreshes on its own timer
;; (default `k8s-metrics-refresh-interval').
;;
;; Reachable from the dashboard (`P') and the `?' transient
;; \(Cluster pulse).

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'eltainer-gauge)
(require 'k8s-api)
(require 'k8s-marks)
(require 'k8s)
(require 'k8s-metrics)

(defgroup k8s-pulse nil
  "Cluster-pulse dashboard."
  :group 'k8s
  :prefix "k8s-pulse-")

(defcustom k8s-pulse-recent-events-window-minutes 60
  "Show Warning events from the last N minutes on the pulse view."
  :type 'integer
  :group 'k8s-pulse)

(defcustom k8s-pulse-top-consumers 5
  "How many rows to show in the Top CPU / Top Memory tables."
  :type 'integer
  :group 'k8s-pulse)

;;; ---------------------------------------------------------------------------
;;; Aggregation helpers (pure-ish, easy to unit-test)

(defun k8s-pulse--pod-phase-counts (pods)
  "Return `((PHASE . COUNT) ...)' from PODS (vector of pod alists)."
  (let ((tbl (make-hash-table :test 'equal)))
    (seq-doseq (p pods)
      (let ((phase (or (cdr (assq 'phase (cdr (assq 'status p)))) "Unknown")))
        (puthash phase (1+ (gethash phase tbl 0)) tbl)))
    (let (out)
      (maphash (lambda (k v) (push (cons k v) out)) tbl)
      (sort out (lambda (a b)
                  (or (> (cdr a) (cdr b))
                      (and (= (cdr a) (cdr b))
                           (string< (car a) (car b)))))))))

(defun k8s-pulse--node-ready-counts (nodes)
  "Return (READY . NOTREADY) tallying NODES by Ready-condition status."
  (let ((ready 0) (notready 0))
    (seq-doseq (n nodes)
      (let* ((conds (cdr (assq 'conditions (cdr (assq 'status n)))))
             (ready-cond
              (cl-find-if (lambda (c)
                            (equal "Ready" (cdr (assq 'type c))))
                          (append (or conds []) nil))))
        (if (and ready-cond
                 (equal "True" (cdr (assq 'status ready-cond))))
            (cl-incf ready)
          (cl-incf notready))))
    (cons ready notready)))

(defun k8s-pulse--event-iso-time (ev)
  "Return EV's most useful timestamp string (lastTimestamp falls back
to eventTime, then to metadata.creationTimestamp)."
  (or (cdr (assq 'lastTimestamp ev))
      (cdr (assq 'eventTime ev))
      (cdr (assq 'creationTimestamp (cdr (assq 'metadata ev))))))

(defun k8s-pulse--filter-recent-warnings (events window-secs)
  "From EVENTS, return only Warning events newer than WINDOW-SECS ago,
sorted newest-first."
  (let ((cutoff (- (float-time) window-secs)))
    (sort
     (seq-filter
      (lambda (ev)
        (and (equal "Warning" (cdr (assq 'type ev)))
             (let ((iso (k8s-pulse--event-iso-time ev)))
               (and iso
                    (condition-case nil
                        (> (float-time (date-to-time iso)) cutoff)
                      (error nil))))))
      (append events nil))
     (lambda (a b)
       (let ((ta (k8s-pulse--event-iso-time a))
             (tb (k8s-pulse--event-iso-time b)))
         (string> (or ta "") (or tb "")))))))

(defun k8s-pulse--rank-pods-by-cpu (metrics-table)
  "Rank pods in METRICS-TABLE (`k8s-metrics-collect' result) by
total CPU usage (millicores) desc.  Returns a list of plists with
keys :ns :pod :cpu :mem.

METRICS-TABLE is a hash NS/POD -> (hash CNAME -> (CPU . MEM)) — sum
across containers per pod."
  (let (out)
    (maphash
     (lambda (key per-cname)
       (let ((cpu 0) (mem 0))
         (maphash
          (lambda (_cname usage)
            (cl-incf cpu (or (car usage) 0))
            (cl-incf mem (or (cdr usage) 0)))
          per-cname)
         (let ((parts (split-string key "/" t)))
           (push (list :ns (car parts) :pod (cadr parts)
                       :cpu cpu :mem mem)
                 out))))
     metrics-table)
    out))

(defun k8s-pulse--top-by (rows key n)
  "Return the top N ROWS sorted by KEY (a plist key) desc."
  (seq-take (sort (copy-sequence rows)
                  (lambda (a b)
                    (> (or (plist-get a key) 0)
                       (or (plist-get b key) 0))))
            n))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun k8s-pulse--phase-face (phase)
  (pcase phase
    ("Running"   'eltainer-status-running)
    ("Succeeded" 'eltainer-status-running)
    ("Pending"   'eltainer-status-warn)
    ("Failed"    'eltainer-status-error)
    ("Unknown"   'eltainer-status-error)
    (_            'eltainer-status-other)))

(defun k8s-pulse--insert-phase-row (phase count max-count)
  "Insert one row of the phase tally with a small bar of width 14."
  (let* ((width 14)
         (frac (if (and max-count (> max-count 0))
                   (/ (float count) max-count)
                 0.0))
         (filled (round (* width frac))))
    (insert (format "  %-12s %5d  "
                    (propertize phase 'font-lock-face
                                (k8s-pulse--phase-face phase))
                    count))
    (insert (propertize (make-string filled ?█)
                        'font-lock-face (k8s-pulse--phase-face phase)))
    (insert (propertize (make-string (- width filled) ?·)
                        'font-lock-face 'k8s-dim))
    (insert "\n")))

(defun k8s-pulse--insert-event-row (ev)
  (let* ((reason (or (cdr (assq 'reason ev)) "?"))
         (msg    (or (cdr (assq 'message ev)) ""))
         (obj    (cdr (assq 'involvedObject ev)))
         (kind   (cdr (assq 'kind obj)))
         (name   (cdr (assq 'name obj)))
         (ns     (cdr (assq 'namespace obj)))
         (iso    (k8s-pulse--event-iso-time ev))
         (age    (and iso (k8s--age-string iso))))
    (insert (format "  %-20s %-40s %s\n"
                    (propertize reason 'font-lock-face 'eltainer-status-error)
                    (propertize (format "%s/%s %s"
                                        (or ns "")
                                        (or name "")
                                        (or kind ""))
                                'font-lock-face 'k8s-resource-name)
                    age))
    (when (and msg (not (string-empty-p msg)))
      (insert (propertize (format "    %s\n"
                                  (truncate-string-to-width msg 100 nil nil "…"))
                          'font-lock-face 'k8s-dim)))))

(defun k8s-pulse--insert-consumer-row (row metric)
  (let ((value (plist-get row metric))
        (ns (plist-get row :ns))
        (pod (plist-get row :pod)))
    (insert (format "  %-12s %-40s %s\n"
                    (cond
                     ((eq metric :cpu)
                      (propertize (k8s-metrics--human-cpu value)
                                  'font-lock-face 'eltainer-resource-name))
                     (t
                      (propertize (eltainer-human-bytes value)
                                  'font-lock-face 'eltainer-resource-name)))
                    (propertize (format "%s/%s" ns pod)
                                'font-lock-face 'k8s-dim)
                    ""))))

;;; ---------------------------------------------------------------------------
;;; Refresh

(defvar-local k8s-pulse--timer nil)

(defun k8s-pulse--collect ()
  "Run every API call the pulse needs, return a plist of results."
  (let* ((conn (k8s--ensure-connection))
         (pods (condition-case nil
                   (or (append (k8s-list-pods conn) nil) nil)
                 (error nil)))
         (nodes (condition-case nil
                    (or (append (k8s-list-nodes conn) nil) nil)
                  (error nil)))
         (events (condition-case nil
                     (k8s-list-events-all conn "type=Warning")
                   (error nil)))
         (metrics-table (condition-case nil
                            (k8s-metrics-collect conn)
                          (error nil))))
    (list :conn conn
          :pods pods
          :nodes nodes
          :events events
          :metrics-table metrics-table)))

(defun k8s-pulse--workload-counts (conn)
  "Return an alist of (LABEL . COUNT) for the chunky workload kinds."
  (cl-loop
   for (label fn) in
   `(("Deployments"  ,#'k8s-list-deployments)
     ("StatefulSets" ,#'k8s-list-statefulsets)
     ("DaemonSets"   ,#'k8s-list-daemonsets)
     ("Jobs"         ,#'k8s-list-jobs)
     ("CronJobs"     ,#'k8s-list-cronjobs)
     ("Services"     ,#'k8s-list-services)
     ("Ingresses"    ,#'k8s-list-ingresses))
   for items = (condition-case nil (funcall fn conn) (error nil))
   collect (cons label (length items))))

(defun k8s-pulse-refresh ()
  "Re-collect everything and re-render the pulse buffer."
  (interactive)
  (let* ((data (k8s-pulse--collect))
         (conn (plist-get data :conn))
         (pods (plist-get data :pods))
         (nodes (plist-get data :nodes))
         (events (plist-get data :events))
         (metrics-table (plist-get data :metrics-table))
         (phase-counts (k8s-pulse--pod-phase-counts pods))
         (max-phase-count (apply #'max 0 (mapcar #'cdr phase-counts)))
         (node-counts (k8s-pulse--node-ready-counts nodes))
         (recent-warnings
          (k8s-pulse--filter-recent-warnings
           events (* 60 k8s-pulse-recent-events-window-minutes)))
         (pod-rows (and metrics-table
                        (k8s-pulse--rank-pods-by-cpu metrics-table)))
         (top-cpu (and pod-rows
                       (k8s-pulse--top-by pod-rows :cpu k8s-pulse-top-consumers)))
         (top-mem (and pod-rows
                       (k8s-pulse--top-by pod-rows :mem k8s-pulse-top-consumers)))
         (wl-counts (k8s-pulse--workload-counts conn))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (pulse-root)
      ;; Header
      (insert (propertize "Cluster pulse" 'font-lock-face 'eltainer-section-heading)
              "\n\n")
      ;; Pods
      (magit-insert-section (pulse-pods)
        (magit-insert-heading
          (propertize (format "Pods (%d)\n" (length pods))
                      'font-lock-face 'eltainer-section-heading))
        (if (null phase-counts)
            (insert (propertize "  (no pods)\n" 'font-lock-face 'k8s-dim))
          (dolist (pc phase-counts)
            (k8s-pulse--insert-phase-row (car pc) (cdr pc) max-phase-count)))
        (insert "\n"))
      ;; Nodes
      (magit-insert-section (pulse-nodes)
        (magit-insert-heading
          (propertize (format "Nodes (%d)\n" (length nodes))
                      'font-lock-face 'eltainer-section-heading))
        (insert (format "  %-12s %5d\n"
                        (propertize "Ready" 'font-lock-face 'eltainer-status-running)
                        (car node-counts)))
        (when (> (cdr node-counts) 0)
          (insert (format "  %-12s %5d\n"
                          (propertize "NotReady" 'font-lock-face 'eltainer-status-error)
                          (cdr node-counts))))
        (insert "\n"))
      ;; Workloads
      (magit-insert-section (pulse-workloads)
        (magit-insert-heading
          (propertize "Workloads\n" 'font-lock-face 'eltainer-section-heading))
        (dolist (kv wl-counts)
          (insert (format "  %-15s %5d\n"
                          (propertize (car kv) 'font-lock-face 'k8s-dim)
                          (cdr kv))))
        (insert "\n"))
      ;; Recent warning events
      (magit-insert-section (pulse-events)
        (magit-insert-heading
          (propertize (format "Recent Warning events (last %dm) — %d\n"
                              k8s-pulse-recent-events-window-minutes
                              (length recent-warnings))
                      'font-lock-face 'eltainer-section-heading))
        (if (null recent-warnings)
            (insert (propertize "  (no recent warning events)\n"
                                'font-lock-face 'eltainer-status-running))
          (dolist (ev (seq-take recent-warnings 10))
            (k8s-pulse--insert-event-row ev))
          (when (> (length recent-warnings) 10)
            (insert (propertize (format "  ... %d more\n"
                                        (- (length recent-warnings) 10))
                                'font-lock-face 'k8s-dim))))
        (insert "\n"))
      ;; Top consumers
      (when top-cpu
        (magit-insert-section (pulse-top-cpu)
          (magit-insert-heading
            (propertize (format "Top %d CPU consumers\n"
                                k8s-pulse-top-consumers)
                        'font-lock-face 'eltainer-section-heading))
          (dolist (row top-cpu)
            (k8s-pulse--insert-consumer-row row :cpu))
          (insert "\n")))
      (when top-mem
        (magit-insert-section (pulse-top-mem)
          (magit-insert-heading
            (propertize (format "Top %d memory consumers\n"
                                k8s-pulse-top-consumers)
                        'font-lock-face 'eltainer-section-heading))
          (dolist (row top-mem)
            (k8s-pulse--insert-consumer-row row :mem))
          (insert "\n"))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar k8s-pulse-mode-map (make-sparse-keymap)
  "Keymap for `k8s-pulse-mode'.")
(set-keymap-parent k8s-pulse-mode-map k8s-common-map)
(keymap-set k8s-pulse-mode-map "g" #'k8s-pulse-refresh)

(define-derived-mode k8s-pulse-mode magit-section-mode "K8s:Pulse"
  "Cluster-pulse dashboard.

\\{k8s-pulse-mode-map}"
  :interactive nil
  :group 'k8s-pulse
  (setq-local revert-buffer-function (lambda (_a _b) (k8s-pulse-refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces))
  (add-hook 'kill-buffer-hook #'k8s-pulse--stop-timer nil t))

(defun k8s-pulse--stop-timer ()
  (when (timerp k8s-pulse--timer)
    (cancel-timer k8s-pulse--timer))
  (setq k8s-pulse--timer nil))

;;;###autoload
(defun k8s-pulse ()
  "Open the cluster-pulse dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:pulse*")))
    (with-current-buffer buf
      (k8s-pulse-mode)
      (k8s--ensure-connection)
      (k8s-pulse-refresh)
      (k8s-pulse--stop-timer)
      (setq k8s-pulse--timer
            (run-at-time k8s-metrics-refresh-interval
                         k8s-metrics-refresh-interval
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (condition-case err
                                   (k8s-pulse-refresh)
                                 (error
                                  (message
                                   "k8s-pulse: refresh failed: %s"
                                   (error-message-string err))))))))))
    (pop-to-buffer buf)))

(provide 'k8s-pulse)
;;; k8s-pulse.el ends here
