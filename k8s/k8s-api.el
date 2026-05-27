;;; k8s-api.el --- Pure Elisp Kubernetes API client -*- lexical-binding: t -*-
;;
;; Talks to the Kubernetes API server over HTTPS via the shared
;; `docker-http' transport (Phase B of the merge).  Kubeconfig parsing
;; and resource helpers are k8s-specific; the wire is the same as the
;; Docker engine path.
;;
;; Usage:
;;   (setq conn (k8s-connection-open "/path/to/kubeconfig"))
;;   (k8s-get conn "/api/v1/namespaces")

(require 'cl-lib)
(require 'docker-config)
(require 'docker-http)
(require 'eltainer-shell-helper)
(require 'k8s-config)

;;; ---------------------------------------------------------------------------
;;; Connection struct

(cl-defstruct (k8s-connection (:constructor k8s-connection--new) (:copier nil))
  "Connection parameters for a Kubernetes API server."
  config            ; k8s-config
  cluster           ; k8s-cluster
  user              ; k8s-user
  server            ; string "https://host:port"
  host              ; string
  port              ; integer
  ca-file            ; temp file path for the CA cert, or nil
  client-cert-file   ; temp file path for client cert PEM, or nil
  client-key-file    ; temp file path for client key PEM, or nil
  docker-cfg)        ; a `docker-config' built from the above, used as
                     ; the transport handle for docker-http-request

