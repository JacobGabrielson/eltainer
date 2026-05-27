;;; k8s-xray.el --- "xray" resource-tree view for a workload -*- lexical-binding: t -*-
;;
;; `T' on a Deployment / StatefulSet / DaemonSet / Job / CronJob /
;; ReplicaSet / Service row opens `*k8s:xray:NS/KIND/NAME*' — a
;; magit-section tree that descends from the workload through every
;; layer of its dependency graph:
;;
;;   Deployment   bookstore-api
;;   └── ReplicaSet  bookstore-api-7d9c   (3/3 ready)
;;       ├── Pod  bookstore-api-7d9c-abc  Running
;;       │   ├── Container  api          (image / status)
;;       │   │   └── Volumes: configmap/api-config  pvc/data
;;       │   └── Container  sidecar      ...
;;       └── Pod  bookstore-api-7d9c-def  ...
;;
;; Every level is a magit-section so `TAB' folds it.  `RET' on a
;; leaf cycles to the natural follow-up (Pod → logs / exec; Volume
;; → owning ConfigMap or Secret view).
;;
;; Scope of v1:
;; - Deployments → ReplicaSets → Pods.
;; - StatefulSets / DaemonSets → Pods directly (no intermediate RS).
;; - Jobs → Pods.  CronJobs → Jobs → Pods.
;; - Services → Endpoints (which point at Pods) → Pods.
;; - Per-Pod: containers, init containers, and the Pod's mounted
;;   Volumes (ConfigMap / Secret / PVC references made into jump
;;   targets via `k8s-jump-target').

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'k8s-api)
(require 'k8s-marks)
(require 'k8s)

(defgroup k8s-xray nil
  "xray tree view for a workload."
  :group 'k8s
  :prefix "k8s-xray-")

;;; ---------------------------------------------------------------------------
;;; Helpers

(defun k8s-xray--selector-labels (selector)
  "Return SELECTOR (a `.spec.selector' value) as a labelSelector string."
  (let ((match-labels (cdr (assq 'matchLabels selector))))
    (if match-labels
        (mapconcat (lambda (kv)
                     (format "%s=%s"
                             (let ((k (car kv)))
                               (if (symbolp k) (symbol-name k) k))
                             (let ((v (cdr kv)))
                               (if (symbolp v) (symbol-name v) v))))
                   match-labels ",")
      "")))

(defun k8s-xray--list-by-selector (conn path selector-labels)
  "GET PATH with `?labelSelector=SELECTOR-LABELS', return items."
  (let ((full (if (string-empty-p selector-labels)
                  path
                (format "%s?labelSelector=%s"
                        path (url-hexify-string selector-labels)))))
    (append (cdr (assq 'items (k8s-get conn full))) nil)))

(defun k8s-xray--rs-pod-status (rs)
  "Return a short ready-string for ReplicaSet RS (`N/M ready')."
  (let* ((status (cdr (assq 'status rs)))
         (ready (or (cdr (assq 'readyReplicas status)) 0))
         (replicas (or (cdr (assq 'replicas status)) 0)))
    (format "%d/%d ready" ready replicas)))

(defun k8s-xray--pod-phase (pod)
  (or (cdr (assq 'phase (cdr (assq 'status pod)))) "?"))

(defun k8s-xray--container-image (c)
  (or (cdr (assq 'image c)) "?"))

(defun k8s-xray--container-status (pod cname)
  "Return a short status string for container CNAME in POD.
Checks both `containerStatuses' and `initContainerStatuses' since
init containers report into the latter."
  (let* ((status (cdr (assq 'status pod)))
         (statuses (append
                    (or (cdr (assq 'containerStatuses status)) [])
                    (or (cdr (assq 'initContainerStatuses status)) [])
                    nil))
         (cs (cl-find-if (lambda (s) (equal (cdr (assq 'name s)) cname))
                         statuses))
         (ready (cdr (assq 'ready cs)))
         (restarts (cdr (assq 'restartCount cs)))
         (state (cdr (assq 'state cs))))
    (cond
     ((null cs) "?")
     ((assq 'running state)
      (format "Running, %d restart%s" (or restarts 0)
              (if (= (or restarts 0) 1) "" "s")))
     ((assq 'waiting state)
      (let ((reason (cdr (assq 'reason (cdr (assq 'waiting state))))))
        (format "Waiting (%s)" (or reason "?"))))
     ((assq 'terminated state)
      (let ((reason (cdr (assq 'reason (cdr (assq 'terminated state))))))
        (format "Terminated (%s)" (or reason "?"))))
     (t (format "ready=%s" ready)))))

(defun k8s-xray--volume-target (vol)
  "Return a jump-target description for VOL (a pod spec volume), or nil
when the volume is scratch (emptyDir, no referent to jump to).
Test with `assq' rather than `cdr (assq …)' because an empty object
\(`{}', common for `emptyDir' / `projected') decodes to nil — the
key presence is the signal, not the value's truthiness."
  (let* ((name (cdr (assq 'name vol))))
    (cond
     ((assq 'configMap vol)
      (list :kind "ConfigMap"
            :name (cdr (assq 'name (cdr (assq 'configMap vol))))
            :mount name))
     ((assq 'secret vol)
      (list :kind "Secret"
            :name (cdr (assq 'secretName (cdr (assq 'secret vol))))
            :mount name))
     ((assq 'persistentVolumeClaim vol)
      (list :kind "PersistentVolumeClaim"
            :name (cdr (assq 'claimName
                              (cdr (assq 'persistentVolumeClaim vol))))
            :mount name))
     ((assq 'projected vol)
      (list :kind "[projected]" :name name :mount name))
     ((assq 'emptyDir vol)
      (list :kind "[emptyDir]" :name name :mount name))
     ((assq 'hostPath vol)
      (list :kind "[hostPath]"
            :name (cdr (assq 'path (cdr (assq 'hostPath vol))))
            :mount name))
     ((assq 'downwardAPI vol)
      (list :kind "[downwardAPI]" :name name :mount name))
     (t
      (list :kind "[other]" :name name :mount name)))))

(defun k8s-xray--volume-jump-target (vol-plist ns)
  "Return a `k8s-jump-target' value for VOL-PLIST or nil."
  (pcase (plist-get vol-plist :kind)
    ("ConfigMap"             (list 'helm-resources ns "ConfigMap"
                                   (list (plist-get vol-plist :name))))
    ("Secret"                (list 'helm-resources ns "Secret"
                                   (list (plist-get vol-plist :name))))
    ;; PVC has no dedicated view yet; render the row inert until then.
    (_ nil)))

;;; ---------------------------------------------------------------------------
;;; Tree fetchers
;;
;; Returns a plist describing the children for a node.  The renderer
;; then walks the result and emits sections.

(defun k8s-xray--children-of-deployment (conn ns deploy)
  "Return list of ReplicaSets owned by DEPLOY in NS via CONN.
Uses `?labelSelector=' from the deployment's `spec.selector', then
client-side filters to those with `ownerReferences' actually
pointing at this Deployment (since selectors may overlap)."
  (let* ((spec (cdr (assq 'spec deploy)))
         (selector (k8s-xray--selector-labels (cdr (assq 'selector spec))))
         (uid (cdr (assq 'uid (cdr (assq 'metadata deploy)))))
         (rss (k8s-xray--list-by-selector
                conn
                (format "/apis/apps/v1/namespaces/%s/replicasets" ns)
                selector)))
    (seq-filter
     (lambda (rs)
       (let ((owners (append
                      (or (cdr (assq 'ownerReferences
                                      (cdr (assq 'metadata rs))))
                          [])
                      nil)))
         (cl-some (lambda (o) (equal uid (cdr (assq 'uid o)))) owners)))
     rss)))

(defun k8s-xray--children-of-replicaset (conn ns rs)
  "Pods owned by ReplicaSet RS."
  (let* ((spec (cdr (assq 'spec rs)))
         (selector (k8s-xray--selector-labels (cdr (assq 'selector spec))))
         (uid (cdr (assq 'uid (cdr (assq 'metadata rs))))))
    (seq-filter
     (lambda (pod)
       (let ((owners (append
                      (or (cdr (assq 'ownerReferences
                                      (cdr (assq 'metadata pod))))
                          [])
                      nil)))
         (cl-some (lambda (o) (equal uid (cdr (assq 'uid o)))) owners)))
     (k8s-xray--list-by-selector
      conn (format "/api/v1/namespaces/%s/pods" ns) selector))))

(defun k8s-xray--children-of-statefulset-or-daemonset (conn ns obj)
  "Pods directly owned by a StatefulSet / DaemonSet."
  (let* ((spec (cdr (assq 'spec obj)))
         (selector (k8s-xray--selector-labels (cdr (assq 'selector spec))))
         (uid (cdr (assq 'uid (cdr (assq 'metadata obj))))))
    (seq-filter
     (lambda (pod)
       (let ((owners (append
                      (or (cdr (assq 'ownerReferences
                                      (cdr (assq 'metadata pod))))
                          [])
                      nil)))
         (cl-some (lambda (o) (equal uid (cdr (assq 'uid o)))) owners)))
     (k8s-xray--list-by-selector
      conn (format "/api/v1/namespaces/%s/pods" ns) selector))))

(defun k8s-xray--children-of-job (conn ns job)
  "Pods directly owned by a Job."
  (k8s-xray--children-of-statefulset-or-daemonset conn ns job))

(defun k8s-xray--children-of-cronjob (conn ns cj)
  "Jobs owned by a CronJob (latest first)."
  (let ((uid (cdr (assq 'uid (cdr (assq 'metadata cj))))))
    (seq-filter
     (lambda (j)
       (let ((owners (append
                      (or (cdr (assq 'ownerReferences
                                      (cdr (assq 'metadata j))))
                          [])
                      nil)))
         (cl-some (lambda (o) (equal uid (cdr (assq 'uid o)))) owners)))
     (sort (append (cdr (assq 'items
                               (k8s-get
                                conn
                                (format "/apis/batch/v1/namespaces/%s/jobs" ns))))
                   nil)
           (lambda (a b)
             (string>
              (or (cdr (assq 'creationTimestamp (cdr (assq 'metadata a)))) "")
              (or (cdr (assq 'creationTimestamp (cdr (assq 'metadata b)))) "")))))))

(defun k8s-xray--children-of-service (conn ns svc)
  "Pods backing a Service via its selector (a generous read — endpoints
would be more accurate but require a second API call)."
  (let* ((selector (cdr (assq 'selector (cdr (assq 'spec svc)))))
         (sel-str (k8s-xray--selector-labels
                   ;; Service selectors are a flat alist, not
                   ;; matchLabels — wrap for the helper.
                   `((matchLabels . ,selector)))))
    (when (and selector (> (length sel-str) 0))
      (k8s-xray--list-by-selector
       conn (format "/api/v1/namespaces/%s/pods" ns) sel-str))))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defface k8s-xray-kind '((t :inherit eltainer-section-heading))
  "Face for kind labels in the xray tree."
  :group 'k8s-xray)

(defun k8s-xray--row (indent kind name extra)
  "Format one tree row at INDENT (string) with KIND / NAME / EXTRA."
  (format "%s%s  %s  %s\n"
          indent
          (propertize (format "%-12s" kind) 'font-lock-face 'k8s-xray-kind)
          (propertize name 'font-lock-face 'k8s-resource-name)
          (propertize extra 'font-lock-face 'k8s-dim)))

(defun k8s-xray--insert-mount (mnt volumes ns indent)
  "Emit one volumeMount row at INDENT.
MNT is a `volumeMount' alist on the container; VOLUMES is the pod's
`spec.volumes' as a list; NS is the pod's namespace."
  (let* ((mount-name (cdr (assq 'name mnt)))
         (mount-path (cdr (assq 'mountPath mnt)))
         (vol (cl-find-if
               (lambda (v) (equal mount-name (cdr (assq 'name v))))
               volumes))
         (vol-info (and vol (k8s-xray--volume-target vol)))
         (label (if vol-info
                    (format "%s/%s"
                            (plist-get vol-info :kind)
                            (or (plist-get vol-info :name) "?"))
                  "[scratch]"))
         (jump (and vol-info (k8s-xray--volume-jump-target vol-info ns)))
         (helpe (and vol-info
                     (format "RET: jump to %s/%s"
                             (plist-get vol-info :kind)
                             (or (plist-get vol-info :name) "?")))))
    (insert
     (propertize (format "%s    %-32s  %s\n" indent label mount-path)
                 'font-lock-face 'k8s-dim
                 'k8s-jump-target jump
                 'help-echo helpe))))

(defun k8s-xray--insert-container (pod ns c is-init indent)
  "Emit a Container (or InitContainer) section + its mounts."
  (let* ((cname (cdr (assq 'name c)))
         (kind (if is-init "InitContainer" "Container"))
         (volumes (append
                   (or (cdr (assq 'volumes (cdr (assq 'spec pod)))) [])
                   nil))
         (mounts (append (or (cdr (assq 'volumeMounts c)) []) nil)))
    (magit-insert-section (xray-container c t)
      (magit-insert-heading
        (k8s-xray--row (concat indent "  ") kind cname
                       (format "%s · %s"
                               (k8s-xray--container-image c)
                               (k8s-xray--container-status pod cname))))
      (dolist (mnt mounts)
        (k8s-xray--insert-mount mnt volumes ns indent)))))

(defun k8s-xray--insert-pod (_conn pod indent)
  "Insert a Pod section: containers + their volume mounts."
  (let* ((meta (cdr (assq 'metadata pod)))
         (name (cdr (assq 'name meta)))
         (ns (cdr (assq 'namespace meta)))
         (spec (cdr (assq 'spec pod)))
         (containers (append (or (cdr (assq 'containers spec)) []) nil))
         (init-containers
          (append (or (cdr (assq 'initContainers spec)) []) nil))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (xray-pod pod t)
      (magit-insert-heading
        (k8s-xray--row indent "Pod" name
                       (format "%s · %s" (k8s-xray--pod-phase pod) age)))
      (dolist (c init-containers)
        (k8s-xray--insert-container pod ns c t indent))
      (dolist (c containers)
        (k8s-xray--insert-container pod ns c nil indent)))))

(defun k8s-xray--insert-replicaset (conn ns rs indent)
  (let* ((meta (cdr (assq 'metadata rs)))
         (name (cdr (assq 'name meta))))
    (magit-insert-section (xray-rs rs t)
      (magit-insert-heading
        (k8s-xray--row indent "ReplicaSet" name (k8s-xray--rs-pod-status rs)))
      (dolist (pod (k8s-xray--children-of-replicaset conn ns rs))
        (k8s-xray--insert-pod conn pod (concat indent "  "))))))

(defun k8s-xray--insert-job (conn ns job indent)
  (let* ((meta (cdr (assq 'metadata job)))
         (name (cdr (assq 'name meta)))
         (status (cdr (assq 'status job)))
         (succeeded (or (cdr (assq 'succeeded status)) 0))
         (failed (or (cdr (assq 'failed status)) 0)))
    (magit-insert-section (xray-job job t)
      (magit-insert-heading
        (k8s-xray--row indent "Job" name
                       (format "%d succeeded · %d failed" succeeded failed)))
      (dolist (pod (k8s-xray--children-of-job conn ns job))
        (k8s-xray--insert-pod conn pod (concat indent "  "))))))

(defun k8s-xray--insert-direct-pods (conn ns owner _kind indent)
  "Insert pods directly owned by OWNER (StatefulSet / DaemonSet)."
  (dolist (pod (k8s-xray--children-of-statefulset-or-daemonset
                conn ns owner))
    (k8s-xray--insert-pod conn pod indent)))

(defun k8s-xray--describe-root (kind obj)
  (let* ((meta (cdr (assq 'metadata obj)))
         (name (cdr (assq 'name meta)))
         (status (cdr (assq 'status obj)))
         (replicas (cdr (assq 'replicas status)))
         (ready (or (cdr (assq 'readyReplicas status)) 0)))
    (k8s-xray--row "" kind name
                   (cond
                    (replicas (format "%d/%d ready" ready replicas))
                    (t "")))))

(defun k8s-xray--refresh-with (conn ns kind obj)
  "Render the xray of (KIND, OBJ) into the current buffer.
KIND is one of `Deployment' / `StatefulSet' / `DaemonSet' / `Job' /
`CronJob' / `Service' / `ReplicaSet'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (xray-root)
      (insert (k8s-xray--describe-root kind obj))
      (insert "\n")
      (pcase kind
        ("Deployment"
         (dolist (rs (k8s-xray--children-of-deployment conn ns obj))
           (k8s-xray--insert-replicaset conn ns rs "  ")))
        ("ReplicaSet"
         (k8s-xray--insert-replicaset conn ns obj "  "))
        ((or "StatefulSet" "DaemonSet")
         (k8s-xray--insert-direct-pods conn ns obj kind "  "))
        ("Job"
         (dolist (pod (k8s-xray--children-of-job conn ns obj))
           (k8s-xray--insert-pod conn pod "  ")))
        ("CronJob"
         (dolist (job (k8s-xray--children-of-cronjob conn ns obj))
           (k8s-xray--insert-job conn ns job "  ")))
        ("Service"
         (dolist (pod (k8s-xray--children-of-service conn ns obj))
           (k8s-xray--insert-pod conn pod "  ")))
        ("Pod"
         (k8s-xray--insert-pod conn obj "  "))
        (_
         (insert (propertize
                  (format "  (xray for %s is not implemented yet)\n" kind)
                  'font-lock-face 'k8s-dim)))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar-local k8s-xray--ns nil)
(defvar-local k8s-xray--kind nil)
(defvar-local k8s-xray--obj nil)

(defvar k8s-xray-mode-map (make-sparse-keymap)
  "Keymap for `k8s-xray-mode'.")
(set-keymap-parent k8s-xray-mode-map k8s-common-map)

(define-derived-mode k8s-xray-mode magit-section-mode "K8s:Xray"
  "Recursive tree view of a workload's dependency graph.

\\{k8s-xray-mode-map}"
  :interactive nil
  :group 'k8s-xray
  (setq-local revert-buffer-function
              (lambda (_a _b)
                (k8s-xray--refresh-with (k8s--ensure-connection)
                                        k8s-xray--ns
                                        k8s-xray--kind
                                        k8s-xray--obj)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces)))

;;;###autoload
(defun k8s-xray (kind ns obj)
  "Open the xray tree for OBJ (an alist of KIND in NS).
KIND is the K8s kind string: `Deployment', `StatefulSet', etc."
  (let* ((name (cdr (assq 'name (cdr (assq 'metadata obj)))))
         (buf (get-buffer-create
               (format "*k8s:xray:%s/%s/%s*" ns kind name))))
    (with-current-buffer buf
      (k8s-xray-mode)
      (setq k8s-xray--ns ns
            k8s-xray--kind kind
            k8s-xray--obj obj)
      (k8s-xray--refresh-with (k8s--ensure-connection) ns kind obj))
    (pop-to-buffer buf)))

;;;###autoload
(defun k8s-xray-at-point ()
  "Bound to `T' on a workload row — open its xray."
  (interactive)
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (val (and sec (oref sec value)))
         (kind (pcase type
                 ('deployment "Deployment")
                 ('statefulset "StatefulSet")
                 ('daemonset "DaemonSet")
                 ('job "Job")
                 ('cronjob "CronJob")
                 ('replicaset "ReplicaSet")
                 ('service "Service")
                 ('pod "Pod"))))
    (unless kind
      (user-error
       "k8s-xray: not on a workload row (got section type %S)" type))
    (k8s-xray kind (k8s--resource-namespace val) val)))

(provide 'k8s-xray)
;;; k8s-xray.el ends here
