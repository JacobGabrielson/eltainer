;;; k8s-scan.el --- Cluster sanity scan -*- lexical-binding: t -*-
;;
;; `M-x k8s-scan' walks the cluster and runs a set of static checks
;; against every Pod / workload / Service / Node / Ingress / PVC /
;; ClusterRoleBinding, then renders the findings (grouped by severity)
;; in `*k8s:scan*'.  RET on a finding jumps to the offending resource
;; via the existing `k8s-jump-target' mechanism.
;;
;; The shape (read-only, severity-tagged findings, cluster-hygiene
;; score, magit-section grouping) is the popeye-shaped one outlined
;; in `docs/feature-ideas.md'.  Linters are pure functions over the
;; decoded resource alist — easy to add new arms incrementally.
;;
;; No CLI shell-out; everything goes through the existing
;; `k8s-list-*' / `k8s-get' primitives.

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'k8s-api)
(require 'k8s-marks)
(require 'k8s)

(defgroup k8s-scan nil
  "Cluster sanity scanner."
  :group 'k8s
  :prefix "k8s-scan-")

(defcustom k8s-scan-pod-restarts-warn 5
  "Pod with a container at restartCount > this triggers a warning."
  :type 'integer :group 'k8s-scan)

;;; ---------------------------------------------------------------------------
;;; Finding struct + severity

(cl-defstruct (k8s-scan-finding
               (:constructor k8s-scan-finding--new)
               (:copier nil))
  severity      ; 'error / 'warning / 'info
  rule          ; short symbol/string, e.g. `pod-no-liveness'
  kind          ; section-type symbol for k8s-jump-target (pod / deployment / …)
  ns            ; namespace (nil for cluster-scoped)
  name          ; resource name
  message)      ; one-line rationale

(defun k8s-scan-finding (severity rule kind ns name message)
  "Convenience constructor."
  (k8s-scan-finding--new
   :severity severity :rule rule :kind kind
   :ns ns :name name :message message))

(defconst k8s-scan--severity-faces
  '((error   . eltainer-status-error)
    (warning . eltainer-status-warn)
    (info    . eltainer-dim))
  "Faces per severity for the report buffer.")

(defun k8s-scan--severity-weight (sev)
  (pcase sev (`error 5) (`warning 2) (`info 0) (_ 0)))

(defun k8s-scan--score (findings)
  "Return an integer 0..100 cluster-hygiene score."
  (let ((penalty (cl-loop for f in findings
                          sum (k8s-scan--severity-weight
                               (k8s-scan-finding-severity f)))))
    (max 0 (- 100 penalty))))

;;; ---------------------------------------------------------------------------
;;; Linters
;;
;; Each linter takes one decoded resource alist and returns a list of
;; findings (possibly empty).  The set is fixed at v1; users can add
;; their own by extending the per-kind registries below.