(defvar k8s-tls-priority "NORMAL:-VERS-TLS1.3"
  "GnuTLS priority string used for K8s API connections.
TLS 1.3 is disabled because Emacs's GnuTLS does not reliably present
client certificates during a 1.3 handshake — the server then sees the
request as `system:anonymous'.  TLS 1.2 with cert auth works.")

;;; ---------------------------------------------------------------------------
;;; Connection open

(defun k8s-connection-open (kubeconfig-path)
  "Open a connection to the K8s cluster defined in KUBECONFIG-PATH.
Returns a `k8s-connection' struct.  The struct carries a `docker-config'
in its `docker-cfg' slot — all subsequent requests go through
`docker-http-request' against that config."
  (let* ((config (k8s-config-load kubeconfig-path))
         (cluster (k8s-config-resolve-cluster config))
         (user (k8s-config-resolve-user config))
         (server (k8s-cluster-server cluster))
         (host-port (k8s--parse-url server))
         (host (car host-port))
         (port (cdr host-port))
         (ca-pem (k8s-cluster-ca-cert-pem cluster))
         (ca-file (k8s-api--temp-pem "k8s-ca-" ca-pem))
         (cert-pem (k8s-user-client-cert-pem user))
         (key-pem (k8s-user-client-key-pem user))
         (client-cert-file (k8s-api--temp-pem "k8s-cert-" cert-pem t))
         (client-key-file (k8s-api--temp-pem "k8s-key-" key-pem t))
         (token (or (k8s-user-token user)
                    (k8s-api--exec-token user)))
         (docker-cfg
          (docker-config--new
           :host host
           :port port
           :tls t
           :tls-verify nil          ; k8s clusters routinely use self-
                                    ; signed certs with no matching SAN
           :tls-ca-cert ca-file
           :tls-cert client-cert-file
           :tls-key client-key-file
           :tls-priority k8s-tls-priority
           :default-headers
           (append
            (when token
              `(("Authorization" . ,(format "Bearer %s" token))))
            '(("Accept" . "application/json")
              ("User-Agent" . "eltainer/0.1"))))))
    (message "eltainer: connecting to %s:%d ..." host port)
    (k8s-connection--new
     :config config
     :cluster cluster
     :user user
     :server server
     :host host
     :port port
     :ca-file ca-file
     :client-cert-file client-cert-file
     :client-key-file client-key-file
     :docker-cfg docker-cfg)))

(defun k8s-api--exec-token (user)
  "Run USER's `exec' plugin, if any, and return the bearer token it emits.

Plugins like `aws eks get-token' or `gke-gcloud-auth-plugin' implement
the client-go ExecCredential protocol: stdout is a JSON
`{ \"kind\": \"ExecCredential\", \"status\": { \"token\": \"…\" } }'.
Returns nil if no exec section is present, the binary isn't on PATH,
the helper exits non-zero, or the JSON is malformed."
  (when-let* ((exec (k8s-user-exec user))
              (command (cdr (assoc "command" exec))))
    (let* ((args (cdr (assoc "args" exec)))
           (env-list (cdr (assoc "env" exec)))
           (env (mapcar (lambda (e)
                          (cons (cdr (assoc "name" e))
                                (cdr (assoc "value" e))))
                        env-list))
           (result (eltainer-shell-helper-json command args nil :env env)))
      (and result
           (cdr (assoc 'token (cdr (assoc 'status result))))))))

(defun k8s-api--temp-pem (prefix pem &optional restrict-mode)
  "Write PEM (a string) to a temp file with PREFIX and return its path."
  (when pem
    (let ((f (make-temp-file prefix nil ".pem")))
      (with-temp-file f
        (set-buffer-multibyte nil)
        (insert pem))
      (when restrict-mode (set-file-modes f #o600))
      f)))

;;; ---------------------------------------------------------------------------
;;; K8s API requests (routed through docker-http-request)

(defun k8s--http-json (conn method path)
  "Send METHOD PATH against CONN.  Return decoded JSON or signal."
  (let* ((cfg (k8s-connection-docker-cfg conn))
         (resp (docker-http-request cfg method path)))
    (unless (docker-http-ok-p resp)
      (error "K8s API request failed: %s %s [%d]"
             method path (docker-http-response-status resp)))
    ;; Native JSON returns alists/lists per docker-http-json; k8s code
    ;; downstream reads `.items' as a vector (the old json-read default
    ;; for arrays).  `:array-type 'array' on json-parse-string preserves
    ;; that — keep it for now and revisit when the k8s readers move to
    ;; lists.
    (let ((body (docker-http-response-body resp)))
      (when (and body (> (length body) 0))
        (json-parse-string body
                           :object-type 'alist
                           :array-type 'array
                           :null-object nil
                           :false-object :false)))))

(defun k8s-get (conn path)
  "Perform a GET request to PATH on the K8s API via CONN."
  (k8s--http-json conn "GET" path))

;;; ---------------------------------------------------------------------------
;;; Async + parallel primitives
;;
;; Most K8s operations have always been synchronous: `k8s-get' blocks
;; on `accept-process-output' until the response is fully buffered.
;; That's fine for one-shot fetches, but views that need N+1 round-
;; trips (e.g. kubelet Summary per node, Prometheus query bundle)
;; serialize those calls on the timer and stall Emacs for seconds.
;;
;; The primitives below let those callers fan out independent requests
;; in parallel and barrier-wait for all to complete (or time out).

;; Concurrency primitives live in `docker-http.el' so the docker
;; half can share them; alias them under `k8s--' for symmetry with
;; the existing `k8s--' helpers.
(defalias 'k8s--fan-out      #'docker-http-fan-out)
(defalias 'k8s--fan-out-sync #'docker-http-fan-out-sync)

(defun k8s-get-async (conn path callback)
  "Async GET PATH on CONN.  CALLBACK receives the parsed JSON alist,
or nil when the request fails or the body is unparseable."
  (let ((cfg (k8s-connection-docker-cfg conn)))
    (docker-http-get-async
     cfg path
     (lambda (body)
       (funcall callback
                (and body (> (length body) 0)
                     (ignore-errors
                       (json-parse-string body
                                          :object-type 'alist
                                          :array-type 'array
                                          :null-object nil
                                          :false-object :false))))))))

(defun k8s-list-pods-async (conn namespace callback)
  "List pods via CONN asynchronously, optionally in NAMESPACE.
CALLBACK receives the items vector, or nil on failure."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/pods" namespace)
                "/api/v1/pods")))
    (k8s-get-async
     conn path
     (lambda (json)
       (funcall callback (and json (cdr (assq 'items json))))))))

(defun k8s-stats-summary-async (conn node callback)
  "Async wrapper around `k8s-stats-summary'.  CALLBACK receives the
decoded kubelet Summary alist for NODE, or nil on failure."
  (k8s-get-async
   conn
   (format "/api/v1/nodes/%s/proxy/stats/summary" (url-hexify-string node))
   callback))


(defun k8s-delete (conn path)
  "Perform a DELETE request to PATH on the K8s API via CONN."
  (k8s--http-json conn "DELETE" path))

(defconst k8s--list-api-paths
  '((pods         "/api/v1/pods"
                  "/api/v1/namespaces/%s/pods")
    (deployments  "/apis/apps/v1/deployments"
                  "/apis/apps/v1/namespaces/%s/deployments")
    (services     "/api/v1/services"
                  "/api/v1/namespaces/%s/services")
    (statefulsets "/apis/apps/v1/statefulsets"
                  "/apis/apps/v1/namespaces/%s/statefulsets")
    (daemonsets   "/apis/apps/v1/daemonsets"
                  "/apis/apps/v1/namespaces/%s/daemonsets")
    (jobs         "/apis/batch/v1/jobs"
                  "/apis/batch/v1/namespaces/%s/jobs")
    (cronjobs     "/apis/batch/v1/cronjobs"
                  "/apis/batch/v1/namespaces/%s/cronjobs")
    (configmaps   "/api/v1/configmaps"
                  "/api/v1/namespaces/%s/configmaps")
    (secrets      "/api/v1/secrets"
                  "/api/v1/namespaces/%s/secrets")
    (ingresses    "/apis/networking.k8s.io/v1/ingresses"
                  "/apis/networking.k8s.io/v1/namespaces/%s/ingresses")
    (sandboxes    "/apis/agents.x-k8s.io/v1alpha1/sandboxes"
                  "/apis/agents.x-k8s.io/v1alpha1/namespaces/%s/sandboxes")
    (horizontalpodautoscalers
     "/apis/autoscaling/v2/horizontalpodautoscalers"
     "/apis/autoscaling/v2/namespaces/%s/horizontalpodautoscalers")
    (poddisruptionbudgets
     "/apis/policy/v1/poddisruptionbudgets"
     "/apis/policy/v1/namespaces/%s/poddisruptionbudgets")
    (persistentvolumes
     "/api/v1/persistentvolumes"
     "/api/v1/persistentvolumes")        ; cluster-scoped
    (persistentvolumeclaims
     "/api/v1/persistentvolumeclaims"
     "/api/v1/namespaces/%s/persistentvolumeclaims")
    (storageclasses
     "/apis/storage.k8s.io/v1/storageclasses"
     "/apis/storage.k8s.io/v1/storageclasses") ; cluster-scoped
    (networkpolicies
     "/apis/networking.k8s.io/v1/networkpolicies"
     "/apis/networking.k8s.io/v1/namespaces/%s/networkpolicies"))
  "Alist mapping resource types (plural) to (ALL-PATH NAMESPACED-PATH-TEMPLATE).
Keys are plural to match `k8s--define-view's macro name convention.")

(defvar k8s--list-api-paths-hash nil
  "Hash-table index of `k8s--list-api-paths' for O(1) lookup.
Built at load time by `k8s--rebuild-path-hashes'; the alist
above remains the source of truth.")

(defvar k8s--resource-api-paths-hash nil
  "Hash-table index of `k8s--resource-api-paths' (see above).")

(defun k8s--rebuild-path-hashes ()
  "Re-index the path alists into hash tables.
Run at load time, and again if either alist is ever mutated at
runtime (which today it isn't — but the indirection keeps the
two forms in sync without a per-render `assq')."
  (let ((lh (make-hash-table :test 'eq :size 32)))
    (dolist (entry k8s--list-api-paths)
      (puthash (car entry) (cdr entry) lh))
    (setq k8s--list-api-paths-hash lh)))

(defun k8s--list-path (type &optional namespace label-selector)
  "Return the API list path for resource TYPE.
With NAMESPACE, build the namespaced path; otherwise the
cluster-wide variant.  With LABEL-SELECTOR (a non-empty string in
the K8s `labelSelector' mini-language: `a=b,c!=d,key,!key'),
append it as a `?labelSelector=' query so the API server narrows
the response."
  (let* ((entry (gethash type k8s--list-api-paths-hash))
         (base (if namespace
                   (format (cadr entry) namespace)
                 (car entry))))
    (if (and label-selector (not (string-empty-p label-selector)))
        (format "%s?labelSelector=%s"
                base (url-hexify-string label-selector))
      base)))

(defconst k8s--resource-api-paths
  '((pod         . "/api/v1/namespaces/%s/pods/%s")
    (deployment  . "/apis/apps/v1/namespaces/%s/deployments/%s")
    (service     . "/api/v1/namespaces/%s/services/%s")
    (statefulset . "/apis/apps/v1/namespaces/%s/statefulsets/%s")
    (daemonset   . "/apis/apps/v1/namespaces/%s/daemonsets/%s")
    (job         . "/apis/batch/v1/namespaces/%s/jobs/%s")
    (cronjob     . "/apis/batch/v1/namespaces/%s/cronjobs/%s")
    (configmap   . "/api/v1/namespaces/%s/configmaps/%s")
    (secret      . "/api/v1/namespaces/%s/secrets/%s")
    (ingress     . "/apis/networking.k8s.io/v1/namespaces/%s/ingresses/%s")
    (sandbox     . "/apis/agents.x-k8s.io/v1alpha1/namespaces/%s/sandboxes/%s")
    (horizontalpodautoscaler . "/apis/autoscaling/v2/namespaces/%s/horizontalpodautoscalers/%s")
    (poddisruptionbudget . "/apis/policy/v1/namespaces/%s/poddisruptionbudgets/%s")
    ;; Cluster-scoped: use `%2$s' so callers still pass (NAMESPACE NAME).
    (persistentvolume . "/api/v1/persistentvolumes/%2$s")
    (persistentvolumeclaim . "/api/v1/namespaces/%s/persistentvolumeclaims/%s")
    (storageclass . "/apis/storage.k8s.io/v1/storageclasses/%2$s")
    (networkpolicy . "/apis/networking.k8s.io/v1/namespaces/%s/networkpolicies/%s"))
  "Alist mapping section types to API path templates (namespace, name).")

(defun k8s-delete-resource (conn type namespace name)
  "Delete resource of TYPE named NAME in NAMESPACE via CONN."
  (let ((template (gethash type k8s--resource-api-paths-hash)))
    (unless template
      (error "Don't know how to delete %s" type))
    (k8s-delete conn (format template namespace name))))

;; Finish wiring up the hash indices now that both alists are defined.
(let ((rh (make-hash-table :test 'eq :size 32)))
  (dolist (entry k8s--resource-api-paths)
    (puthash (car entry) (cdr entry) rh))
  (setq k8s--resource-api-paths-hash rh))
(k8s--rebuild-path-hashes)

(defun k8s-get-text (conn path)
  "Perform a GET request to PATH on the K8s API via CONN.
Returns the raw response body as a string (for non-JSON endpoints like logs)."
  (let* ((cfg (k8s-connection-docker-cfg conn))
         (resp (docker-http-request
                cfg "GET" path
                :headers '(("Accept" . "text/plain")))))
    (when (docker-http-ok-p resp)
      (docker-http-response-body resp))))

(defun k8s-pod-logs (conn namespace name &optional tail-lines container)
  "Fetch logs for pod NAME in NAMESPACE via CONN.
Returns log text as a string.  TAIL-LINES limits to last N lines.
CONTAINER specifies which container (required for multi-container pods)."
  (let* ((params (list (format "tailLines=%d" (or tail-lines 100))))
         (_ (when container
              (push (format "container=%s" container) params)))
         (query (mapconcat #'identity params "&"))
         (path (format "/api/v1/namespaces/%s/pods/%s/log?%s"
                       namespace name query)))
    (or (k8s-get-text conn path) "")))

;;; ---------------------------------------------------------------------------
;;; Convenience functions

(defun k8s-list-namespaces (conn)
  "List all namespaces via CONN.  Returns a vector of namespace alists."
  (cdr (assq 'items (k8s-get conn "/api/v1/namespaces"))))

(defun k8s-list-nodes (conn)
  "List all cluster nodes via CONN.  Returns a vector of node alists.
Nodes are cluster-scoped — there is no namespaced variant."
  (cdr (assq 'items (k8s-get conn "/api/v1/nodes"))))

(defun k8s-list-pods (conn &optional namespace)
  "List pods via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/pods" namespace)
                "/api/v1/pods")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-pods-by-selector (conn namespace selector)
  "List pods in NAMESPACE that match SELECTOR via CONN.
SELECTOR is an alist of (LABEL-NAME . LABEL-VALUE) — names may be
strings or symbols.  Returns a list (not a vector) of pod alists,
or nil when nothing matches / the call fails.

Server-side filtering via the K8s API's `labelSelector' query
param, so the wire payload only carries matching pods."
  (let* ((parts (mapcar (lambda (kv)
                          (let ((k (car kv)) (v (cdr kv)))
                            (format "%s=%s"
                                    (if (symbolp k) (symbol-name k) k)
                                    (if (symbolp v) (symbol-name v) v))))
                        selector))
         (sel-str (mapconcat #'identity parts ","))
         (path (format "/api/v1/namespaces/%s/pods?labelSelector=%s"
                       namespace (url-hexify-string sel-str))))
    (condition-case nil
        (append (cdr (assq 'items (k8s-get conn path))) nil)
      (error nil))))

(defun k8s-list-deployments (conn &optional namespace)
  "List deployments via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/deployments" namespace)
                "/apis/apps/v1/deployments")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-services (conn &optional namespace)
  "List services via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/services" namespace)
                "/api/v1/services")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-statefulsets (conn &optional namespace)
  "List statefulsets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/statefulsets" namespace)
                "/apis/apps/v1/statefulsets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-daemonsets (conn &optional namespace)
  "List daemonsets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/daemonsets" namespace)
                "/apis/apps/v1/daemonsets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-jobs (conn &optional namespace)
  "List jobs via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/batch/v1/namespaces/%s/jobs" namespace)
                "/apis/batch/v1/jobs")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-cronjobs (conn &optional namespace)
  "List cronjobs via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/batch/v1/namespaces/%s/cronjobs" namespace)
                "/apis/batch/v1/cronjobs")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-configmaps (conn &optional namespace)
  "List configmaps via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/configmaps" namespace)
                "/api/v1/configmaps")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-secrets (conn &optional namespace)
  "List secrets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/secrets" namespace)
                "/api/v1/secrets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-ingresses (conn &optional namespace)
  "List ingresses via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/networking.k8s.io/v1/namespaces/%s/ingresses"
                          namespace)
                "/apis/networking.k8s.io/v1/ingresses")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-sandboxes (conn &optional namespace)
  "List agent-sandbox Sandboxes via CONN, optionally in NAMESPACE.
Returns nil (rather than erroring) when the `agents.x-k8s.io' CRD
isn't installed in the cluster — callers degrade gracefully."
  (let ((path (if namespace
                  (format "/apis/agents.x-k8s.io/v1alpha1/namespaces/%s/sandboxes"
                          namespace)
                "/apis/agents.x-k8s.io/v1alpha1/sandboxes")))
    (condition-case nil
        (cdr (assq 'items (k8s-get conn path)))
      (error nil))))

(defun k8s-get-resource (conn path)
  "GET a single resource at PATH via CONN."
  (k8s-get conn path))

;;; ---------------------------------------------------------------------------
;;; Metrics (metrics.k8s.io — served by metrics-server)

(defun k8s-metrics-list-pods (conn &optional namespace)
  "List pod metrics via CONN, optionally limited to NAMESPACE.
Returns a vector of PodMetrics, or nil when the `metrics.k8s.io'
API group is unavailable — i.e. metrics-server isn't installed.
The nil return lets callers degrade gracefully rather than error."
  (let ((path (if namespace
                  (format "/apis/metrics.k8s.io/v1beta1/namespaces/%s/pods"
                          namespace)
                "/apis/metrics.k8s.io/v1beta1/pods")))
    (condition-case nil
        (cdr (assq 'items (k8s-get conn path)))
      (error nil))))

(defun k8s-metrics-list-nodes (conn)
  "List node metrics via CONN.
Returns a vector of NodeMetrics, or nil when `metrics.k8s.io' is
unavailable."
  (condition-case nil
      (cdr (assq 'items
                 (k8s-get conn "/apis/metrics.k8s.io/v1beta1/nodes")))
    (error nil)))

(defun k8s-stats-summary (conn node)
  "Fetch the kubelet Summary API for NODE via CONN.
Returns the decoded summary alist (its `pods' entry carries
per-pod network counters and per-container `rootfs' disk usage),
or nil when unavailable — the `nodes/proxy' subresource needs RBAC
not every kubeconfig has, and the kubelet may be unreachable."
  (condition-case nil
      (k8s-get conn (format "/api/v1/nodes/%s/proxy/stats/summary"
                            (url-hexify-string node)))
    (error nil)))

(defun k8s--extract-resource-version (response)
  "Return metadata.resourceVersion from a list RESPONSE."
  (cdr (assq 'resourceVersion (cdr (assq 'metadata response)))))

(defun k8s-list-hpas (conn &optional namespace)
  "List HorizontalPodAutoscalers via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/autoscaling/v2/namespaces/%s/horizontalpodautoscalers" namespace)
                "/apis/autoscaling/v2/horizontalpodautoscalers")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-pdbs (conn &optional namespace)
  "List PodDisruptionBudgets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/policy/v1/namespaces/%s/poddisruptionbudgets" namespace)
                "/apis/policy/v1/poddisruptionbudgets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-pvs (conn &optional _namespace)
  "List PersistentVolumes via CONN (cluster-scoped — NAMESPACE ignored)."
  (cdr (assq 'items (k8s-get conn "/api/v1/persistentvolumes"))))

(defun k8s-list-pvcs (conn &optional namespace)
  "List PersistentVolumeClaims via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/persistentvolumeclaims" namespace)
                "/api/v1/persistentvolumeclaims")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-storageclasses (conn &optional _namespace)
  "List StorageClasses via CONN (cluster-scoped)."
  (cdr (assq 'items (k8s-get conn "/apis/storage.k8s.io/v1/storageclasses"))))

(defun k8s-list-networkpolicies (conn &optional namespace)
  "List NetworkPolicies via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/networking.k8s.io/v1/namespaces/%s/networkpolicies" namespace)
                "/apis/networking.k8s.io/v1/networkpolicies")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-events (conn namespace &optional field-selector)
  "List events in NAMESPACE via CONN, optionally filtered by FIELD-SELECTOR."
  (let* ((query (if field-selector
                    (format "?fieldSelector=%s"
                            (url-hexify-string field-selector))
                  ""))
         (path (format "/api/v1/namespaces/%s/events%s" namespace query)))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-events-all (conn &optional field-selector)
  "List events cluster-wide via CONN, optionally filtered by FIELD-SELECTOR."
  (let* ((query (if field-selector
                    (format "?fieldSelector=%s"
                            (url-hexify-string field-selector))
                  ""))
         (path (format "/api/v1/events%s" query)))
    (cdr (assq 'items (k8s-get conn path)))))

;;; ---------------------------------------------------------------------------
;;; Error condition

(define-error 'k8s-api-error "Kubernetes API error")

(provide 'k8s-api)
;;; k8s-api.el ends here
