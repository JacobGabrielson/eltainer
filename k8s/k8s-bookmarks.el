;;; k8s-bookmarks.el --- Bookmark + jump cluster resources -*- lexical-binding: t -*-
;;
;; Wires every k8s resource row into Emacs's built-in `bookmark.el',
;; so `M-x bookmark-set' (typically `C-x r m') saves a cross-cluster
;; pointer to "this pod" / "this service" / etc.  `bookmark-jump'
;; later re-opens the right view and scrolls to the row.
;;
;; Each bookmark carries:
;;   :backend k8s
;;   :context  (cluster name from kubeconfig)
;;   :kind     (e.g. pod, deployment)
;;   :ns       (namespace, or nil for cluster-scoped)
;;   :name     (resource name)
;;
;; When jumping, we switch kubeconfig context if it doesn't match
;; the bookmark, open the right view, and scroll to the matching
;; row.  Cross-cluster works because every K8s view uses
;; `k8s-context-override' as the source of truth.

(require 'cl-lib)
(require 'bookmark)
(require 'magit-section)
(require 'k8s-api)
(require 'k8s-config)

;; Avoid `(require 'k8s)' (that would cycle on `eltainer-reload').
;; Variables / commands referenced lazily at runtime:
(defvar k8s-context-override)
(defvar k8s-kubeconfig-path)
(defvar k8s--namespace)
(declare-function k8s-pods                       "k8s-pods")
(declare-function k8s-deployments                "k8s")
(declare-function k8s-statefulsets               "k8s")
(declare-function k8s-daemonsets                 "k8s")
(declare-function k8s-jobs                       "k8s")
(declare-function k8s-cronjobs                   "k8s")
(declare-function k8s-services                   "k8s")
(declare-function k8s-ingresses                  "k8s")
(declare-function k8s-configmaps                 "k8s")
(declare-function k8s-secrets                    "k8s")
(declare-function k8s-nodes                      "k8s")
(declare-function k8s-sandboxes                  "k8s")
(declare-function k8s-horizontalpodautoscalers   "k8s")
(declare-function k8s-poddisruptionbudgets       "k8s")
(declare-function k8s-persistentvolumes          "k8s")
(declare-function k8s-persistentvolumeclaims     "k8s")
(declare-function k8s-storageclasses             "k8s")
(declare-function k8s-networkpolicies            "k8s")
(declare-function k8s-helm                       "k8s-helm")
(declare-function eltainer--apply-context-switch "eltainer")

(defgroup k8s-bookmarks nil
  "Emacs-bookmark integration for K8s resources."
  :group 'k8s
  :prefix "k8s-bookmarks-")

;;; ---------------------------------------------------------------------------
;;; Section -> bookmark record

(defconst k8s-bookmarks--kind-to-cmd
  '((pod         . k8s-pods)
    (deployment  . k8s-deployments)
    (statefulset . k8s-statefulsets)
    (daemonset   . k8s-daemonsets)
    (job         . k8s-jobs)
    (cronjob     . k8s-cronjobs)
    (service     . k8s-services)
    (ingress     . k8s-ingresses)
    (configmap   . k8s-configmaps)
    (secret      . k8s-secrets)
    (node        . k8s-nodes)
    (sandbox     . k8s-sandboxes)
    (horizontalpodautoscaler . k8s-horizontalpodautoscalers)
    (poddisruptionbudget . k8s-poddisruptionbudgets)
    (persistentvolume . k8s-persistentvolumes)
    (persistentvolumeclaim . k8s-persistentvolumeclaims)
    (storageclass . k8s-storageclasses)
    (networkpolicy . k8s-networkpolicies)
    (helm-release . k8s-helm))
  "Map a section type symbol to the entry-point command for its view.")

(defun k8s-bookmarks--current-context ()
  "Return the active context name, or nil."
  (or k8s-context-override
      (let ((path (or k8s-kubeconfig-path
                      (and (file-readable-p (expand-file-name "~/.kube/config"))
                           (expand-file-name "~/.kube/config")))))
        (and path
             (condition-case nil
                 (k8s-config-current-context (k8s-config-load path))
               (error nil))))))

(defun k8s-bookmarks--current-kubeconfig ()
  "Return the kubeconfig file path the active context lives in, or nil."
  (or k8s-kubeconfig-path
      (let ((env (getenv "KUBECONFIG")))
        (and env (car (split-string env ":" t))))
      (let ((default (expand-file-name "~/.kube/config")))
        (and (file-readable-p default) default))))

(defun k8s-bookmarks-make-record ()
  "`bookmark-make-record-function' for k8s view buffers.
Pulls the resource info from the magit-section at point."
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (val (and sec (oref sec value)))
         (cmd (cdr (assq type k8s-bookmarks--kind-to-cmd))))
    (unless (and val (listp val) (assq 'metadata val) cmd)
      (user-error
       "k8s-bookmarks: nothing bookmarkable at point (section type %S)"
       type))
    (let* ((meta (cdr (assq 'metadata val)))
           (name (cdr (assq 'name meta)))
           (ns (cdr (assq 'namespace meta)))
           (ctx (k8s-bookmarks--current-context))
           (kcfg (k8s-bookmarks--current-kubeconfig))
           (display
            (format "k8s:%s/%s%s [%s]"
                    (symbol-name type)
                    (if ns (format "%s/" ns) "")
                    name
                    (or ctx "?"))))
      `(,display
        (handler . k8s-bookmarks-jump)
        (k8s-backend . k8s)
        (k8s-kind . ,type)
        (k8s-ns . ,ns)
        (k8s-name . ,name)
        (k8s-context . ,ctx)
        (k8s-kubeconfig . ,kcfg)))))

;;; ---------------------------------------------------------------------------
;;; Jumping

(defun k8s-bookmarks--switch-context-if-needed (kcfg ctx)
  "Apply (KCFG, CTX) before opening the view, if they don't already match."
  (when (and ctx
             (not (equal ctx (k8s-bookmarks--current-context))))
    ;; `eltainer--apply-context-switch' (in eltainer.el) does the
    ;; right thing: sets the vars, kills active k8s buffers (we
    ;; don't want stale state), refreshes the dashboard.
    (require 'eltainer)
    (eltainer--apply-context-switch kcfg ctx)))

(defun k8s-bookmarks--scroll-to-name (name ns)
  "Search the current buffer for a row matching NAME (and NS if set)."
  (goto-char (point-min))
  (cond
   ;; Namespaced: try `NS/NAME' first, then bare NAME.
   ((and ns
         (re-search-forward
          (format "^  %s\\b" (regexp-quote (format "%s/%s" ns name)))
          nil t))
    (beginning-of-line))
   ((re-search-forward (format "^  %s\\b" (regexp-quote name)) nil t)
    (beginning-of-line))
   (t
    (message "k8s-bookmarks: %s%s not found in view"
             (if ns (format "%s/" ns) "") name))))

;;;###autoload
(defun k8s-bookmarks-jump (bm)
  "Follow a `k8s-bookmarks'-made record BM."
  (let* ((rec (bookmark-get-bookmark-record bm))
         (kind (alist-get 'k8s-kind rec))
         (ns (alist-get 'k8s-ns rec))
         (name (alist-get 'k8s-name rec))
         (ctx (alist-get 'k8s-context rec))
         (kcfg (alist-get 'k8s-kubeconfig rec))
         (cmd (cdr (assq kind k8s-bookmarks--kind-to-cmd))))
    (unless cmd
      (user-error "k8s-bookmarks: unknown kind %S in bookmark" kind))
    (k8s-bookmarks--switch-context-if-needed kcfg ctx)
    ;; Open the right view.  Each `cmd' is the autoloaded view-open
    ;; function (k8s-pods, k8s-services, etc.) -- they pop the
    ;; buffer.
    (funcall cmd)
    ;; Set the namespace filter on the view if the bookmarked
    ;; resource lives in one and the view supports it.
    (when (and ns
               (boundp 'k8s--namespace)
               (not (equal ns k8s--namespace)))
      (setq-local k8s--namespace ns)
      (revert-buffer nil t))
    (k8s-bookmarks--scroll-to-name name ns)))

;;; ---------------------------------------------------------------------------
;;; Mode-hook wiring

(defun k8s-bookmarks--install-handler ()
  "Install the buffer-local `bookmark-make-record-function'."
  (setq-local bookmark-make-record-function #'k8s-bookmarks-make-record))

;; Wire into every K8s view mode.  We can't reference each mode by
;; name without `require'-ing every file, so install on the parent
;; (magit-section-mode) hook with a runtime check.
(defun k8s-bookmarks--maybe-install ()
  (when (and (derived-mode-p 'magit-section-mode)
             (buffer-name)
             (string-prefix-p "*k8s:" (buffer-name)))
    (k8s-bookmarks--install-handler)))

(add-hook 'magit-section-mode-hook #'k8s-bookmarks--maybe-install)

(provide 'k8s-bookmarks)
;;; k8s-bookmarks.el ends here