(defun k8s-scan--meta (obj key)
  (cdr (assq key (cdr (assq 'metadata obj)))))

(defun k8s-scan--name (obj) (k8s-scan--meta obj 'name))
(defun k8s-scan--ns   (obj) (k8s-scan--meta obj 'namespace))

(defun k8s-scan--containers (pod)
  (append (or (cdr (assq 'containers (cdr (assq 'spec pod)))) []) nil))

(defun k8s-scan--init-containers (pod)
  (append (or (cdr (assq 'initContainers (cdr (assq 'spec pod)))) []) nil))

;;; --- Pod linters ---

(defun k8s-scan/pod-no-resources (pod)
  "Pod whose containers don't set resources.limits."
  (cl-loop for c in (k8s-scan--containers pod)
           for cname = (cdr (assq 'name c))
           for limits = (cdr (assq 'limits (cdr (assq 'resources c))))
           unless limits
           collect
           (k8s-scan-finding
            'warning 'pod-no-resources 'pod
            (k8s-scan--ns pod) (k8s-scan--name pod)
            (format "container %s has no resources.limits" cname))))

(defun k8s-scan/pod-no-liveness (pod)
  (cl-loop for c in (k8s-scan--containers pod)
           for cname = (cdr (assq 'name c))
           unless (cdr (assq 'livenessProbe c))
           collect
           (k8s-scan-finding
            'warning 'pod-no-liveness 'pod
            (k8s-scan--ns pod) (k8s-scan--name pod)
            (format "container %s has no livenessProbe" cname))))

(defun k8s-scan/pod-no-readiness (pod)
  (cl-loop for c in (k8s-scan--containers pod)
           for cname = (cdr (assq 'name c))
           unless (cdr (assq 'readinessProbe c))
           collect
           (k8s-scan-finding
            'info 'pod-no-readiness 'pod
            (k8s-scan--ns pod) (k8s-scan--name pod)
            (format "container %s has no readinessProbe" cname))))

(defun k8s-scan/pod-latest-tag (pod)
  "Image uses `:latest' or no tag at all."
  (cl-loop for c in (k8s-scan--containers pod)
           for cname = (cdr (assq 'name c))
           for image = (cdr (assq 'image c))
           when (or (null image)
                    (string-suffix-p ":latest" image)
                    (not (string-match-p ":" (or image ""))))
           collect
           (k8s-scan-finding
            'warning 'pod-latest-tag 'pod
            (k8s-scan--ns pod) (k8s-scan--name pod)
            (format "container %s uses an unpinned tag (%s)"
                    cname (or image "?")))))

(defun k8s-scan/pod-run-as-root (pod)
  "Pod doesn't explicitly run as non-root."
  (let* ((spec (cdr (assq 'spec pod)))
         (sec  (cdr (assq 'securityContext spec)))
         (run-non-root (cdr (assq 'runAsNonRoot sec)))
         (user (cdr (assq 'runAsUser sec))))
    (unless (or (eq run-non-root t)
                (and (numberp user) (> user 0)))
      (list (k8s-scan-finding
             'info 'pod-run-as-root 'pod
             (k8s-scan--ns pod) (k8s-scan--name pod)
             "no securityContext.runAsNonRoot=true / runAsUser>0")))))

(defun k8s-scan/pod-restarts-high (pod)
  (let* ((statuses (append
                    (or (cdr (assq 'containerStatuses (cdr (assq 'status pod))))
                        [])
                    nil)))
    (cl-loop for cs in statuses
             for restarts = (or (cdr (assq 'restartCount cs)) 0)
             when (> restarts k8s-scan-pod-restarts-warn)
             collect
             (k8s-scan-finding
              'warning 'pod-restarts-high 'pod
              (k8s-scan--ns pod) (k8s-scan--name pod)
              (format "container %s has restarted %d times"
                      (cdr (assq 'name cs)) restarts)))))

(defun k8s-scan/pod-pending-too-long (pod)
  (let* ((phase (cdr (assq 'phase (cdr (assq 'status pod)))))
         (start-time (cdr (assq 'startTime (cdr (assq 'status pod)))))
         (age (and start-time
                   (- (float-time)
                      (float-time (date-to-time start-time))))))
    (when (and (equal phase "Pending") age (> age 300)) ; > 5m
      (list (k8s-scan-finding
             'error 'pod-pending-too-long 'pod
             (k8s-scan--ns pod) (k8s-scan--name pod)
             (format "Pending for %d minutes" (truncate (/ age 60))))))))

(defconst k8s-scan--pod-rules
  '(k8s-scan/pod-no-resources
    k8s-scan/pod-no-liveness
    k8s-scan/pod-no-readiness
    k8s-scan/pod-latest-tag
    k8s-scan/pod-run-as-root
    k8s-scan/pod-restarts-high
    k8s-scan/pod-pending-too-long))

;;; --- Workload linters ---

(defun k8s-scan/workload-zero-replicas (wl kind)
  (let ((r (cdr (assq 'replicas (cdr (assq 'spec wl))))))
    (when (and (numberp r) (zerop r))
      (list (k8s-scan-finding
             'info 'workload-zero-replicas kind
             (k8s-scan--ns wl) (k8s-scan--name wl)
             "spec.replicas = 0")))))

(defun k8s-scan/workload-bad-selector (wl kind)
  "Selector that matches nothing (with the workload's own labels)
flags a finding.  Cheap: we only compare matchLabels to
spec.template.metadata.labels."
  (let* ((spec (cdr (assq 'spec wl)))
         (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec)))))
         (tmpl-labels (cdr (assq 'labels
                                  (cdr (assq 'metadata
                                             (cdr (assq 'template spec))))))))
    (when (and selector tmpl-labels)
      (let ((mismatch
             (cl-some (lambda (kv)
                        (let ((k (car kv)) (v (cdr kv)))
                          (not (equal v (cdr (assq k tmpl-labels))))))
                      selector)))
        (when mismatch
          (list (k8s-scan-finding
                 'error 'workload-bad-selector kind
                 (k8s-scan--ns wl) (k8s-scan--name wl)
                 "spec.selector.matchLabels doesn't match \
spec.template.metadata.labels")))))))

(defun k8s-scan--deployments-linters (wl) (k8s-scan--workload-linters wl 'deployment))
(defun k8s-scan--statefulsets-linters (wl) (k8s-scan--workload-linters wl 'statefulset))
(defun k8s-scan--daemonsets-linters (wl) (k8s-scan--workload-linters wl 'daemonset))

(defun k8s-scan--workload-linters (wl kind)
  (append
   (k8s-scan/workload-zero-replicas wl kind)
   (k8s-scan/workload-bad-selector wl kind)))

;;; --- Service linters ---

(defun k8s-scan/service-no-selector (svc)
  (let* ((spec (cdr (assq 'spec svc)))
         (sel (cdr (assq 'selector spec)))
         (type (cdr (assq 'type spec))))
    (unless (or sel (equal type "ExternalName"))
      (list (k8s-scan-finding
             'warning 'service-no-selector 'service
             (k8s-scan--ns svc) (k8s-scan--name svc)
             "Service has no `.spec.selector' and isn't ExternalName")))))

(defun k8s-scan/service-port-unnamed (svc)
  (let ((ports (append (or (cdr (assq 'ports (cdr (assq 'spec svc)))) []) nil)))
    (when (and (> (length ports) 1)
               (cl-some (lambda (p) (null (cdr (assq 'name p)))) ports))
      (list (k8s-scan-finding
             'info 'service-port-unnamed 'service
             (k8s-scan--ns svc) (k8s-scan--name svc)
             "multiple ports defined but at least one has no name")))))

;;; --- Node linters ---

(defun k8s-scan/node-not-ready (node)
  (let* ((conds (append (or (cdr (assq 'conditions
                                        (cdr (assq 'status node))))
                            [])
                        nil))
         (ready (cl-find-if (lambda (c) (equal "Ready" (cdr (assq 'type c)))) conds)))
    (when (and ready (not (equal "True" (cdr (assq 'status ready)))))
      (list (k8s-scan-finding
             'error 'node-not-ready 'node
             nil (k8s-scan--name node)
             (format "Node Ready=%s"
                     (or (cdr (assq 'status ready)) "Unknown")))))))

(defun k8s-scan/node-pressure (node)
  (let ((conds (append (or (cdr (assq 'conditions (cdr (assq 'status node)))) [])
                       nil)))
    (cl-loop for c in conds
             for type = (cdr (assq 'type c))
             when (and (member type '("MemoryPressure" "DiskPressure" "PIDPressure"))
                       (equal "True" (cdr (assq 'status c))))
             collect
             (k8s-scan-finding
              'warning 'node-pressure 'node
              nil (k8s-scan--name node)
              (format "%s = True" type)))))

;;; --- Ingress linters ---

(defun k8s-scan/ingress-no-host (ing)
  (let ((rules (append (or (cdr (assq 'rules (cdr (assq 'spec ing)))) []) nil)))
    (cl-loop for r in rules
             unless (cdr (assq 'host r))
             collect
             (k8s-scan-finding
              'info 'ingress-no-host 'ingress
              (k8s-scan--ns ing) (k8s-scan--name ing)
              "ingress rule has no host (catch-all)"))))

;;; --- PVC linters ---

(defun k8s-scan/pvc-not-bound (pvc)
  (let ((phase (cdr (assq 'phase (cdr (assq 'status pvc))))))
    (unless (equal phase "Bound")
      (list (k8s-scan-finding
             'warning 'pvc-not-bound 'persistentvolumeclaim
             (k8s-scan--ns pvc) (k8s-scan--name pvc)
             (format "PVC phase = %s" (or phase "?")))))))

;;; --- ClusterRoleBinding linters ---

(defun k8s-scan/crb-cluster-admin (crb)
  "ClusterRoleBinding binds `cluster-admin' to non-system subjects."
  (let* ((roleref (cdr (assq 'roleRef crb)))
         (role-name (cdr (assq 'name roleref)))
         (subjects (append (or (cdr (assq 'subjects crb)) []) nil)))
    (when (equal role-name "cluster-admin")
      (cl-loop for s in subjects
               for kind = (cdr (assq 'kind s))
               for name = (cdr (assq 'name s))
               for ns = (cdr (assq 'namespace s))
               unless (or (and (equal kind "Group")
                               (string-prefix-p "system:" (or name "")))
                          (and (equal kind "User")
                               (string-prefix-p "system:" (or name "")))
                          ;; system:* SA namespaces are also boring
                          (equal ns "kube-system"))
               collect
               (k8s-scan-finding
                'warning 'crb-cluster-admin 'clusterrolebinding
                nil (k8s-scan--name crb)
                (format "binds cluster-admin to %s/%s%s"
                        kind name (if ns (format " (ns %s)" ns) "")))))))

;;; ---------------------------------------------------------------------------
;;; Scan engine

(defun k8s-scan--apply-rules (resources rules)
  "Run each RULES function over each item in RESOURCES; flatten."
  (let (out)
    (seq-doseq (r resources)
      (dolist (rule rules)
        (let ((findings (funcall rule r)))
          (dolist (f findings) (push f out)))))
    out))

(defun k8s-scan--apply-rule-with-kind (resources rule kind)
  (let (out)
    (seq-doseq (r resources)
      (let ((findings (funcall rule r kind)))
        (dolist (f findings) (push f out))))
    out))

(defun k8s-scan-collect (conn)
  "Walk the cluster via CONN, run every linter, return a flat list."
  (let (findings)
    ;; Pods
    (let ((pods (or (k8s-list-pods conn) [])))
      (setq findings
            (append (k8s-scan--apply-rules pods k8s-scan--pod-rules)
                    findings)))
    ;; Deployments / STS / DS — workload-shaped
    (dolist (entry `((,#'k8s-list-deployments  . deployment)
                     (,#'k8s-list-statefulsets . statefulset)
                     (,#'k8s-list-daemonsets   . daemonset)))
      (let* ((items (condition-case nil
                        (funcall (car entry) conn)
                      (error nil)))
             (kind (cdr entry)))
        (setq findings
              (append (k8s-scan--apply-rule-with-kind
                        items #'k8s-scan--workload-linters kind)
                      findings))))
    ;; Services
    (let ((svcs (condition-case nil (k8s-list-services conn) (error nil))))
      (setq findings
            (append (k8s-scan--apply-rules
                      svcs '(k8s-scan/service-no-selector
                             k8s-scan/service-port-unnamed))
                    findings)))
    ;; Nodes
    (let ((nodes (condition-case nil (k8s-list-nodes conn) (error nil))))
      (setq findings
            (append (k8s-scan--apply-rules
                      nodes '(k8s-scan/node-not-ready
                              k8s-scan/node-pressure))
                    findings)))
    ;; Ingresses
    (let ((ings (condition-case nil (k8s-list-ingresses conn) (error nil))))
      (setq findings
            (append (k8s-scan--apply-rules
                      ings '(k8s-scan/ingress-no-host))
                    findings)))
    ;; PVCs
    (let ((pvcs (condition-case nil (k8s-list-pvcs conn) (error nil))))
      (setq findings
            (append (k8s-scan--apply-rules
                      pvcs '(k8s-scan/pvc-not-bound))
                    findings)))
    ;; ClusterRoleBindings
    (let ((crbs (condition-case nil (k8s-list-clusterrolebindings conn) (error nil))))
      (setq findings
            (append (k8s-scan--apply-rules
                      crbs '(k8s-scan/crb-cluster-admin))
                    findings)))
    findings))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun k8s-scan--severity-order (sev)
  (pcase sev (`error 0) (`warning 1) (`info 2) (_ 3)))

(defun k8s-scan--group-by-severity (findings)
  "Partition FINDINGS by severity; return alist `(SEV . LIST)' in fixed order."
  (let ((errs nil) (warns nil) (infs nil))
    (dolist (f findings)
      (pcase (k8s-scan-finding-severity f)
        (`error   (push f errs))
        (`warning (push f warns))
        (`info    (push f infs))))
    `((error . ,(nreverse errs))
      (warning . ,(nreverse warns))
      (info . ,(nreverse infs)))))

(defun k8s-scan--jump-target (f)
  "Build a `k8s-jump-target' property value for finding F's resource.
For namespaced resources we use the existing `(service NS NAME)'
shape (which already supports the services view) when the kind is
service; otherwise we use the per-kind name-regex pattern (so any
view-with-name-filter receives F's resource highlighted)."
  (let ((kind (k8s-scan-finding-kind f))
        (ns   (k8s-scan-finding-ns f))
        (name (k8s-scan-finding-name f)))
    ;; Reuse the `helm-resources' shape from k8s-helm: it opens any
    ;; resource view filtered by name-regex.  Pass a single-item list.
    (let ((kind-str (pcase kind
                      ('pod "Pod")
                      ('service "Service")
                      ('deployment "Deployment")
                      ('statefulset "StatefulSet")
                      ('daemonset "DaemonSet")
                      ('ingress "Ingress")
                      ('persistentvolumeclaim "PersistentVolumeClaim")
                      ('node nil)            ; nodes view uses different shape
                      ('clusterrolebinding nil)
                      (_ nil))))
      (and kind-str
           (list 'helm-resources ns kind-str (list name))))))

(defun k8s-scan--insert-finding (f)
  (let* ((sev (k8s-scan-finding-severity f))
         (face (cdr (assq sev k8s-scan--severity-faces)))
         (rule (k8s-scan-finding-rule f))
         (kind (k8s-scan-finding-kind f))
         (ns   (k8s-scan-finding-ns f))
         (name (k8s-scan-finding-name f))
         (msg  (k8s-scan-finding-message f))
         (jump (k8s-scan--jump-target f))
         (sevstr (upcase (symbol-name sev)))
         (header
          (format "  %-7s  %-32s  %-22s  %s\n"
                  (propertize (format "[%s]" (substring sevstr 0 (min 4 (length sevstr))))
                              'font-lock-face face)
                  (propertize (format "%s%s"
                                      (if ns (format "%s/" ns) "")
                                      name)
                              'font-lock-face 'k8s-resource-name)
                  (propertize (format "%s/%s"
                                      (or kind "?")
                                      (or rule "?"))
                              'font-lock-face 'k8s-dim)
                  (propertize msg 'font-lock-face face))))
    (insert
     (if jump
         (propertize header 'k8s-jump-target jump
                     'help-echo (format "RET: open %s view filtered to %s"
                                         kind name))
       header))))

(defun k8s-scan--insert-group (label findings)
  (when findings
    (magit-insert-section (scan-group label)
      (magit-insert-heading
        (propertize (format "%s (%d)\n" label (length findings))
                    'font-lock-face 'eltainer-section-heading))
      (dolist (f findings)
        (k8s-scan--insert-finding f))
      (insert "\n"))))

(defun k8s-scan-render (findings)
  (let* ((inhibit-read-only t)
         (groups (k8s-scan--group-by-severity findings))
         (errs (cdr (assq 'error groups)))
         (warns (cdr (assq 'warning groups)))
         (infs (cdr (assq 'info groups)))
         (score (k8s-scan--score findings)))
    (erase-buffer)
    (magit-insert-section (scan-root)
      (insert (propertize "Cluster scan\n" 'font-lock-face 'eltainer-section-heading))
      (insert (format "  Score: %3d/100   %s\n"
                      score
                      (cond
                       ((>= score 90)
                        (propertize "good" 'font-lock-face 'eltainer-status-running))
                       ((>= score 70)
                        (propertize "okay" 'font-lock-face 'eltainer-status-warn))
                       (t
                        (propertize "needs work" 'font-lock-face 'eltainer-status-error)))))
      (insert (format "  %d error%s, %d warning%s, %d info\n\n"
                      (length errs) (if (= 1 (length errs)) "" "s")
                      (length warns) (if (= 1 (length warns)) "" "s")
                      (length infs)))
      (when (and (null errs) (null warns) (null infs))
        (insert (propertize "  All clear.\n" 'font-lock-face 'eltainer-status-running)))
      (k8s-scan--insert-group "Errors" errs)
      (k8s-scan--insert-group "Warnings" warns)
      (k8s-scan--insert-group "Info" infs))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

(defun k8s-scan-refresh ()
  "Re-collect every linter finding and re-render."
  (interactive)
  (message "k8s-scan: scanning cluster…")
  (let ((conn (k8s--ensure-connection)))
    (k8s-scan-render (k8s-scan-collect conn))
    (message "k8s-scan: done.")))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar k8s-scan-mode-map (make-sparse-keymap))
(set-keymap-parent k8s-scan-mode-map k8s-common-map)
(keymap-set k8s-scan-mode-map "g" #'k8s-scan-refresh)

(define-derived-mode k8s-scan-mode magit-section-mode "K8s:Scan"
  "Read-only cluster sanity report.

\\{k8s-scan-mode-map}"
  :interactive nil
  :group 'k8s-scan
  (setq-local revert-buffer-function (lambda (_a _b) (k8s-scan-refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces)))

;;;###autoload
(defun k8s-scan ()
  "Run the cluster sanity scan and pop its report."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:scan*")))
    (with-current-buffer buf
      (k8s-scan-mode)
      (k8s--ensure-connection)
      (k8s-scan-refresh))
    (pop-to-buffer buf)))

(provide 'k8s-scan)
;;; k8s-scan.el ends here
