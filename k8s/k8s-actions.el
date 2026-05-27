;;; k8s-actions.el --- Write-side actions on existing resource views -*- lexical-binding: t -*-
;;
;; A small catalogue of common write-side actions that mainstream K8s
;; UIs offer, wired into eltainer's existing view bindings:
;;
;;   `S'   scale Deployment / StatefulSet / ReplicaSet
;;   `R'   rollout-restart Deployment / StatefulSet / DaemonSet
;;   `K'   force-kill the Pod at point (controller recreates)
;;   `c'   toggle cordon on the Node at point
;;   `D'   drain the Node at point  (cordon + evict every pod)
;;   `C-u l' / `C-u L'  show *previous* container logs (after a crash)
;;
;; Each action does one (or, for drain, a small fan of) API call(s)
;; using existing eltainer-style primitives.  PATCH bodies use the
;; built-in `application/strategic-merge-patch+json' content type
;; (built-in resources expect that; for CRDs there is no scale or
;; rollout-restart shape anyway).

(require 'cl-lib)
(require 'json)
(require 'docker-http)
(require 'k8s-api)
(require 'k8s-marks)
(require 'k8s)

(defgroup k8s-actions nil
  "Write-side actions for the standard resource views."
  :group 'k8s
  :prefix "k8s-")

;;; ---------------------------------------------------------------------------
;;; PATCH helper

(defun k8s-actions--patch-strategic (conn path body)
  "Send PATCH BODY (a JSON string) to PATH with strategic-merge.
Returns the response struct.  Caller checks status."
  (let ((cfg (k8s-connection-docker-cfg conn)))
    (docker-http-request
     cfg "PATCH" path
     :headers
     '(("Content-Type" . "application/strategic-merge-patch+json"))
     :body body)))

(defun k8s-actions--require-ok (resp action)
  "Signal a clean user-error when RESP isn't 2xx (ACTION is for the msg)."
  (unless (docker-http-ok-p resp)
    (user-error "k8s-actions: %s failed (HTTP %d): %s"
                action
                (docker-http-response-status resp)
                (or (docker-http-response-body resp) ""))))

;;; ---------------------------------------------------------------------------
;;; Section-at-point dispatch

(defun k8s-actions--workload-at-point (allowed-kinds)
  "Return (KIND OBJ NS NAME PATH) for the workload at point.
Errors out unless the section type is in ALLOWED-KINDS."
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (obj (and sec (oref sec value))))
    (unless (and obj (listp obj) (assq 'metadata obj)
                 (memq type allowed-kinds))
      (user-error "k8s-actions: not on one of %S (got %S)"
                  allowed-kinds type))
    (let* ((ns (k8s--resource-namespace obj))
           (name (k8s--resource-name obj))
           (tpl (cdr (assq type k8s--resource-api-paths)))
           (path (and tpl ns name (format tpl ns name))))
      (unless path
        (user-error "k8s-actions: no API-path template for %S" type))
      (list type obj ns name path))))

;;; ---------------------------------------------------------------------------
;;; Scale  (S)

;;;###autoload
(defun k8s-scale-at-point (&optional new-replicas)
  "Scale the workload at point.  Prompts for the new replica count
unless NEW-REPLICAS is supplied (a numeric prefix arg works).

Sends a strategic-merge PATCH of `{\"spec\":{\"replicas\":N}}'.
Refuses on resources that don't have a `replicas' shape."
  (interactive "P")
  (pcase-let* ((`(,_kind ,obj ,ns ,name ,path)
                (k8s-actions--workload-at-point
                 '(deployment statefulset replicaset))))
    (let* ((current (or (cdr (assq 'replicas (cdr (assq 'spec obj)))) 0))
           (n (cond ((numberp new-replicas) new-replicas)
                    (t (read-number
                        (format "Scale %s/%s replicas (now %d) to: "
                                ns name current)
                        current)))))
      (when (or (numberp new-replicas)
                (yes-or-no-p
                 (format "Scale %s/%s from %d -> %d? " ns name current n)))
        (let* ((conn (k8s--ensure-connection))
               (body (json-encode `(("spec" . (("replicas" . ,n))))))
               (resp (k8s-actions--patch-strategic conn path body)))
          (k8s-actions--require-ok resp (format "scale %s/%s" ns name))
          (message "k8s-actions: scaled %s/%s -> %d" ns name n)
          (revert-buffer nil t))))))

