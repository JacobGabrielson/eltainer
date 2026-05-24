;;; k8s-prom.el --- Query Prometheus through the K8s API service proxy -*- lexical-binding: t -*-
;;
;; Optional Prometheus integration.  Rather than open a second
;; connection to a Prometheus endpoint — which would mean its own URL,
;; TLS material and auth — this routes PromQL queries through the
;; Kubernetes API server's *service proxy*:
;;
;;   /api/v1/namespaces/{ns}/services/{svc}:{port}/proxy/api/v1/query
;;
;; so every query reuses the already-authenticated `k8s-connection'.
;; No port-forward, no extra credentials.  The Prometheus Service is
;; auto-discovered (override with `eltainer-prometheus-service'); when
;; none is found every entry point degrades to nil and callers simply
;; render without the Prometheus-sourced rows.

(require 'cl-lib)
(require 'url-util)
(require 'k8s-api)

(defgroup k8s-prom nil
  "Prometheus integration for the eltainer Kubernetes views."
  :group 'k8s
  :prefix "k8s-prom-")

(defcustom eltainer-prometheus-service nil
  "Where to find Prometheus, as the string \"NAMESPACE/NAME:PORT\".

When nil (the default) eltainer auto-discovers a Prometheus
Service by scanning the cluster's Services.  Set it to the symbol
`disabled' to switch the Prometheus integration off entirely and
skip discovery."
  :type '(choice (const :tag "Auto-discover" nil)
                 (const :tag "Disabled" disabled)
                 (string :tag "namespace/name:port"))
  :group 'k8s-prom)

;;; ---------------------------------------------------------------------------
;;; Service resolution

(defvar k8s-prom--service-cache nil
  "Memoized discovery result: a cons (SERVER-URL . SERVICE-or-`none').
SERVICE is a plist (:namespace :name :port :headless).  The symbol
`none' records that a scan ran and turned up nothing, so we do not
rescan on every refresh.")

(defun k8s-prom-reset ()
  "Forget any cached Prometheus-Service discovery result.
Run this after installing or moving Prometheus so the next query
re-discovers it."
  (interactive)
  (setq k8s-prom--service-cache nil)
  (message "eltainer: Prometheus discovery cache cleared"))

(defun k8s-prom--parse-spec (spec)
  "Parse SPEC \"NAMESPACE/NAME:PORT\" into a service plist, or nil."
  (when (and (stringp spec)
             (string-match
              "\\`\\([^/]+\\)/\\([^:/]+\\):\\([0-9]+\\)\\'" spec))
    (list :namespace (match-string 1 spec)
          :name      (match-string 2 spec)
          :port      (string-to-number (match-string 3 spec))
          :headless  nil)))

(defconst k8s-prom--exclude-rx
  (regexp-opt '("node-exporter" "alertmanager" "operator" "operated"
                "grafana" "kube-state-metrics" "adapter" "thanos"
                "pushgateway" "blackbox" "exporter"))
  "Service-name fragments that look monitoring-ish but are not a Prom server.
`operated' is here so the headless `prometheus-operated' Service
loses to the routable ClusterIP one.")

(defun k8s-prom--label (labels key)
  "Return the value of label KEY (a string) from LABELS alist."
  (cdr (assq (intern key) labels)))

(defun k8s-prom--service-prometheus-p (name labels)
  "Return non-nil when a Service NAME/LABELS looks like a Prometheus server."
  (let ((ln (downcase (or name ""))))
    (and (not (string-match-p k8s-prom--exclude-rx ln))
         (or (string-match-p "prometheus" ln)
             (let ((app (or (k8s-prom--label labels "app.kubernetes.io/name")
                            (k8s-prom--label labels "app")
                            "")))
               (string-match-p "prometheus" (downcase app)))))))

(defun k8s-prom--pick-port (spec)
  "Return the best Prometheus port number from a Service SPEC alist."
  (let (named numbered first)
    (seq-doseq (p (or (cdr (assq 'ports spec)) []))
      (let ((pn (cdr (assq 'port p)))
            (nm (downcase (or (cdr (assq 'name p)) ""))))
        (unless first (setq first pn))
        (when (and (not named) (member nm '("web" "http-web" "http")))
          (setq named pn))
        (when (and (not numbered) (eql pn 9090))
          (setq numbered pn))))
    (or named numbered first)))

(defun k8s-prom--discover (conn)
  "Scan CONN's Services for a Prometheus server.  Return a plist or nil.
A routable ClusterIP Service wins over a headless one."
  (condition-case nil
      (let (best)
        (seq-doseq (svc (or (k8s-list-services conn) []))
          (let* ((meta (cdr (assq 'metadata svc)))
                 (name (cdr (assq 'name meta)))
                 (ns   (cdr (assq 'namespace meta)))
                 (labels (cdr (assq 'labels meta)))
                 (spec (cdr (assq 'spec svc))))
            (when (and name ns
                       (k8s-prom--service-prometheus-p name labels))
              (let ((port (k8s-prom--pick-port spec))
                    (headless (equal (cdr (assq 'clusterIP spec)) "None")))
                (when (and port
                           (or (null best)
                               (and (plist-get best :headless)
                                    (not headless))))
                  (setq best (list :namespace ns :name name
                                   :port port :headless headless)))))))
        best)
    (error nil)))

(defun k8s-prom-service (conn)
  "Resolve the Prometheus Service for CONN as a plist, or nil.
Honors `eltainer-prometheus-service'; otherwise auto-discovers,
memoizing the result — including \"found nothing\" — per cluster."
  (cond
   ((eq eltainer-prometheus-service 'disabled) nil)
   ((stringp eltainer-prometheus-service)
    (k8s-prom--parse-spec eltainer-prometheus-service))
   (t
    (let ((server (k8s-connection-server conn)))
      (unless (equal (car k8s-prom--service-cache) server)
        (setq k8s-prom--service-cache
              (cons server (or (k8s-prom--discover conn) 'none))))
      (let ((v (cdr k8s-prom--service-cache)))
        (unless (eq v 'none) v))))))

(defun k8s-prom-available-p (conn)
  "Return non-nil when Prometheus is reachable for CONN."
  (and (k8s-prom-service conn) t))

(defun k8s-prom-status-string (conn)
  "Return \"NS/NAME:PORT\" for CONN's Prometheus Service, or nil."
  (when-let ((svc (k8s-prom-service conn)))
    (format "%s/%s:%s"
            (plist-get svc :namespace)
            (plist-get svc :name)
            (plist-get svc :port))))

;;; ---------------------------------------------------------------------------
;;; Querying

(defun k8s-prom--proxy-path (svc subpath)
  "Build the API-server service-proxy path reaching Prometheus SUBPATH via SVC."
  (format "/api/v1/namespaces/%s/services/%s:%s/proxy%s"
          (plist-get svc :namespace)
          (plist-get svc :name)
          (plist-get svc :port)
          subpath))

(defun k8s-prom--result (conn path)
  "GET PATH (a Prometheus HTTP-API path) via CONN's service proxy.
Return the `result' field of a successful response, else nil."
  (condition-case nil
      (let ((resp (k8s-get conn path)))
        (and (equal (cdr (assq 'status resp)) "success")
             (cdr (assq 'result (cdr (assq 'data resp))))))
    (error nil)))

(defun k8s-prom-query (conn promql)
  "Run the instant PromQL query PROMQL via CONN.
Return the result vector (each element a metric/value alist), or
nil when Prometheus is unavailable or the query fails."
  (when-let ((svc (k8s-prom-service conn)))
    (k8s-prom--result
     conn (k8s-prom--proxy-path
           svc (concat "/api/v1/query?query="
                       (url-hexify-string promql))))))

(defun k8s-prom-query-range (conn promql start end step)
  "Run the range PromQL query PROMQL via CONN.
START and END are epoch seconds, STEP the resolution in seconds.
Return the result vector (each a metric/values matrix entry), or nil."
  (when-let ((svc (k8s-prom-service conn)))
    (k8s-prom--result
     conn (k8s-prom--proxy-path
           svc (format "/api/v1/query_range?query=%s&start=%d&end=%d&step=%d"
                       (url-hexify-string promql)
                       (floor start) (floor end) (max 1 (floor step)))))))

;;; ---------------------------------------------------------------------------
;;; Result extraction

(defun k8s-prom-sample-value (sample)
  "Return the float value of an instant-vector SAMPLE, or nil.
SAMPLE's `value' is the two-element [TIMESTAMP STRINGVAL] array."
  (let ((v (cdr (assq 'value sample))))
    (and (vectorp v) (>= (length v) 2)
         (ignore-errors (string-to-number (aref v 1))))))

(defun k8s-prom-range-values (sample)
  "Return a list of float values (oldest first) from a range SAMPLE.
SAMPLE's `values' is an array of [TIMESTAMP STRINGVAL] arrays."
  (let (out)
    (seq-doseq (pair (or (cdr (assq 'values sample)) []))
      (when (and (vectorp pair) (>= (length pair) 2))
        (push (ignore-errors (string-to-number (aref pair 1))) out)))
    (nreverse (delq nil out))))

;;; ---------------------------------------------------------------------------
;;; Per-node metrics
;;
;; All queries use base node-exporter / node series rather than the
;; kubernetes-mixin recording rules, so they do not depend on a
;; particular Prometheus chart shipping those rules.  Series are mapped
;; back to Kubernetes nodes by `k8s-prom--match-node', which checks
;; every label value against the node name and InternalIP — robust to
;; whether the relevant label is `instance', `node', `nodename', ….

;; Node-matching used to be O(N×L) per sample (dolist NODES × dolist
;; LABELS).  Now we build two hashes once per node-metrics call —
;; NAME-SET and IP→NAME — and the per-sample matcher is O(L).  The
;; hashes live inside one call's lexical scope; they can't go stale
;; because they're rebuilt from the freshly-fetched node list every
;; time `k8s-prom-node-metrics' or its async sibling runs.

(defconst k8s-prom--instance-ip-rx
  "\\`\\([0-9]+\\(?:\\.[0-9]+\\)\\{3\\}\\):[0-9]+\\'"
  "Matches the common `IP:port' shape of node-exporter's `instance' label.")

(defun k8s-prom--make-matcher (nodes)
  "Build a label-to-node lookup from NODES (list of (NAME . IP) conses).
Returns a plist (:names HASH :ips HASH); both map a candidate
label value to the node NAME it identifies."
  (let ((names (make-hash-table :test 'equal))
        (ips   (make-hash-table :test 'equal)))
    (dolist (nd nodes)
      (let ((name (car nd)) (ip (cdr nd)))
        (when name (puthash name name names))
        (when (and ip (stringp ip)) (puthash ip name ips))))
    (list :names names :ips ips)))

(defun k8s-prom--match-node (sample matcher)
  "Return the node name that SAMPLE belongs to, or nil.
MATCHER comes from `k8s-prom--make-matcher'.  Scans the sample's
labels and returns the first hit; handles exact `name', exact `IP',
and the `IP:port' form used by node-exporter's `instance' label."
  (let ((names (plist-get matcher :names))
        (ips   (plist-get matcher :ips)))
    (catch 'hit
      (dolist (lbl (cdr (assq 'metric sample)))
        (let ((v (cdr lbl)))
          (when (stringp v)
            (when-let ((n (gethash v names))) (throw 'hit n))
            (when-let ((n (gethash v ips)))   (throw 'hit n))
            (when (string-match k8s-prom--instance-ip-rx v)
              (when-let ((n (gethash (match-string 1 v) ips)))
                (throw 'hit n))))))
      nil)))

(defun k8s-prom--put (table node key value)
  "Set plist KEY to VALUE for NODE's entry in hash TABLE."
  (when (and node value)
    (puthash node (plist-put (gethash node table) key value) table)))

(defun k8s-prom--fold-instant (samples table matcher key)
  "Fold instant SAMPLES into TABLE under KEY, using MATCHER for node lookup."
  (seq-doseq (sample (or samples []))
    (k8s-prom--put table (k8s-prom--match-node sample matcher)
                   key (k8s-prom-sample-value sample))))

(defun k8s-prom--fold-range (samples table matcher key)
  "Fold range SAMPLES into TABLE under KEY, using MATCHER for node lookup."
  (seq-doseq (sample (or samples []))
    (let ((vals (k8s-prom-range-values sample)))
      (when vals
        (k8s-prom--put table (k8s-prom--match-node sample matcher) key vals)))))

;; The five PromQL strings used by the node view.  Defined once so the
;; sync and async paths can't drift.
(defconst k8s-prom--node-cpu-history-query
  "1 - avg without (cpu) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))"
  "Hour-long CPU-utilisation fraction per `instance', from node-exporter.")
(defconst k8s-prom--node-mem-history-query
  "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes"
  "Hour-long memory-utilisation fraction per `instance', from node-exporter.")

(defun k8s-prom-query-async (conn promql callback)
  "Async instant PromQL.  CALLBACK receives the result vector or nil."
  (let ((svc (k8s-prom-service conn)))
    (if (not svc)
        (funcall callback nil)
      (let ((cfg (k8s-connection-docker-cfg conn))
            (path (k8s-prom--proxy-path
                   svc (concat "/api/v1/query?query="
                               (url-hexify-string promql)))))
        (docker-http-get-async
         cfg path
         (lambda (body)
           (funcall callback
                    (and body
                         (let ((resp (ignore-errors
                                       (json-parse-string
                                        body
                                        :object-type 'alist
                                        :array-type 'array
                                        :null-object nil
                                        :false-object :false))))
                           (and resp
                                (equal (cdr (assq 'status resp)) "success")
                                (cdr (assq 'result
                                           (cdr (assq 'data resp))))))))))))))

(defun k8s-prom-query-range-async (conn promql start end step callback)
  "Async range PromQL.  CALLBACK receives the result matrix vector or nil."
  (let ((svc (k8s-prom-service conn)))
    (if (not svc)
        (funcall callback nil)
      (let ((cfg (k8s-connection-docker-cfg conn))
            (path (k8s-prom--proxy-path
                   svc (format "/api/v1/query_range?query=%s&start=%d&end=%d&step=%d"
                               (url-hexify-string promql)
                               (floor start) (floor end) (max 1 (floor step))))))
        (docker-http-get-async
         cfg path
         (lambda (body)
           (funcall callback
                    (and body
                         (let ((resp (ignore-errors
                                       (json-parse-string
                                        body
                                        :object-type 'alist
                                        :array-type 'array
                                        :null-object nil
                                        :false-object :false))))
                           (and resp
                                (equal (cdr (assq 'status resp)) "success")
                                (cdr (assq 'result
                                           (cdr (assq 'data resp))))))))))))))

(defun k8s-prom-node-metrics (conn nodes)
  "Collect per-node Prometheus metrics for NODES via CONN.
NODES is a list of (NAME . INTERNAL-IP) conses.  Returns a hash
NODE-NAME -> plist with keys :load1 :load5 :load15 (instant scalars)
and :cpu-hist :mem-hist (hour-long fractional value series for the
trend sparklines).  Returns nil when Prometheus is unavailable;
individual keys are simply absent when their series are missing."
  (when (and nodes (k8s-prom-available-p conn))
    (let* ((matcher (k8s-prom--make-matcher nodes))
           (table (make-hash-table :test 'equal))
           (end (float-time))
           (start (- end 3600))
           (step 90)
           ;; All five queries run in parallel.
           (results (k8s--fan-out-sync
                     (list
                      (lambda (cb) (k8s-prom-query-async conn "node_load1"  cb))
                      (lambda (cb) (k8s-prom-query-async conn "node_load5"  cb))
                      (lambda (cb) (k8s-prom-query-async conn "node_load15" cb))
                      (lambda (cb) (k8s-prom-query-range-async
                                    conn k8s-prom--node-cpu-history-query
                                    start end step cb))
                      (lambda (cb) (k8s-prom-query-range-async
                                    conn k8s-prom--node-mem-history-query
                                    start end step cb))))))
      (k8s-prom--fold-instant (nth 0 results) table matcher :load1)
      (k8s-prom--fold-instant (nth 1 results) table matcher :load5)
      (k8s-prom--fold-instant (nth 2 results) table matcher :load15)
      (k8s-prom--fold-range   (nth 3 results) table matcher :cpu-hist)
      (k8s-prom--fold-range   (nth 4 results) table matcher :mem-hist)
      table)))

(defun k8s-prom-node-metrics-async (conn nodes callback)
  "Async variant of `k8s-prom-node-metrics'.
CALLBACK receives the node-name -> plist hash, or nil when
Prometheus is unavailable.  Fires all five queries concurrently."
  (if (or (null nodes) (not (k8s-prom-available-p conn)))
      (funcall callback nil)
    (let* ((matcher (k8s-prom--make-matcher nodes))
           (end (float-time))
           (start (- end 3600))
           (step 90))
      (k8s--fan-out
       (list
        (lambda (cb) (k8s-prom-query-async conn "node_load1"  cb))
        (lambda (cb) (k8s-prom-query-async conn "node_load5"  cb))
        (lambda (cb) (k8s-prom-query-async conn "node_load15" cb))
        (lambda (cb) (k8s-prom-query-range-async
                      conn k8s-prom--node-cpu-history-query
                      start end step cb))
        (lambda (cb) (k8s-prom-query-range-async
                      conn k8s-prom--node-mem-history-query
                      start end step cb)))
       (lambda (results)
         (let ((table (make-hash-table :test 'equal)))
           (k8s-prom--fold-instant (nth 0 results) table matcher :load1)
           (k8s-prom--fold-instant (nth 1 results) table matcher :load5)
           (k8s-prom--fold-instant (nth 2 results) table matcher :load15)
           (k8s-prom--fold-range   (nth 3 results) table matcher :cpu-hist)
           (k8s-prom--fold-range   (nth 4 results) table matcher :mem-hist)
           (funcall callback table)))))))

(provide 'k8s-prom)
;;; k8s-prom.el ends here
