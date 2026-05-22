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

(defun k8s-prom--match-node (sample nodes)
  "Return the node name in NODES that SAMPLE belongs to, or nil.
NODES is a list of (NAME . INTERNAL-IP) conses.  node-exporter
labels the host inconsistently across setups, so this matches any
label value equal to a node name, or equal to / prefixed by an
InternalIP (covering the common \"IP:9100\" `instance' form)."
  (let ((metric (cdr (assq 'metric sample))))
    (catch 'hit
      (dolist (nd nodes)
        (let ((name (car nd)) (ip (cdr nd)))
          (dolist (lbl metric)
            (let ((v (cdr lbl)))
              (when (and (stringp v)
                         (or (equal v name)
                             (and ip (stringp ip)
                                  (or (equal v ip)
                                      (string-prefix-p (concat ip ":") v)))))
                (throw 'hit name))))))
      nil)))

(defun k8s-prom--put (table node key value)
  "Set plist KEY to VALUE for NODE's entry in hash TABLE."
  (when (and node value)
    (puthash node (plist-put (gethash node table) key value) table)))

(defun k8s-prom--collect-instant (conn table nodes key promql)
  "Run instant PROMQL and fold each node's scalar into TABLE under KEY."
  (dolist (sample (append (k8s-prom-query conn promql) nil))
    (k8s-prom--put table (k8s-prom--match-node sample nodes)
                   key (k8s-prom-sample-value sample))))

(defun k8s-prom--collect-range (conn table nodes key promql start end step)
  "Run range PROMQL and fold each node's value series into TABLE under KEY."
  (dolist (sample (append (k8s-prom-query-range conn promql start end step)
                          nil))
    (let ((vals (k8s-prom-range-values sample)))
      (when vals
        (k8s-prom--put table (k8s-prom--match-node sample nodes) key vals)))))

(defun k8s-prom-node-metrics (conn nodes)
  "Collect per-node Prometheus metrics for NODES via CONN.
NODES is a list of (NAME . INTERNAL-IP) conses.  Returns a hash
NODE-NAME -> plist with keys :load1 :load5 :load15 (instant scalars)
and :cpu-hist :mem-hist (hour-long fractional value series for the
trend sparklines).  Returns nil when Prometheus is unavailable;
individual keys are simply absent when their series are missing."
  (when (and nodes (k8s-prom-available-p conn))
    (let ((table (make-hash-table :test 'equal)))
      (k8s-prom--collect-instant conn table nodes :load1  "node_load1")
      (k8s-prom--collect-instant conn table nodes :load5  "node_load5")
      (k8s-prom--collect-instant conn table nodes :load15 "node_load15")
      (let* ((end (float-time))
             (start (- end 3600))
             (step 90))
        (k8s-prom--collect-range
         conn table nodes :cpu-hist
         "1 - avg without (cpu) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))"
         start end step)
        (k8s-prom--collect-range
         conn table nodes :mem-hist
         "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes"
         start end step))
      table)))

(provide 'k8s-prom)
;;; k8s-prom.el ends here