;;; ---------------------------------------------------------------------------
;;; Rollout restart  (R)

;;;###autoload
(defun k8s-rollout-restart-at-point ()
  "Rollout-restart the workload at point.

Patches `spec.template.metadata.annotations.kubectl.kubernetes.io/
restartedAt' to the current time — exactly what `kubectl rollout
restart' does.  The Deployment controller notices the template
change and rolls a new ReplicaSet."
  (interactive)
  (pcase-let* ((`(,_kind ,_obj ,ns ,name ,path)
                (k8s-actions--workload-at-point
                 '(deployment statefulset daemonset))))
    (when (yes-or-no-p
           (format "Rollout-restart %s/%s? " ns name))
      (let* ((conn (k8s--ensure-connection))
             (now (format-time-string "%Y-%m-%dT%H:%M:%SZ" (current-time) t))
             (body
              (json-encode
               `(("spec"
                  . (("template"
                      . (("metadata"
                          . (("annotations"
                              . (("kubectl.kubernetes.io/restartedAt"
                                  . ,now)))))))))))))
        (k8s-actions--require-ok
         (k8s-actions--patch-strategic conn path body)
         (format "rollout-restart %s/%s" ns name))
        (message "k8s-actions: restarted %s/%s at %s" ns name now)
        (revert-buffer nil t)))))

;;; ---------------------------------------------------------------------------
;;; Force-kill pod  (K)

;;;###autoload
(defun k8s-force-kill-pod-at-point ()
  "Delete the Pod at point.  The controller (Deployment / STS /
DaemonSet / Job) will recreate it; for orphan pods this just
removes them.  Distinct from `d' (delete) which is the
\"remove this resource\" semantic across all views."
  (interactive)
  (pcase-let* ((`(,_kind ,_obj ,ns ,name ,path)
                (k8s-actions--workload-at-point '(pod))))
    (when (yes-or-no-p
           (format "Force-kill pod %s/%s (controller will recreate)? "
                   ns name))
      (let ((conn (k8s--ensure-connection)))
        (k8s-delete conn path)
        (message "k8s-actions: killed pod %s/%s" ns name)
        (revert-buffer nil t)))))

;;; ---------------------------------------------------------------------------
;;; Node actions: cordon / uncordon / drain

(defun k8s-actions--node-at-point ()
  "Return (NAME OBJ PATH) for the Node section at point, or signal."
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (obj (and sec (oref sec value))))
    (unless (and obj (memq type '(node)))
      (user-error "k8s-actions: not on a Node row"))
    (let ((name (k8s--resource-name obj)))
      (list name obj (format "/api/v1/nodes/%s" name)))))

(defun k8s-actions--node-unschedulable-p (node)
  (eq (cdr (assq 'unschedulable (cdr (assq 'spec node)))) t))

;;;###autoload
(defun k8s-cordon-toggle-at-point ()
  "Toggle the cordon state of the Node at point.
PATCHes `.spec.unschedulable' to its inverse."
  (interactive)
  (pcase-let* ((`(,name ,obj ,path) (k8s-actions--node-at-point))
               (was (k8s-actions--node-unschedulable-p obj))
               (verb (if was "Uncordon" "Cordon")))
    (when (yes-or-no-p (format "%s %s? " verb name))
      (let* ((conn (k8s--ensure-connection))
             ;; json-encode writes `:false' as the string "false";
             ;; the json.el-compatible boolean symbols are `t' and
             ;; `:json-false'.  Get the wire form right or the API
             ;; rejects with 422.
             (body (json-encode
                    `(("spec" . (("unschedulable"
                                  . ,(if was :json-false t))))))))
        (k8s-actions--require-ok
         (k8s-actions--patch-strategic conn path body)
         (format "%s %s" verb name))
        (message "k8s-actions: %sed %s"
                 (downcase verb) name)
        (revert-buffer nil t)))))

