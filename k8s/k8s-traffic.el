;;; k8s-traffic.el --- Per-Service ingress/egress traffic aggregation -*- lexical-binding: t -*-
;;
;; "Load balancer" in K8s ultimately funnels traffic to backing pods.
;; Every shape -- ClusterIP / NodePort / LoadBalancer / headless --
;; ends with the bytes hitting the pods, where the kubelet's Summary
;; API counts them as `network.{rxBytes, txBytes}'.  This module
;; aggregates those per-pod counters by Service selector, computes
;; rates against the previous tick, and renders compact
;; `IN/s  OUT/s' columns in the Services view.  An `M' on a Service
;; row opens a focused metrics buffer with sparklines and per-pod
;; breakdown.
;;
;; Design + scope: docs/lb-traffic-plan.md.
;;
;; The Prometheus fast-path (sum-by-service over container_network_*
;; range queries) is deferred to a follow-up -- the Summary path
;; works everywhere kubelet does and reuses the polling tick the
;; pods view already pays for.

(require 'cl-lib)
(require 'subr-x)
(require 'eltainer-ui)
(require 'eltainer-gauge)
(require 'k8s-api)
(require 'k8s-metrics)

(defgroup k8s-traffic nil
  "Service-level traffic aggregation from kubelet Summary."
  :group 'k8s
  :prefix "k8s-traffic-")

(defcustom k8s-services-show-traffic t
  "When non-nil, the Services view renders `IN/s' and `OUT/s' columns.
Set to nil to drop them and recover ~25 chars of row width."
  :type 'boolean
  :group 'k8s-traffic)

;;; ---------------------------------------------------------------------------
;;; Aggregation primitives

(defun k8s-traffic--selector->string (selector)
  "Convert SELECTOR (alist of (KEY . VALUE), keys symbols or strings)
to the canonical K8s `labelSelector' comma-separated form."
  (mapconcat (lambda (kv)
               (let ((k (car kv)) (v (cdr kv)))
                 (format "%s=%s"
                         (if (symbolp k) (symbol-name k) k)
                         (if (symbolp v) (symbol-name v) v))))
             selector ","))

(defun k8s-traffic--selector-matches-p (selector pod)
  "Non-nil iff POD's labels include every (KEY . VALUE) in SELECTOR.
SELECTOR may be nil (a service with no selector — selectorless /
ExternalName — matches nothing here)."
  (and selector
       (let ((labels (cdr (assq 'labels (cdr (assq 'metadata pod))))))
         (cl-every (lambda (kv)
                     (let ((k (car kv)) (v (cdr kv)))
                       (equal (if (symbolp v) (symbol-name v) v)
                              (cdr (assq (if (stringp k) (intern k) k)
                                         labels)))))
                   selector))))

(defun k8s-traffic-aggregate-pod-summary (summary-pod)
  "Return (RX . TX) cumulative bytes from a Summary-API pod entry,
or nil if the pod has no `network' block."
  (let ((net (cdr (assq 'network summary-pod))))
    (when net
      (cons (or (cdr (assq 'rxBytes net)) 0)
            (or (cdr (assq 'txBytes net)) 0)))))

(defun k8s-traffic--sum-pods (selector pods summaries)
  "Sum (rx . tx) across POD-SUMMARIES whose pod matches SELECTOR.
POD is the *spec* pod alist (carries `metadata.labels'); SUMMARIES
is `(POD-KEY . SUMMARY-ENTRY)' alist where POD-KEY matches the
spec pod's `metadata.name'.

Returns (RX-SUM . TX-SUM . MATCHED-COUNT)."
  (let ((rx 0) (tx 0) (n 0))
    (seq-doseq (pod pods)
      (when (k8s-traffic--selector-matches-p selector pod)
        (let* ((name (cdr (assq 'name (cdr (assq 'metadata pod)))))
               (sum (cdr (assoc name summaries)))
               (bytes (and sum (k8s-traffic-aggregate-pod-summary sum))))
          (when bytes
            (cl-incf rx (car bytes))
            (cl-incf tx (cdr bytes))
            (cl-incf n)))))
    (list rx tx n)))

;;; ---------------------------------------------------------------------------
;;; Polling layer
;;
;; The Services view's polling tick fetches:
;;   1. The Service list (already in the buffer).
;;   2. The pod list for the active namespace (one call).
;;   3. The Summary blob for every Node in the cluster (one call per
;;      node — same blob the per-pod metrics tick already pulls).
;;
;; Then for every Service:
;;   - resolve its selector against the pod list,
;;   - sum the matching pods' rx/tx from the Summary,
;;   - fold (rx, tx, now) into the buffer's history hash via
;;     `k8s-metrics-net-sample' so the sparkline + rate code is shared.

(defun k8s-traffic--summary-by-pod-name (summary-blob)
  "Return an alist of (POD-NAME . POD-SUMMARY-ENTRY) from SUMMARY-BLOB.
SUMMARY-BLOB is the `(pods . [...])' field of one Node's
`/stats/summary' response.  Used to look up a pod's network by name."
  (let (out)
    (seq-doseq (p summary-blob)
      (let ((name (cdr (assq 'name (cdr (assq 'podRef p))))))
        (when name (push (cons name p) out))))
    out))

(defun k8s-traffic-collect (conn ns)
  "One-shot poll: return an alist of (SERVICE-NAME . PLIST) for
every Service in NS via CONN.  PLIST keys: :rx :tx :pod-count
\(cumulative bytes; rate math is done at fold time)."
  (let* ((services (k8s-list-services conn ns))
         (pods     (k8s-list-pods conn ns))
         ;; Pull Summary for every node and flatten the per-pod entries
         ;; into a single alist keyed by pod name.  In a multi-node
         ;; cluster a given Service's backing pods may live on any
         ;; node, so we union them all.
         (nodes    (k8s-list-nodes conn))
         (sum-by-pod nil))
    (seq-doseq (node nodes)
      (let* ((node-name (cdr (assq 'name (cdr (assq 'metadata node)))))
             (path (format
                    "/api/v1/nodes/%s/proxy/stats/summary" node-name))
             (blob (condition-case nil (k8s-get conn path) (error nil)))
             (pod-summaries (and blob (cdr (assq 'pods blob)))))
        (when pod-summaries
          (setq sum-by-pod
                (append sum-by-pod
                        (k8s-traffic--summary-by-pod-name pod-summaries))))))
    (let (out)
      (seq-doseq (svc services)
        (let* ((sname (cdr (assq 'name (cdr (assq 'metadata svc)))))
               (selector (cdr (assq 'selector (cdr (assq 'spec svc)))))
               (rs (k8s-traffic--sum-pods selector pods sum-by-pod)))
          (push (cons sname
                      (list :rx (nth 0 rs)
                            :tx (nth 1 rs)
                            :pod-count (nth 2 rs)))
                out)))
      (nreverse out))))

(defun k8s-traffic-fold-into-history (history collected now)
  "Fold one COLLECTED tick of `(SERVICE . PLIST)' pairs into HISTORY.
HISTORY is a hash table the caller owns (one per Services buffer).
Reuses `k8s-metrics-net-sample' so the rate math + counter-reset
handling + ring buffer are the same code the per-pod sparkline
uses.  Returns HISTORY."
  (dolist (entry collected)
    (let* ((svc (car entry))
           (plist (cdr entry))
           (rx (plist-get plist :rx))
           (tx (plist-get plist :tx)))
      (k8s-metrics-net-sample history svc rx tx now)))
  history)

;;; ---------------------------------------------------------------------------
;;; Column rendering (Services view)

(defun k8s-traffic--rate-cell (rate)
  "Format RATE as a fixed-width cell suitable for a table column."
  (propertize (format "%10s" (eltainer-ui-bytes-rate (or rate 0)))
              'font-lock-face 'k8s-dim))

(defun k8s-traffic-render-columns (service-name history)
  "Return `\"  IN/s   OUT/s\"' rendered cells for SERVICE-NAME from
HISTORY (the per-buffer net-history hash).  Cells show \"—\" when no
sample has been recorded yet (first poll)."
  (let ((entry (gethash service-name history)))
    (cond
     ((or (null entry) (null (plist-get entry :rx-hist)))
      (concat (propertize (format "%10s" "—") 'font-lock-face 'k8s-dim)
              " "
              (propertize (format "%10s" "—") 'font-lock-face 'k8s-dim)))
     (t
      (concat (k8s-traffic--rate-cell (plist-get entry :rx-rate))
              " "
              (k8s-traffic--rate-cell (plist-get entry :tx-rate)))))))

;;; ---------------------------------------------------------------------------
;;; Per-Service metrics buffer
;;
;; `M' on a Service row opens `*k8s:traffic:NS/SVC*' with sparklines
;; and a per-backing-pod breakdown.  Polls on its own timer (default
;; the same interval as `k8s-metrics-refresh-interval').

(defvar-local k8s-traffic--buffer-conn nil)
(defvar-local k8s-traffic--buffer-ns nil)
(defvar-local k8s-traffic--buffer-service nil)
(defvar-local k8s-traffic--buffer-timer nil)
(defvar-local k8s-traffic--buffer-history nil
  "Per-Service history (one key) for the sparkline.")
(defvar-local k8s-traffic--buffer-pod-history nil
  "Per-pod history (N keys) for the per-pod sparklines.")

(defun k8s-traffic--service-buffer-name (ns svc)
  (format "*k8s:traffic:%s/%s*" ns svc))

(defun k8s-traffic--insert-service-summary (entry)
  "Insert the top sparkline block from ENTRY (the per-Service plist)."
  (let* ((rx-rate (plist-get entry :rx-rate))
         (tx-rate (plist-get entry :tx-rate))
         (rx-hist (plist-get entry :rx-hist))
         (tx-hist (plist-get entry :tx-hist)))
    (insert (propertize "  IN/s   "  'font-lock-face 'k8s-dim))
    (if rx-hist
        (insert (propertize (eltainer-sparkline rx-hist 16)
                            'font-lock-face 'eltainer-gauge-low)
                (format "  %s\n" (eltainer-ui-bytes-rate (or rx-rate 0))))
      (insert (propertize "(sampling…)\n" 'font-lock-face 'k8s-dim)))
    (insert (propertize "  OUT/s  "  'font-lock-face 'k8s-dim))
    (if tx-hist
        (insert (propertize (eltainer-sparkline tx-hist 16)
                            'font-lock-face 'eltainer-gauge-mid)
                (format "  %s\n" (eltainer-ui-bytes-rate (or tx-rate 0))))
      (insert (propertize "(sampling…)\n" 'font-lock-face 'k8s-dim)))))

(defun k8s-traffic--insert-pod-line (pod-name entry)
  "Insert one per-pod line with IN/OUT rates + a small sparkline."
  (let* ((rxr (plist-get entry :rx-rate))
         (txr (plist-get entry :tx-rate))
         (rxh (plist-get entry :rx-hist))
         (txh (plist-get entry :tx-hist)))
    (insert (format "  %-40s " pod-name))
    (if (and rxh txh)
        (insert (propertize (eltainer-sparkline rxh 8)
                            'font-lock-face 'eltainer-gauge-low)
                (format " %9s   "
                        (eltainer-ui-bytes-rate (or rxr 0)))
                (propertize (eltainer-sparkline txh 8)
                            'font-lock-face 'eltainer-gauge-mid)
                (format " %9s\n"
                        (eltainer-ui-bytes-rate (or txr 0))))
      (insert (propertize "(sampling…)\n" 'font-lock-face 'k8s-dim)))))

(defun k8s-traffic--buffer-refresh ()
  "Re-poll the Service + pods + Summary, fold into history, render."
  (let* ((conn k8s-traffic--buffer-conn)
         (ns   k8s-traffic--buffer-ns)
         (svc-name k8s-traffic--buffer-service)
         (now  (float-time))
         (svc  (condition-case nil
                   (k8s-get conn
                            (format "/api/v1/namespaces/%s/services/%s"
                                    ns svc-name))
                 (error nil)))
         (selector (and svc (cdr (assq 'selector
                                       (cdr (assq 'spec svc))))))
         (pods (k8s-list-pods conn ns))
         (matching
          (seq-filter (lambda (p)
                        (k8s-traffic--selector-matches-p selector p))
                      pods))
         (nodes (k8s-list-nodes conn))
         (sum-by-pod nil))
    (seq-doseq (node nodes)
      (let* ((node-name (cdr (assq 'name (cdr (assq 'metadata node)))))
             (path (format
                    "/api/v1/nodes/%s/proxy/stats/summary" node-name))
             (blob (condition-case nil (k8s-get conn path) (error nil)))
             (pod-summaries (and blob (cdr (assq 'pods blob)))))
        (when pod-summaries
          (setq sum-by-pod
                (append sum-by-pod
                        (k8s-traffic--summary-by-pod-name pod-summaries))))))
    ;; Service-level sum
    (let* ((agg (k8s-traffic--sum-pods selector matching sum-by-pod))
           (rx (nth 0 agg)) (tx (nth 1 agg)))
      (k8s-metrics-net-sample
       k8s-traffic--buffer-history svc-name rx tx now))
    ;; Per-pod
    (seq-doseq (pod matching)
      (let* ((pname (cdr (assq 'name (cdr (assq 'metadata pod)))))
             (sum (cdr (assoc pname sum-by-pod)))
             (b (and sum (k8s-traffic-aggregate-pod-summary sum))))
        (when b
          (k8s-metrics-net-sample
           k8s-traffic--buffer-pod-history pname (car b) (cdr b) now))))
    ;; Render
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize (format "Service:   %s/%s\n" ns svc-name)
                          'font-lock-face 'eltainer-section-heading))
      (when svc
        (let ((type (or (cdr (assq 'type (cdr (assq 'spec svc))))
                        "ClusterIP")))
          (insert (propertize (format "Type:      %s\n" type)
                              'font-lock-face 'k8s-dim))))
      (when selector
        (insert (propertize
                 (format "Selector:  %s\n"
                         (k8s-traffic--selector->string selector))
                 'font-lock-face 'k8s-dim)))
      (insert "\n")
      (k8s-traffic--insert-service-summary
       (gethash svc-name k8s-traffic--buffer-history))
      (insert "\n")
      (insert (propertize
               (format "Backing pods (%d):\n" (length matching))
               'font-lock-face 'eltainer-section-heading))
      (if (zerop (length matching))
          (insert (propertize "  (no matching pods)\n" 'font-lock-face 'k8s-dim))
        (seq-doseq (pod matching)
          (let ((pname (cdr (assq 'name (cdr (assq 'metadata pod))))))
            (k8s-traffic--insert-pod-line
             pname (gethash pname k8s-traffic--buffer-pod-history))))))))

(defvar-keymap k8s-traffic-mode-map
  :parent special-mode-map
  "g" #'k8s-traffic--buffer-refresh
  "q" #'quit-window)

(define-derived-mode k8s-traffic-mode special-mode "K8s:Traffic"
  "Per-Service ingress / egress traffic dashboard.

\\{k8s-traffic-mode-map}"
  :interactive nil
  :group 'k8s-traffic
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'k8s-traffic--buffer-stop-timer nil t))

(defun k8s-traffic--buffer-stop-timer ()
  (when (timerp k8s-traffic--buffer-timer)
    (cancel-timer k8s-traffic--buffer-timer))
  (setq k8s-traffic--buffer-timer nil))

;;;###autoload
(defun k8s-traffic-buffer (conn ns service-name)
  "Open the per-Service traffic dashboard for NS/SERVICE-NAME via CONN."
  (let ((buf (get-buffer-create
              (k8s-traffic--service-buffer-name ns service-name))))
    (with-current-buffer buf
      (k8s-traffic-mode)
      (setq k8s-traffic--buffer-conn conn
            k8s-traffic--buffer-ns ns
            k8s-traffic--buffer-service service-name
            k8s-traffic--buffer-history (make-hash-table :test 'equal)
            k8s-traffic--buffer-pod-history (make-hash-table :test 'equal))
      (k8s-traffic--buffer-refresh)
      (k8s-traffic--buffer-stop-timer)
      (setq k8s-traffic--buffer-timer
            (run-at-time k8s-metrics-refresh-interval
                         k8s-metrics-refresh-interval
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (condition-case err
                                   (k8s-traffic--buffer-refresh)
                                 (error
                                  (message
                                   "k8s-traffic: refresh error: %s"
                                   (error-message-string err))))))))))
    (pop-to-buffer buf)))

(provide 'k8s-traffic)
;;; k8s-traffic.el ends here