(defun k8s-actions--pods-on-node (conn node-name)
  "List pods scheduled onto NODE-NAME (cluster-wide)."
  (append
   (cdr (assq 'items
              (k8s-get
               conn
               (format "/api/v1/pods?fieldSelector=%s"
                       (url-hexify-string
                        (format "spec.nodeName=%s" node-name))))))
   nil))

(defun k8s-actions--evict (conn ns name)
  "POST a single-pod eviction.  Returns the response struct so the
caller can decide whether to retry (PDB-blocked) or move on."
  (let* ((cfg (k8s-connection-docker-cfg conn))
         (path (format "/api/v1/namespaces/%s/pods/%s/eviction" ns name))
         (body
          (json-encode
           `(("apiVersion" . "policy/v1")
             ("kind" . "Eviction")
             ("metadata" . (("name" . ,name) ("namespace" . ,ns)))))))
    (docker-http-request
     cfg "POST" path
     :headers '(("Content-Type" . "application/json"))
     :body body)))

;;;###autoload
(defun k8s-drain-at-point ()
  "Drain the Node at point: cordon it, then evict every pod on it
that isn't a DaemonSet pod or a mirror pod.
Best-effort; reports per-pod success / failure.  No `--force' yet."
  (interactive)
  (pcase-let* ((`(,name ,_obj ,path) (k8s-actions--node-at-point)))
    (unless (yes-or-no-p
             (format "Drain node %s? \
Cordons it + evicts every non-DaemonSet pod scheduled there. "
                     name))
      (user-error "Aborted"))
    (let* ((conn (k8s--ensure-connection))
           (pods (k8s-actions--pods-on-node conn name))
           (kept 0) (evicted 0) (failed 0))
      (k8s-actions--require-ok
       (k8s-actions--patch-strategic
        conn path (json-encode '(("spec" . (("unschedulable" . t))))))
       (format "cordon %s" name))
      (dolist (pod pods)
        (let* ((meta (cdr (assq 'metadata pod)))
               (ns (cdr (assq 'namespace meta)))
               (pname (cdr (assq 'name meta)))
               (owners (append
                        (or (cdr (assq 'ownerReferences meta)) [])
                        nil))
               (is-ds (cl-some (lambda (o)
                                 (equal "DaemonSet"
                                        (cdr (assq 'kind o))))
                               owners))
               (is-mirror (cdr (assq 'kubernetes.io/config.mirror
                                     (cdr (assq 'annotations meta))))))
          (cond
           ((or is-ds is-mirror) (cl-incf kept))
           (t
            (let ((resp (k8s-actions--evict conn ns pname)))
              (cond ((docker-http-ok-p resp) (cl-incf evicted))
                    (t (cl-incf failed)
                       (message "k8s-actions: evict %s/%s failed (%d)"
                                ns pname
                                (docker-http-response-status resp)))))))))
      (message
       "k8s-actions: drain %s — cordoned, %d evicted, %d kept (DS/mirror), %d failed"
       name evicted kept failed)
      (revert-buffer nil t))))

;;; ---------------------------------------------------------------------------
;;; Previous-container logs (C-u l)
;;
;; The `?previous=true' query on the logs endpoint pulls from the
;; container's PREVIOUS run -- useful immediately after a crash.
;; Plumbed by `k8s--log-previous' (defvar-local) which the existing
;; log-stream code now consults at start.

(defvar-local k8s--log-previous nil
  "When non-nil, the per-pod log stream pulls `?previous=true'.
Toggled by passing a prefix arg to `k8s-pod-view-logs' (`C-u l').")

(provide 'k8s-actions)
;;; k8s-actions.el ends here
