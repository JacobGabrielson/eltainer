;;; k8s.el --- Kubernetes UI for Emacs -*- lexical-binding: t -*-
;;
;; Main entry point for the eltainer k8s side.  Provides shared infrastructure
;; (connection, namespace filtering, faces, helpers) and views for
;; all common Kubernetes resource types.
;;
;; Usage:
;;   M-x k8s

(require 'cl-lib)
(require 'magit-section)
(require 'transient)
(require 'eltainer-ui)
(require 'eltainer-gauge)
(require 'eltainer-filter)
(require 'k8s-traffic)
(require 'k8s-config)
(require 'k8s-api)
(require 'k8s-watch)
(require 'k8s-marks)
(require 'k8s-metrics)
(require 'k8s-multilog)
(require 'k8s-prom)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup k8s nil
  "Kubernetes UI for Emacs."
  :prefix "k8s-"
  :group 'tools)

(defcustom k8s-kubeconfig-path nil
  "Path to the kubeconfig file.
If nil, uses $KUBECONFIG or ~/.kube/config."
  :type '(choice (const nil) string)
  :group 'k8s)

;;; ---------------------------------------------------------------------------
;;; Internal state

(defvar-local k8s--connection nil
  "The `k8s-connection' for the current buffer.")

(defvar-local k8s--namespace nil
  "Current namespace filter.  nil means all namespaces.")

(defvar-local k8s--header-end nil
  "Buffer position where the scrollable content begins (after header).")

(defvar-local k8s--watch nil
  "Active `k8s-watch' struct for this buffer, or nil.")

(defvar-local k8s--resource-table nil
  "Hash table (uid -> resource alist) maintained by the watch system.")

(defvar-local k8s--watch-debounce-timer nil
  "Timer for coalescing rapid watch events into a single re-render.")

(defvar-local k8s--api-path-fn nil
  "Function that returns the API list path for this view.
Called with one optional arg (namespace), returns a path string.")

;;; ---------------------------------------------------------------------------
;;; Faces

;; Faces inherit from the shared `eltainer-*' family so theme tweaks
;; happen in one place.

(defface k8s-section-heading '((t :inherit eltainer-section-heading))
  "Face for section headings." :group 'k8s)

(defface k8s-resource-name '((t :inherit eltainer-resource-name))
  "Face for resource names." :group 'k8s)

(defface k8s-namespace '((t :inherit eltainer-resource-secondary))
  "Face for namespace names." :group 'k8s)

(defface k8s-status-running '((t :inherit eltainer-status-running))
  "Face for Running/Active status." :group 'k8s)

(defface k8s-status-pending '((t :inherit eltainer-status-warn))
  "Face for Pending status." :group 'k8s)

(defface k8s-status-failed '((t :inherit eltainer-status-error))
  "Face for Failed status." :group 'k8s)

(defface k8s-status-other '((t :inherit eltainer-status-other))
  "Face for other statuses." :group 'k8s)

(defface k8s-dim '((t :inherit eltainer-dim))
  "Face for secondary information." :group 'k8s)

;;; ---------------------------------------------------------------------------
;;; Connection helpers

(defun k8s--resolve-kubeconfig ()
  "Return the kubeconfig path to use."
  (or k8s-kubeconfig-path
      (getenv "KUBECONFIG")
      (expand-file-name "~/.kube/config")))

(defun k8s--ensure-connection ()
  "Return the current buffer's connection, opening one if needed."
  (or k8s--connection
      (setq k8s--connection
            (k8s-connection-open (k8s--resolve-kubeconfig)))))

;;; ---------------------------------------------------------------------------
;;; Shared helpers

(defun k8s--resource-name (resource)
  "Return metadata.name from RESOURCE alist."
  (cdr (assq 'name (cdr (assq 'metadata resource)))))

(defun k8s--resource-namespace (resource)
  "Return metadata.namespace from RESOURCE alist."
  (cdr (assq 'namespace (cdr (assq 'metadata resource)))))

(defun k8s--resource-creation-time (resource)
  "Return metadata.creationTimestamp from RESOURCE."
  (cdr (assq 'creationTimestamp (cdr (assq 'metadata resource)))))

(defun k8s--resource-uid (resource)
  "Return metadata.uid from RESOURCE — a stable identity across refreshes."
  (cdr (assq 'uid (cdr (assq 'metadata resource)))))

(defun k8s--section-stable-id (value)
  "Return a stable identity (string) for the k8s section VALUE, or nil.
For resource alists, the metadata.uid; for namespace-group sections
the namespace name (a string).  Used so refreshes can put point back
on the same row instead of jumping to the top."
  (cond
   ((null value) nil)
   ((stringp value) (concat "ns:" value))    ; namespace group header
   ((listp value)   (k8s--resource-uid value))))

(defvar-local k8s--expanded-sections nil
  "Buffer-local hash of stable section IDs currently expanded.
Maintained incrementally by advice on `magit-section-show' /
`magit-section-hide' (`k8s--track-section-{shown,hidden}'), so
the per-refresh `k8s--save-point-context' doesn't have to walk
the whole buffer.  Lazily initialized via
`k8s--ensure-expanded-set' — the first call seeds it by walking
the buffer once.")

(defun k8s--ensure-expanded-set ()
  "Return the buffer-local expanded-sections hash; create + seed if needed.
First call walks the buffer once; subsequent calls are O(1)."
  (unless (hash-table-p k8s--expanded-sections)
    (setq k8s--expanded-sections (make-hash-table :test 'equal))
    (save-excursion
      (goto-char (point-min))
      (let (seen)
        (while (not (eobp))
          (let ((sec (get-text-property (point) 'magit-section)))
            (when (and sec (not (memq sec seen))
                       (not (eq (ignore-errors (oref sec hidden)) t)))
              (push sec seen)
              (when-let ((id (k8s--section-stable-id
                              (ignore-errors (oref sec value)))))
                (puthash id t k8s--expanded-sections))))
          (forward-line 1)))))
  k8s--expanded-sections)

(defun k8s--track-section-shown (section &rest _)
  "Advice: record that SECTION is now expanded in the current buffer.
No-op outside eltainer buffers (the hash is buffer-local + nil by
default; checking `hash-table-p' filters them out)."
  (when (and (boundp 'k8s--expanded-sections)
             (hash-table-p k8s--expanded-sections))
    (when-let ((id (k8s--section-stable-id
                    (ignore-errors (oref section value)))))
      (puthash id t k8s--expanded-sections))))

(defun k8s--track-section-hidden (section &rest _)
  "Advice: record that SECTION is now collapsed in the current buffer."
  (when (and (boundp 'k8s--expanded-sections)
             (hash-table-p k8s--expanded-sections))
    (when-let ((id (k8s--section-stable-id
                    (ignore-errors (oref section value)))))
      (remhash id k8s--expanded-sections))))

;; Global advice — fires for every magit-section toggle anywhere, but the
;; buffer-local hash-table-p gate makes it a no-op outside eltainer.
(advice-add 'magit-section-show :after #'k8s--track-section-shown)
(advice-add 'magit-section-hide :after #'k8s--track-section-hidden)

(defun k8s--show-sections-by-ids (ids)
  "Re-expand any section whose stable ID is in IDS.
IDS may be a list of strings or a hash table mapping IDs -> non-nil."
  (when ids
    (let ((set (cond
                ((hash-table-p ids) ids)
                (t (let ((h (make-hash-table :test 'equal)))
                     (dolist (id ids) (puthash id t h))
                     h)))))
      (when (> (hash-table-count set) 0)
        (save-excursion
          (goto-char (point-min))
          (let (seen)
            (while (not (eobp))
              (let ((sec (get-text-property (point) 'magit-section)))
                (when (and sec (not (memq sec seen)))
                  (push sec seen)
                  (when-let ((id (k8s--section-stable-id
                                  (ignore-errors (oref sec value)))))
                    (when (gethash id set)
                      (ignore-errors (magit-section-show sec))))))
              (forward-line 1))))))))

(defun k8s--save-point-context ()
  "Capture point + scroll + section state across a refresh.
A refresh runs from a timer or `g'; the buffer's own `point' can
lag what the user actually sees, so this reads the window's
point.  Also records the line offset within the section under
point and the stable IDs of every currently-expanded section,
so the restore lands on the same line of the same section even
when the user was inside an expanded body."
  (let* ((win (get-buffer-window (current-buffer) t))
         (pos (if win (window-point win) (point)))
         (sec (save-excursion (goto-char pos) (magit-current-section)))
         (val (and sec (ignore-errors (oref sec value))))
         (sec-start (and sec (ignore-errors (oref sec start))))
         (offset (and sec-start
                      (- (line-number-at-pos pos)
                         (line-number-at-pos sec-start)))))
    (list :id        (k8s--section-stable-id val)
          :offset    (max 0 (or offset 0))
          :line      (line-number-at-pos pos)
          :win-start (and win (window-start win))
          ;; Live hash, not a snapshot — save/render/restore is
          ;; synchronous so the hash can't move under us, and a
          ;; hash is what `k8s--show-sections-by-ids' wants anyway.
          :expanded  (k8s--ensure-expanded-set))))

(defun k8s--restore-point-context (ctx)
  "Re-seek to the section matching CTX (from `k8s--save-point-context').
Restores point, the line offset within its section, the window's
point, and — when still in range — the window's scroll position,
so a timer-driven refresh (events, watch, metrics poll) doesn't
jump the buffer.  Also re-expands any section the user had
expanded before the refresh, and re-runs the hl-line overlay
since a timer refresh fires no `post-command-hook'."
  ;; magit re-creates sections in their HIDE-arg state, so without
  ;; this every refresh re-collapses whatever the user expanded.
  (k8s--show-sections-by-ids (plist-get ctx :expanded))
  ;; Re-decorate marks (see k8s-marks.el) — overlays don't survive
  ;; an `erase-buffer', but the marked UIDs do.
  (k8s--marks-reapply)
  (let ((id (plist-get ctx :id))
        (offset (plist-get ctx :offset))
        (line (plist-get ctx :line))
        (win-start (plist-get ctx :win-start))
        target)
    (when id
      (save-excursion
        (goto-char (point-min))
        (while (and (not target) (not (eobp)))
          (let ((sec (get-text-property (point) 'magit-section)))
            (when sec
              (let ((sid (k8s--section-stable-id
                          (ignore-errors (oref sec value)))))
                (when (equal sid id)
                  (setq target (point))))))
          (forward-line 1))))
    (cond
     (target (goto-char target)
             ;; Re-apply the in-section line offset so the cursor
             ;; doesn't pop up to the section's heading after every
             ;; refresh.
             (when (and offset (> offset 0))
               (forward-line offset)
               (beginning-of-line)))
     (line   (goto-char (point-min))
             (forward-line (max 0 (1- line))))
     (t      (goto-char (point-min))))
    (let ((win (get-buffer-window (current-buffer) t)))
      (when win
        (set-window-point win (point))
        ;; Reapply the prior scroll position; the NOFORCE arg lets
        ;; redisplay nudge it if `point' would land off-screen.
        (when (and win-start (<= win-start (point-max)))
          (set-window-start win win-start t))))
    (when (and (bound-and-true-p hl-line-mode)
               (fboundp 'hl-line-highlight))
      (hl-line-highlight))))

(defun k8s--resource-labels (resource)
  "Return metadata.labels alist from RESOURCE."
  (cdr (assq 'labels (cdr (assq 'metadata resource)))))

(defalias 'k8s--age-string #'eltainer-ui-age-render)

(defun k8s--phase-face (phase)
  "Return the face for PHASE string."
  (pcase phase
    ("Running"   'k8s-status-running)
    ("Succeeded" 'k8s-status-running)
    ("Active"    'k8s-status-running)
    ("Complete"  'k8s-status-running)
    ("Bound"     'k8s-status-running)
    ("Available" 'k8s-status-running)
    ("Ready"     'k8s-status-running)
    ("Pending"      'k8s-status-pending)
    ("Terminating"  'k8s-status-failed)
    ("Failed"       'k8s-status-failed)
    (_              'k8s-status-other)))

(defun k8s--group-by-namespace (resources)
  "Group RESOURCES (a vector) into an alist of (NAMESPACE . LIST)."
  (let ((table (make-hash-table :test 'equal)))
    (seq-doseq (r resources)
      (let ((ns (or (k8s--resource-namespace r) "<cluster>")))
        (puthash ns (cons r (gethash ns table)) table)))
    (let (result)
      (maphash (lambda (ns items)
                 (push (cons ns (nreverse items)) result))
               table)
      (sort result (lambda (a b) (string< (car a) (car b)))))))

(defun k8s--insert-labels (labels indent)
  "Insert LABELS alist with INDENT string prefix."
  (when labels
    (insert (propertize (concat indent "Labels:    ") 'font-lock-face 'k8s-dim))
    (let ((first t)
          (pad (make-string (+ (length indent) 11) ?\s)))
      (dolist (pair labels)
        (unless first (insert (propertize pad 'font-lock-face 'k8s-dim)))
        (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                            'font-lock-face 'k8s-dim))
        (setq first nil)))))

(defun k8s--insert-selector (selector indent)
  "Insert SELECTOR alist with INDENT string prefix."
  (when selector
    (insert (propertize (concat indent "Selector:  ") 'font-lock-face 'k8s-dim))
    (let ((first t)
          (pad (make-string (+ (length indent) 11) ?\s)))
      (dolist (pair selector)
        (unless first (insert (propertize pad 'font-lock-face 'k8s-dim)))
        (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                            'font-lock-face 'k8s-dim))
        (setq first nil)))))

(defun k8s--first-container-image (resource)
  "Return the first container image from a workload RESOURCE spec."
  (let* ((spec (cdr (assq 'spec resource)))
         (tmpl (cdr (assq 'template spec)))
         (pod-spec (cdr (assq 'spec tmpl)))
         (containers (cdr (assq 'containers pod-spec))))
    (when (and containers (> (length containers) 0))
      (cdr (assq 'image (aref containers 0))))))

;;; ---------------------------------------------------------------------------
;;; Resource type registry

(defvar k8s--resource-types nil
  "Alist of (DISPLAY-NAME . COMMAND) for available resource views.")

;;; ---------------------------------------------------------------------------
;;; Resource switching (transient popup)

(transient-define-prefix k8s-switch-resource ()
  "Switch to a different resource view."
  [["Workloads"
    ("p" "Pods"         k8s-pods)
    ("d" "Deployments"  k8s-deployments)
    ("S" "StatefulSets" k8s-statefulsets)
    ("D" "DaemonSets"   k8s-daemonsets)]
   ["Batch"
    ("j" "Jobs"         k8s-jobs)
    ("c" "CronJobs"     k8s-cronjobs)]
   ["Config & Network"
    ("s" "Services"     k8s-services)
    ("i" "Ingresses"    k8s-ingresses)
    ("m" "ConfigMaps"   k8s-configmaps)
    ("x" "Secrets"      k8s-secrets)]])

;;; ---------------------------------------------------------------------------
;;; Namespace switching (completing-read)

;;; ---------------------------------------------------------------------------
;;; Describe resource

(defun k8s--describe-value (value indent)
  "Recursively format VALUE as readable text at INDENT level.
Thin wrapper over `eltainer-ui-describe-value' that keeps the
k8s-themed heading face."
  (eltainer-ui-describe-value value indent 'k8s-section-heading))

(defun k8s--describe-insert-events (conn ns name)
  "Insert events for resource NAME in NS."
  (let ((events (condition-case nil
                    (k8s-list-events conn ns
                                    (format "involvedObject.name=%s" name))
                  (error nil))))
    (when (and events (> (length events) 0))
      (insert "\n"
              (propertize "Events:\n" 'font-lock-face 'k8s-section-heading))
      (insert (propertize
               (format "  %-8s %-8s %-25s %-10s %s\n"
                       "LAST" "COUNT" "SOURCE" "TYPE" "MESSAGE")
               'font-lock-face 'k8s-dim))
      (seq-doseq (ev events)
        (let* ((last-time (or (cdr (assq 'lastTimestamp ev)) ""))
               (count (or (cdr (assq 'count ev)) 1))
               (source (cdr (assq 'source ev)))
               (component (or (cdr (assq 'component source)) ""))
               (type (or (cdr (assq 'type ev)) ""))
               (message (or (cdr (assq 'message ev)) "")))
          (insert (format "  %-8s %-8s %-25s %-10s %s\n"
                          (k8s--age-string last-time)
                          count
                          (truncate-string-to-width component 25)
                          (propertize type 'font-lock-face
                                      (if (string= type "Warning")
                                          'k8s-status-failed
                                        'k8s-status-running))
                          message)))))))

(defun k8s-describe ()
  "Describe the resource at point — show full details and events."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (oref section value)
                 (listp (oref section value))
                 (assq 'metadata (oref section value)))
      (user-error "Not on a resource"))
    (let* ((resource (oref section value))
           (meta (cdr (assq 'metadata resource)))
           (name (cdr (assq 'name meta)))
           (ns (or (cdr (assq 'namespace meta)) ""))
           (kind (or (cdr (assq 'kind resource))
                     (symbol-name (oref section type))))
           (conn (k8s--ensure-connection))
           (buf (get-buffer-create
                 (format "*k8s:describe:%s/%s*"
                         (if (string= ns "") "cluster" ns) name))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          ;; Header
          (insert (propertize (format "%s: %s" kind name)
                              'font-lock-face 'k8s-resource-name)
                  "\n")
          (when (not (string= ns ""))
            (insert (propertize "Namespace: " 'font-lock-face 'k8s-dim)
                    ns "\n"))
          (insert "\n")
          ;; Metadata
          (insert (propertize "Metadata:\n" 'font-lock-face 'k8s-section-heading))
          (dolist (key '(name namespace uid creationTimestamp))
            (let ((val (cdr (assq key meta))))
              (when val
                (insert (propertize (format "  %s: " key) 'font-lock-face 'k8s-dim)
                        (format "%s\n" val)))))
          (let ((labels (cdr (assq 'labels meta))))
            (when labels
              (insert (propertize "  labels:\n" 'font-lock-face 'k8s-dim))
              (dolist (pair labels)
                (insert (propertize "    " 'font-lock-face 'k8s-dim)
                        (format "%s: %s\n" (car pair) (cdr pair))))))
          (let ((annotations (cdr (assq 'annotations meta))))
            (when annotations
              (insert (propertize "  annotations:\n" 'font-lock-face 'k8s-dim))
              (dolist (pair annotations)
                (insert (propertize "    " 'font-lock-face 'k8s-dim)
                        (format "%s: %s\n" (car pair) (cdr pair))))))
          ;; Spec
          (let ((spec (cdr (assq 'spec resource))))
            (when spec
              (insert "\n"
                      (propertize "Spec:" 'font-lock-face 'k8s-section-heading))
              (k8s--describe-value spec 2)))
          ;; Status
          (let ((status (cdr (assq 'status resource))))
            (when status
              (insert "\n"
                      (propertize "Status:" 'font-lock-face 'k8s-section-heading))
              (k8s--describe-value status 2)))
          ;; Events
          (when (not (string= ns ""))
            (k8s--describe-insert-events conn ns name)))
        (goto-char (point-min))
        (special-mode)
        (local-set-key "q" #'quit-window)
        (local-set-key "g" (lambda ()
                             (interactive)
                             (k8s-describe))))
      (pop-to-buffer buf))))

;;; ---------------------------------------------------------------------------
;;; Delete resource

(defun k8s-delete-at-point ()
  "Delete the resource at point after confirmation."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (oref section value)
                 (listp (oref section value))
                 (assq 'metadata (oref section value)))
      (user-error "Not on a resource"))
    (let* ((resource (oref section value))
           (type (oref section type))
           (meta (cdr (assq 'metadata resource)))
           (name (cdr (assq 'name meta)))
           (ns (cdr (assq 'namespace meta)))
           (conn (k8s--ensure-connection)))
      (unless (gethash type k8s--resource-api-paths-hash)
        (user-error "Don't know how to delete %s" type))
      (when (yes-or-no-p (format "Delete %s %s/%s? " type ns name))
        (message "eltainer: deleting %s %s/%s ..." type ns name)
        (let ((result (k8s-delete-resource conn type ns name)))
          (if (and result (equal (cdr (assq 'status result)) "Success"))
              (message "eltainer: deleted %s %s/%s" type ns name)
            (message "eltainer: delete %s %s/%s — %s"
                     type ns name
                     (or (cdr (assq 'message result))
                         (cdr (assq 'status result))
                         "sent")))
          (revert-buffer))))))

;;; ---------------------------------------------------------------------------
;;; Header keymaps for clickable fields

(defvar-keymap k8s--resource-header-map
  "RET"       #'k8s-switch-resource
  "<mouse-1>" #'k8s-switch-resource)

(defvar-keymap k8s--namespace-header-map
  "RET"       #'k8s-set-namespace
  "<mouse-1>" #'k8s-set-namespace)

;;; ---------------------------------------------------------------------------
;;; Header / namespace display

(defun k8s--insert-header (resource-type)
  "Insert the header with cluster info and current RESOURCE-TYPE."
  (let* ((conn (k8s--ensure-connection))
         (host (k8s-connection-host conn))
         (port (k8s-connection-port conn))
         (user (k8s-user-name (k8s-connection-user conn))))
    (insert (propertize "Cluster:   " 'font-lock-face 'k8s-dim)
            (format "%s:%d" host port)
            "\n")
    (insert (propertize "User:      " 'font-lock-face 'k8s-dim)
            user
            "\n")
    (insert (propertize "Resource:  " 'font-lock-face 'k8s-dim)
            (propertize resource-type
                        'font-lock-face 'k8s-resource-name
                        'k8s-field 'resource
                        'keymap k8s--resource-header-map
                        'mouse-face 'highlight
                        'help-echo "RET: switch resource type")
            "\n")
    (insert (propertize "Namespace: " 'font-lock-face 'k8s-dim)
            (propertize (or k8s--namespace "all")
                        'font-lock-face (if k8s--namespace
                                            'k8s-namespace
                                          'k8s-dim)
                        'k8s-field 'namespace
                        'keymap k8s--namespace-header-map
                        'mouse-face 'highlight
                        'help-echo "RET: switch namespace")
            "\n\n")))

(defun k8s--insert-namespace-heading (ns count)
  "Insert a namespace section heading for NS with COUNT items."
  (magit-insert-heading
    (format "%s (%d)\n"
            (propertize ns 'font-lock-face 'k8s-namespace)
            count)))

;;; ---------------------------------------------------------------------------
;;; Namespace narrowing

(defun k8s-set-namespace (namespace)
  "Filter the current view to NAMESPACE.  Empty string means all."
  (interactive
   (let* ((conn (k8s--ensure-connection))
          (namespaces (k8s-list-namespaces conn))
          (names (cons "all"
                       (sort (mapcar #'k8s--resource-name
                                     (append namespaces nil))
                             #'string<))))
     (list (completing-read "Namespace: " names nil t))))
  (setq k8s--namespace (if (string= namespace "all") nil namespace))
  ;; Clear resource table so refresh does a fresh API call
  (let ((was-watching k8s--watch))
    (when was-watching (k8s--watch-stop-for-buffer))
    (setq k8s--resource-table nil)
    (revert-buffer)
    ;; Restart watch with new namespace scope
    (when was-watching (k8s--watch-start-for-buffer))))

;;; ---------------------------------------------------------------------------
;;; Shared keymap fragment
;;
;; `k8s-common-map' itself is defined in k8s-marks.el (which loads
;; before any view file) so per-view maps can inherit it via
;; `:parent k8s-common-map' without a load-order dance.  Adding the
;; view-specific bindings on top of common-map happens via straight
;; key binds — no copy step — so changes to common-map propagate
;; automatically across `eltainer-reload'.

;; `eltainer-switch-kubeconfig' lives in the top-level eltainer.el so
;; both the dashboard and the k8s views can call it.  Autoload so we
;; don't force `(require 'eltainer)' from k8s.el (that'd circle back).
(autoload 'eltainer-switch-kubeconfig "eltainer" nil t)

(defun k8s-dwim-ret ()
  "Smart RET: header-field activate / jump-target follow / section toggle.
Picks the action from the text property under point:
  `k8s-field'        — header line activator (resource / namespace).
  `k8s-jump-target'  — cross-resource jump (Ingress -> Service, etc.).
  otherwise          — magit-section toggle."
  (interactive)
  (let ((field  (get-text-property (point) 'k8s-field))
        (target (get-text-property (point) 'k8s-jump-target)))
    (cond
     ((eq field 'resource)   (call-interactively #'k8s-switch-resource))
     ((eq field 'namespace)  (call-interactively #'k8s-set-namespace))
     (target                 (k8s--jump-to-target target))
     (t                      (call-interactively #'magit-section-toggle)))))

;; Defined in k8s-helm.el (loaded after k8s.el).  At runtime when
;; `k8s--jump-to-target' runs the helm-resources arm, the helm view is
;; necessarily up so the variable is bound — this declaration just
;; quiets the byte-compiler's free-variable warning.
(defvar k8s-helm--kind-to-view)

(defun k8s--jump-to-target (target)
  "Follow the `k8s-jump-target' property TARGET.
TARGET is a list whose CAR is the kind and CDR carries the
identifying details.  Recognised forms:

  (service NS NAME)
    Open the services view, switch namespace if needed, scroll to
    NAME.

  (helm-resources NS KIND (NAME ...))
    Open the resource view for KIND (per
    `k8s-helm--kind-to-view'), switch to NS, and pre-set a name-
    regex filter narrowing to exactly the listed names.  Used by
    `RET' on a Helm release's RESOURCES tally row.

Future kinds (pod / node / endpoints / configmap / …) add their
own arms here."
  (pcase target
    (`(service ,ns ,name)
     (k8s-services)
     (with-current-buffer (get-buffer "*k8s:services*")
       (when (and ns (not (equal ns k8s--namespace)))
         (setq-local k8s--namespace ns)
         (k8s--services-refresh))
       (goto-char (point-min))
       (if (re-search-forward
            (format "^  %s[[:space:]]" (regexp-quote name)) nil t)
           (beginning-of-line)
         (message "k8s: %s/%s not found in services view" ns name))))
    (`(helm-resources ,ns ,kind ,names)
     (let ((entry (assoc kind k8s-helm--kind-to-view)))
       (unless entry
         (user-error "k8s-helm: no resource view registered for kind %S"
                     kind))
       (funcall (nth 1 entry))
       (with-current-buffer (get-buffer (nth 2 entry))
         (when ns (setq-local k8s--namespace ns))
         (setq-local eltainer-filter--state
                     (eltainer-filter--new
                      :name-regex
                      (concat "\\`\\("
                              (mapconcat #'regexp-quote names "\\|")
                              "\\)\\'")))
         (revert-buffer nil t)
         (message "k8s: %s view narrowed to %d %s resource%s from the release"
                  kind (length names) kind
                  (if (= 1 (length names)) "" "s")))))
    (_
     (message "k8s-jump-target: don't know how to follow %S" target))))

;;; ---------------------------------------------------------------------------
;;; Watch integration

(defun k8s--watch-event-handler (type object)
  "Handle a watch event: update resource table and schedule re-render.
TYPE is \"ADDED\", \"MODIFIED\", \"DELETED\", or \"BOOKMARK\"."
  (when k8s--resource-table
    (let ((uid (cdr (assq 'uid (cdr (assq 'metadata object))))))
      (pcase type
        ("ADDED"    (puthash uid object k8s--resource-table))
        ("MODIFIED" (puthash uid object k8s--resource-table))
        ("DELETED"  (remhash uid k8s--resource-table))
        ("BOOKMARK" nil)  ; just a keepalive
        ("ERROR"
         (message "eltainer watch: error event: %s"
                  (cdr (assq 'message object))))))
    ;; Debounced re-render
    (when k8s--watch-debounce-timer
      (cancel-timer k8s--watch-debounce-timer))
    (let ((buf (current-buffer)))
      (setq k8s--watch-debounce-timer
            (run-at-time 0.3 nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (setq k8s--watch-debounce-timer nil)
                               (k8s--watch-render)))))))))

(defun k8s--watch-render ()
  "Re-render the current buffer from the resource table.
Point and scroll position are preserved by the view's refresh
itself (`k8s--save-point-context' / `k8s--restore-point-context');
this just triggers the revert.  The previous manual save/restore
here clobbered that section-aware restore with a raw — and, from a
timer, often stale — buffer position, which is what jumped the
buffer to the top on every watch event."
  (revert-buffer nil t))

(defvar-local k8s--watch-starting nil
  "Non-nil while a watch start is in progress.")

(defun k8s-watch-toggle ()
  "Toggle watch mode for the current resource view."
  (interactive)
  (cond
   (k8s--watch-starting
    (message "eltainer: watch start already in progress..."))
   (k8s--watch
    (k8s--watch-stop-for-buffer))
   (t
    (k8s--watch-start-for-buffer))))

(defun k8s--watch-start-for-buffer ()
  "Start watching for the current buffer's resource type."
  (unless k8s--api-path-fn
    (user-error "This view does not support watching"))
  (setq k8s--watch-starting t)
  (message "eltainer: starting watch...")
  (redisplay)
  (unwind-protect
      (let* ((conn (k8s--ensure-connection))
             (path (funcall k8s--api-path-fn k8s--namespace))
             (response (k8s-get conn path))
             (rv (k8s--extract-resource-version response))
             (items (cdr (assq 'items response))))
        ;; Populate resource table
        (setq k8s--resource-table (make-hash-table :test 'equal))
        (seq-doseq (item items)
          (let ((uid (cdr (assq 'uid (cdr (assq 'metadata item))))))
            (when uid (puthash uid item k8s--resource-table))))
        ;; Render from table
        (revert-buffer nil t)
        ;; Start watch
        (let ((buf (current-buffer)))
          (setq k8s--watch
                (k8s-watch-start conn path rv
                                 (lambda (type object)
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (k8s--watch-event-handler type object)))))))
        (force-mode-line-update)
        (message "eltainer: watching %s" path))
    (setq k8s--watch-starting nil)))

(defun k8s--watch-stop-for-buffer ()
  "Stop watching for the current buffer."
  (when k8s--watch
    (k8s-watch-stop k8s--watch)
    (setq k8s--watch nil)
    (setq k8s--resource-table nil)
    (force-mode-line-update)
    (message "eltainer: watch stopped")))

(defun k8s--watch-mode-line ()
  "Return mode-line string indicating watch status."
  (cond
   ((and k8s--watch (k8s-watch-active-p k8s--watch)
         (k8s-watch-process k8s--watch)
         (process-live-p (k8s-watch-process k8s--watch)))
    (propertize " [W]" 'face 'success))
   ((and k8s--watch (k8s-watch-active-p k8s--watch))
    (propertize " [W!]" 'face 'warning))
   (t "")))

(defun k8s--filter-mode-line ()
  "Return mode-line string summarising the active filter, or `\"\"'."
  (if (or (null eltainer-filter--state)
          (eltainer-filter-empty-p eltainer-filter--state))
      ""
    (propertize (format " [%s]"
                        (eltainer-filter-format eltainer-filter--state))
                'face 'warning)))

(defun k8s--on-filter-change ()
  "`eltainer-filter-change-hook' handler for k8s views.
Stops the watch (it was opened with the previous filter's
labelSelector and won't reflect the new one), drops the
resource-table cache so the next refresh hits the API fresh, and
lets the generic refresh path re-render."
  (when (derived-mode-p 'magit-section-mode)
    (when (and k8s--watch (k8s-watch-active-p k8s--watch))
      (k8s--watch-stop-for-buffer))
    (setq k8s--resource-table nil)))

(add-hook 'eltainer-filter-change-hook #'k8s--on-filter-change)

;;; ---------------------------------------------------------------------------
;;; Generic refresh engine

(defun k8s--generic-refresh (resource-type api-fn column-header line-fn)
  "Refresh buffer showing RESOURCE-TYPE.
API-FN fetches items, COLUMN-HEADER is the column titles string,
LINE-FN inserts one item as a section.

When an `eltainer-filter' is active for this buffer:
  - the label-selector half is applied SERVER-SIDE via
    `k8s--api-path-fn' (which builds the URL's `?labelSelector=');
  - the name-regex half is applied CLIENT-SIDE here, after fetch."
  (let* ((inhibit-read-only t)
         (ctx (k8s--save-point-context))
         (conn (k8s--ensure-connection))
         (filter eltainer-filter--state)
         (items (if (and k8s--resource-table
                         (> (hash-table-count k8s--resource-table) 0))
                    ;; Use cached items from watch
                    (vconcat (hash-table-values k8s--resource-table))
                  ;; Fresh API call.  Prefer `k8s--api-path-fn' (which
                  ;; bakes in the active label-selector) when set.
                  (if k8s--api-path-fn
                      (cdr (assq 'items
                                 (k8s-get
                                  conn (funcall k8s--api-path-fn
                                                k8s--namespace))))
                    (funcall api-fn conn k8s--namespace))))
         (items (if (and filter
                         (let ((nr (eltainer-filter-name-regex filter)))
                           (and nr (not (string-empty-p nr)))))
                    (seq-filter
                     (lambda (it)
                       (eltainer-filter-match-name-p
                        filter (k8s--resource-name it)))
                     items)
                  items))
         (grouped (k8s--group-by-namespace items)))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-root)
      (k8s--insert-header resource-type)
      (insert (propertize column-header 'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (dolist (group grouped)
        (magit-insert-section (namespace (car group))
          (k8s--insert-namespace-heading (car group) (length (cdr group)))
          (dolist (item (cdr group))
            (funcall line-fn item))
          (insert "\n"))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (k8s--restore-point-context ctx)))

;;; ---------------------------------------------------------------------------
;;; View definition macro

(defmacro k8s--define-view (name docstring api-fn column-header line-fn)
  "Define a resource view named NAME.
Generates: k8s--NAME-refresh, k8s-NAME-mode, k8s-NAME command.
API-FN fetches items, COLUMN-HEADER is the header string,
LINE-FN inserts one item."
  (let* ((namestr (symbol-name name))
         (display (capitalize namestr))
         (refresh-fn (intern (format "k8s--%s-refresh" namestr)))
         (mode-fn (intern (format "k8s-%s-mode" namestr)))
         (mode-map (intern (format "k8s-%s-mode-map" namestr)))
         (cmd-fn (intern (format "k8s-%s" namestr)))
         (buf-name (format "*k8s:%s*" namestr)))
    `(progn
       (defun ,refresh-fn ()
         ,(format "Refresh the %s buffer." namestr)
         (k8s--generic-refresh ,display ,api-fn ,column-header ,line-fn))

       ;; Plain defvar (not defvar-keymap) so the parent link
       ;; re-installs idempotently on every `eltainer-reload'.
       (defvar ,mode-map (make-sparse-keymap)
         ,(format "Keymap for `k8s-%s-mode'." namestr))
       (set-keymap-parent ,mode-map k8s-common-map)

       (define-derived-mode ,mode-fn magit-section-mode
         ,(format "K8s:%s" (capitalize namestr))
         ,docstring
         :interactive nil
         :group 'k8s
         (setq-local revert-buffer-function
                     (lambda (_ignore-auto _noconfirm) (,refresh-fn)))
         (setq mode-line-format
               (list "%e" 'mode-line-front-space 'mode-line-mule-info
                     'mode-line-modified 'mode-line-remote " "
                     'mode-line-buffer-identification "  "
                     '(:eval (k8s--watch-mode-line))
                     '(:eval (k8s--filter-mode-line)) "  "
                     'mode-line-position 'mode-line-modes
                     'mode-line-end-spaces))
         (add-hook 'kill-buffer-hook #'k8s--watch-stop-for-buffer nil t))

       (defun ,cmd-fn ()
         ,(format "Display %s in the current Kubernetes cluster." namestr)
         (interactive)
         (let ((buf (get-buffer-create ,buf-name)))
           (with-current-buffer buf
             (,mode-fn)
             (k8s--ensure-connection)
             (setq k8s--api-path-fn
                   (lambda (ns)
                     (k8s--list-path
                      ',name ns
                      (and (bound-and-true-p eltainer-filter--state)
                           (eltainer-filter-label-selector
                            eltainer-filter--state)))))
             (,refresh-fn))
           (pop-to-buffer buf)))

       (push (cons ,display #',cmd-fn) k8s--resource-types))))

;;; ---------------------------------------------------------------------------
;;; Transient dispatch

(autoload 'k8s-pods "k8s-pods" nil t)
(autoload 'k8s-helm "k8s-helm" nil t)
(autoload 'k8s-crds "k8s-crds" nil t)
(autoload 'k8s-pulse "k8s-pulse" nil t)
(autoload 'k8s-xray-at-point "k8s-xray" nil t)
(autoload 'k8s-edit-at-point "k8s-edit" nil t)
(autoload 'k8s-scale-at-point          "k8s-actions" nil t)
(autoload 'k8s-rollout-restart-at-point "k8s-actions" nil t)
(autoload 'k8s-force-kill-pod-at-point  "k8s-actions" nil t)
(autoload 'k8s-cordon-toggle-at-point   "k8s-actions" nil t)
(autoload 'k8s-drain-at-point           "k8s-actions" nil t)
(autoload 'k8s-portforward              "k8s-portforward" nil t)
(autoload 'k8s-portforward-at-point     "k8s-portforward" nil t)
(autoload 'k8s-portforward-list         "k8s-portforward" nil t)
(autoload 'k8s-events                   "k8s-events" nil t)

;;; ---------------------------------------------------------------------------
;;; Context-aware dispatch

;; Pod-action commands live in k8s-pods.el; k8s.el doesn't `require' it
;; (the dependency runs the other way).  Declare them so the
;; byte-compiler is quiet — they resolve at runtime, by which point a
;; k8s-pods buffer is loaded.
(declare-function k8s-pod-view-logs       "k8s-pods")
(declare-function k8s-pod-exec-at-point   "k8s-pods")
(declare-function k8s-dired-browse-at-point "k8s-dired")
(declare-function k8s-pod-metrics-at-point "k8s-pods")
(declare-function k8s-pod-dns-lookup-at-point "k8s-pods")

(defun k8s--section-type-at-point ()
  "Return the magit-section TYPE under point, or nil."
  (let ((sec (magit-current-section)))
    (and sec (oref sec type))))

(defun k8s--point-on-p (type)
  "Return non-nil when the section under point has section-type TYPE."
  (eq (k8s--section-type-at-point) type))

(defun k8s--point-on-resource-p ()
  "Return non-nil when point is on a non-pod k8s resource section.
That is: a section whose value is a resource alist (carries
`metadata') and whose type is neither `pod' nor `container'."
  (let ((sec (magit-current-section)))
    (and sec
         (not (memq (oref sec type) '(pod container)))
         (let ((v (oref sec value)))
           (and (listp v) (assq 'metadata v))))))

(transient-define-prefix k8s-view-dispatch ()
  "Switch to another Kubernetes resource view."
  [["Workloads"
    ("p" "Pods"         k8s-pods)
    ("d" "Deployments"  k8s-deployments)
    ("S" "StatefulSets" k8s-statefulsets)
    ("D" "DaemonSets"   k8s-daemonsets)]
   ["Batch"
    ("j" "Jobs"         k8s-jobs)
    ("c" "CronJobs"     k8s-cronjobs)]
   ["Config & Network"
    ("s" "Services"        k8s-services)
    ("i" "Ingresses"       k8s-ingresses)
    ("m" "ConfigMaps"      k8s-configmaps)
    ("x" "Secrets"         k8s-secrets)
    ("n" "NetworkPolicies" k8s-networkpolicies)]
   ["Storage"
    ("v" "PVCs"            k8s-persistentvolumeclaims)
    ("V" "PVs"             k8s-persistentvolumes)
    ("z" "StorageClasses"  k8s-storageclasses)]
   ["Scaling"
    ("a" "HPAs"            k8s-horizontalpodautoscalers)
    ("b" "PDBs"            k8s-poddisruptionbudgets)]
   ["RBAC"
    ("A" "ServiceAccounts"     k8s-serviceaccounts)
    ("Q" "Roles"               k8s-roles)
    ("Y" "RoleBindings"        k8s-rolebindings)
    ("X" "ClusterRoles"        k8s-clusterroles)
    ("Z" "ClusterRoleBindings" k8s-clusterrolebindings)]
   ["Cluster"
    ("P" "Pulse"        k8s-pulse)
    ("E" "Events"       k8s-events)
    ("o" "Nodes"        k8s-nodes)]
   ["Agents"
    ("A" "Sandboxes"    k8s-sandboxes)]
   ["Packaging"
    ("h" "Helm releases" k8s-helm)]
   ["Extensions"
    ("R" "Custom resources" k8s-crds)]])

(transient-define-prefix k8s-dispatch ()
  "Context-aware command menu for the Kubernetes views.
The first group reflects the resource under point — pod, container,
or another resource — so `?' only ever offers actions that apply
where the cursor is."
  [:if (lambda () (k8s--point-on-p 'pod))
   "Pod at point"
   ("l" "Logs"       k8s-pod-view-logs)
   ("e" "Exec"       k8s-pod-exec-at-point)
   ("f" "Browse fs"  k8s-dired-browse-at-point)
   ("D" "DNS lookup" k8s-pod-dns-lookup-at-point)
   ("M" "Metrics"    k8s-pod-metrics-at-point)
   ("i" "Describe"   k8s-describe)
   ("d" "Delete"     k8s-delete-at-point)]
  [:if (lambda () (k8s--point-on-p 'container))
   "Container at point"
   ("l" "Logs"       k8s-pod-view-logs)
   ("e" "Exec"       k8s-pod-exec-at-point)
   ("f" "Browse fs"  k8s-dired-browse-at-point)
   ("D" "DNS lookup" k8s-pod-dns-lookup-at-point)
   ("M" "Metrics"    k8s-pod-metrics-at-point)]
  [:if (lambda () (k8s--point-on-p 'cronjob))
   "CronJob at point"
   ("l" "Logs (last run)" k8s-cronjob-view-logs-at-point)
   ("i" "Describe"        k8s-describe)
   ("d" "Delete"          k8s-delete-at-point)]
  [:if k8s--point-on-resource-p
   "Resource at point"
   ("i" "Describe"   k8s-describe)
   ("d" "Delete"     k8s-delete-at-point)]
  [["View"
    ("v" "Switch view…" k8s-view-dispatch)]
   ["Cluster"
    ("b" "Switch context" eltainer-switch-kubeconfig)
    ("w" "Toggle watch"   k8s-watch-toggle)
    ("N" "Namespace"      k8s-set-namespace)
    ("o" "Nodes"          k8s-nodes)]
   ["Buffer"
    ("g" "Refresh" revert-buffer)
    ("q" "Quit"    quit-window)]])

;;;###autoload
(defun k8s ()
  "Main entry point for the eltainer k8s views.  Shows pods by default."
  (interactive)
  (k8s-pods))

;; Register pods (defined in k8s-pods.el) in the resource type list
(push '("Pods" . k8s-pods) k8s--resource-types)

;;; =========================================================================
;;; Resource views
;;; =========================================================================

;;; ---------------------------------------------------------------------------
;;; Deployments

(defun k8s--insert-deployment-line (deploy)
  "Insert a deployment summary line."
  (let* ((name (k8s--resource-name deploy))
         (status (cdr (assq 'status deploy)))
         (replicas (or (cdr (assq 'replicas status)) 0))
         (ready (or (cdr (assq 'readyReplicas status)) 0))
         (age (k8s--age-string (k8s--resource-creation-time deploy)))
         (image (or (k8s--first-container-image deploy) "")))
    (magit-insert-section (deployment deploy t)
      (magit-insert-heading
        (format "  %-42s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d/%d" ready replicas)
                age
                (propertize image 'font-lock-face 'k8s-dim)))
      (let* ((spec (cdr (assq 'spec deploy)))
             (strategy (or (cdr (assq 'type (cdr (assq 'strategy spec)))) "?"))
             (updated (or (cdr (assq 'updatedReplicas status)) 0))
             (available (or (cdr (assq 'availableReplicas status)) 0))
             (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec))))))
        (insert (propertize (format "    Strategy:  %s\n" strategy)
                            'font-lock-face 'k8s-dim))
        (insert (propertize (format "    Replicas:  %d desired, %d updated, %d available\n"
                                    replicas updated available)
                            'font-lock-face 'k8s-dim))
        (k8s--insert-selector selector "    ")
        (k8s--insert-labels (k8s--resource-labels deploy) "    ")
        (insert "\n")))))

(k8s--define-view deployments
  "Major mode for viewing Kubernetes deployments."
  #'k8s-list-deployments
  (format "  %-42s %-10s %-6s %s\n" "NAME" "READY" "AGE" "IMAGE")
  #'k8s--insert-deployment-line)

;;; ---------------------------------------------------------------------------
;;; StatefulSets

(defun k8s--insert-statefulset-line (sts)
  "Insert a statefulset summary line."
  (let* ((name (k8s--resource-name sts))
         (status (cdr (assq 'status sts)))
         (replicas (or (cdr (assq 'replicas status)) 0))
         (ready (or (cdr (assq 'readyReplicas status)) 0))
         (age (k8s--age-string (k8s--resource-creation-time sts)))
         (image (or (k8s--first-container-image sts) "")))
    (magit-insert-section (statefulset sts t)
      (magit-insert-heading
        (format "  %-42s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d/%d" ready replicas)
                age
                (propertize image 'font-lock-face 'k8s-dim)))
      (let* ((spec (cdr (assq 'spec sts)))
             (policy (or (cdr (assq 'podManagementPolicy spec)) "OrderedReady"))
             (svc-name (cdr (assq 'serviceName spec)))
             (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec))))))
        (insert (propertize (format "    Policy:    %s\n" policy)
                            'font-lock-face 'k8s-dim))
        (when svc-name
          (insert (propertize (format "    Service:   %s\n" svc-name)
                              'font-lock-face 'k8s-dim)))
        (k8s--insert-selector selector "    ")
        (k8s--insert-labels (k8s--resource-labels sts) "    ")
        (insert "\n")))))

(k8s--define-view statefulsets
  "Major mode for viewing Kubernetes statefulsets."
  #'k8s-list-statefulsets
  (format "  %-42s %-10s %-6s %s\n" "NAME" "READY" "AGE" "IMAGE")
  #'k8s--insert-statefulset-line)

;;; ---------------------------------------------------------------------------
;;; DaemonSets

(defun k8s--insert-daemonset-line (ds)
  "Insert a daemonset summary line."
  (let* ((name (k8s--resource-name ds))
         (status (cdr (assq 'status ds)))
         (desired (or (cdr (assq 'desiredNumberScheduled status)) 0))
         (ready (or (cdr (assq 'numberReady status)) 0))
         (available (or (cdr (assq 'numberAvailable status)) 0))
         (age (k8s--age-string (k8s--resource-creation-time ds)))
         (image (or (k8s--first-container-image ds) "")))
    (magit-insert-section (daemonset ds t)
      (magit-insert-heading
        (format "  %-42s %-10s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d/%d" ready desired)
                (propertize (format "%d" available) 'font-lock-face 'k8s-dim)
                age
                (propertize image 'font-lock-face 'k8s-dim)))
      (let* ((spec (cdr (assq 'spec ds)))
             (selector (cdr (assq 'matchLabels (cdr (assq 'selector spec)))))
             (node-sel (cdr (assq 'nodeSelector
                                  (cdr (assq 'spec
                                             (cdr (assq 'template spec))))))))
        (when node-sel
          (insert (propertize "    NodeSel:   " 'font-lock-face 'k8s-dim))
          (let ((first t))
            (dolist (pair node-sel)
              (unless first (insert (propertize "               " 'font-lock-face 'k8s-dim)))
              (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                                  'font-lock-face 'k8s-dim))
              (setq first nil))))
        (k8s--insert-selector selector "    ")
        (k8s--insert-labels (k8s--resource-labels ds) "    ")
        (insert "\n")))))

(k8s--define-view daemonsets
  "Major mode for viewing Kubernetes daemonsets."
  #'k8s-list-daemonsets
  (format "  %-42s %-10s %-10s %-6s %s\n" "NAME" "READY" "AVAILABLE" "AGE" "IMAGE")
  #'k8s--insert-daemonset-line)

;;; ---------------------------------------------------------------------------
;;; Jobs

(defun k8s--insert-job-line (job)
  "Insert a job summary line."
  (let* ((name (k8s--resource-name job))
         (status (cdr (assq 'status job)))
         (spec (cdr (assq 'spec job)))
         (completions (or (cdr (assq 'completions spec)) 1))
         (succeeded (or (cdr (assq 'succeeded status)) 0))
         (failed (or (cdr (assq 'failed status)) 0))
         (active (or (cdr (assq 'active status)) 0))
         (conditions (cdr (assq 'conditions status)))
         (phase (cond
                 ((and conditions (> (length conditions) 0))
                  (cdr (assq 'type (aref conditions 0))))
                 ((> active 0) "Running")
                 ((= succeeded completions) "Complete")
                 (t "Pending")))
         (age (k8s--age-string (k8s--resource-creation-time job))))
    (magit-insert-section (job job t)
      (magit-insert-heading
        (format "  %-42s %-12s %-10s %-6s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize phase 'font-lock-face (k8s--phase-face phase))
                (format "%d/%d" succeeded completions)
                age))
      (insert (propertize (format "    Active: %d  Succeeded: %d  Failed: %d\n"
                                  active succeeded failed)
                          'font-lock-face 'k8s-dim))
      (k8s--insert-labels (k8s--resource-labels job) "    ")
      (insert "\n"))))

(k8s--define-view jobs
  "Major mode for viewing Kubernetes jobs."
  #'k8s-list-jobs
  (format "  %-42s %-12s %-10s %-6s\n" "NAME" "STATUS" "COMPLETIONS" "AGE")
  #'k8s--insert-job-line)

;;; ---------------------------------------------------------------------------
;;; CronJobs

(defun k8s--insert-cronjob-line (cj)
  "Insert a cronjob summary line."
  (let* ((name (k8s--resource-name cj))
         (spec (cdr (assq 'spec cj)))
         (schedule (or (cdr (assq 'schedule spec)) "?"))
         (suspend (if (eq (cdr (assq 'suspend spec)) t) "True" "False"))
         (status (cdr (assq 'status cj)))
         (active (length (or (cdr (assq 'active status)) [])))
         (last-schedule (cdr (assq 'lastScheduleTime status)))
         (last-age (if last-schedule (k8s--age-string last-schedule) "?")))
    (magit-insert-section (cronjob cj t)
      (magit-insert-heading
        (format "  %-35s %-18s %-10s %-8s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                schedule
                (propertize suspend 'font-lock-face
                            (if (string= suspend "True") 'k8s-status-pending
                              'k8s-dim))
                (propertize (format "%d" active) 'font-lock-face 'k8s-dim)
                last-age))
      (k8s--insert-labels (k8s--resource-labels cj) "    ")
      (insert "\n"))))

(k8s--define-view cronjobs
  "Major mode for viewing Kubernetes cronjobs."
  #'k8s-list-cronjobs
  (format "  %-35s %-18s %-10s %-8s %s\n" "NAME" "SCHEDULE" "SUSPEND" "ACTIVE" "LAST")
  #'k8s--insert-cronjob-line)

;; `l' from a cronjob row tails the logs of the most recent run.
(declare-function k8s--open-pod-log-buffer "k8s-pods")
(declare-function k8s--pod-container-names "k8s-pods")

(defun k8s--cronjob-latest-pod (conn ns cronjob-name)
  "Return (NAMESPACE . POD-NAME) for the latest pod of CRONJOB-NAME's
most recent Job, via CONN.  Returns nil when no matching Job or Pod
is found.  Done client-side: the K8s API has no field-selector for
`ownerReferences', and label-based filtering would miss Jobs whose
pods were renamed."
  (let* ((all-jobs (k8s-list-jobs conn ns))
         (jobs (cl-remove-if-not
                (lambda (j)
                  (seq-some
                   (lambda (o)
                     (and (equal (cdr (assq 'kind o)) "CronJob")
                          (equal (cdr (assq 'name o)) cronjob-name)))
                   (or (cdr (assq 'ownerReferences
                                  (cdr (assq 'metadata j))))
                       [])))
                (append all-jobs nil)))
         (jobs (sort jobs
                     (lambda (a b)
                       (string>
                        (or (cdr (assq 'creationTimestamp
                                       (cdr (assq 'metadata a)))) "")
                        (or (cdr (assq 'creationTimestamp
                                       (cdr (assq 'metadata b)))) "")))))
         (latest-job (car jobs))
         (job-name (and latest-job (k8s--resource-name latest-job))))
    (when job-name
      (let* ((all-pods (k8s-list-pods conn ns))
             (pods (cl-remove-if-not
                    (lambda (p)
                      (seq-some
                       (lambda (o)
                         (and (equal (cdr (assq 'kind o)) "Job")
                              (equal (cdr (assq 'name o)) job-name)))
                       (or (cdr (assq 'ownerReferences
                                      (cdr (assq 'metadata p))))
                           [])))
                    (append all-pods nil)))
             (pods (sort pods
                         (lambda (a b)
                           (string>
                            (or (cdr (assq 'creationTimestamp
                                           (cdr (assq 'metadata a)))) "")
                            (or (cdr (assq 'creationTimestamp
                                           (cdr (assq 'metadata b)))) ""))))))
        (when (car pods)
          (cons ns (k8s--resource-name (car pods))))))))

(defun k8s-cronjob-view-logs-at-point ()
  "Tail the logs of the most recent run of the CronJob at point.
Walks CronJob -> most recent owned Job -> most recent owned Pod
and opens its log stream (first container).  Useful even after
the Pod has completed — the kubelet keeps log files around until
the Pod is garbage-collected."
  (interactive)
  (require 'k8s-pods)
  (let ((sec (magit-current-section)))
    (unless (and sec (eq (oref sec type) 'cronjob))
      (user-error "Not on a cronjob"))
    (let* ((cj (oref sec value))
           (ns (k8s--resource-namespace cj))
           (name (k8s--resource-name cj))
           (conn (k8s--ensure-connection))
           (latest (k8s--cronjob-latest-pod conn ns name)))
      (unless latest
        (user-error "No completed runs found for CronJob %s/%s" ns name))
      (let* ((pod-name (cdr latest))
             (pod (k8s-get-resource
                   conn (format "/api/v1/namespaces/%s/pods/%s"
                                ns pod-name)))
             (containers (k8s--pod-container-names pod))
             (container (car containers)))
        (unless container
          (user-error "No containers in pod %s/%s" ns pod-name))
        (message "eltainer: tailing %s/%s[%s] (last run of CronJob %s)"
                 ns pod-name container name)
        (k8s--open-pod-log-buffer conn ns pod-name container)))))

(keymap-set k8s-cronjobs-mode-map "l" #'k8s-cronjob-view-logs-at-point)

;;; ---------------------------------------------------------------------------
;;; Multi-pod log tailing (stern-style)
;;
;; `l' on a deployment / statefulset / daemonset / job / service
;; resolves the workload's pod selector, opens a single
;; `k8s-multilog' buffer, and tails every pod's logs interleaved.
;; See docs/multipod-logs-plan.md.

(defun k8s--workload-selector (type resource)
  "Return the labelSelector alist that picks RESOURCE's pods.
TYPE is the section symbol (deployment, statefulset, …).  Returns
nil if the resource has no derivable selector."
  (let ((spec (cdr (assq 'spec resource))))
    (pcase type
      ((or 'deployment 'statefulset 'daemonset 'job)
       (cdr (assq 'matchLabels (cdr (assq 'selector spec)))))
      ('service
       (cdr (assq 'selector spec))))))

(defun k8s--multilog-at-point ()
  "Tail logs from every pod of the workload section at point.
Opens a multi-pod log buffer (`k8s-multilog-mode') — see
`k8s-multilog-start'.  Works on deployments, statefulsets,
daemonsets, jobs and services."
  (interactive)
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (resource (and sec (oref sec value))))
    (unless (memq type '(deployment statefulset daemonset job service))
      (user-error "Not on a deployment/statefulset/daemonset/job/service"))
    (let* ((ns (k8s--resource-namespace resource))
           (name (k8s--resource-name resource))
           (selector (k8s--workload-selector type resource))
           (conn (k8s--ensure-connection)))
      (unless selector
        (user-error "%s %s/%s has no labelSelector" type ns name))
      (k8s-multilog-start conn ns selector type name))))

(keymap-set k8s-deployments-mode-map  "l" #'k8s--multilog-at-point)
(keymap-set k8s-statefulsets-mode-map "l" #'k8s--multilog-at-point)
(keymap-set k8s-daemonsets-mode-map   "l" #'k8s--multilog-at-point)
(keymap-set k8s-jobs-mode-map         "l" #'k8s--multilog-at-point)
;; `services' view's mode-map is defined later in this file — the
;; binding is set after that macro call.

;;; ---------------------------------------------------------------------------
;;; Services

(defun k8s--service-ports-string (svc)
  "Return a string summarizing the ports of SVC."
  (let ((ports (cdr (assq 'ports (cdr (assq 'spec svc))))))
    (if (and ports (> (length ports) 0))
        (mapconcat
         (lambda (p)
           (let ((port (cdr (assq 'port p)))
                 (proto (or (cdr (assq 'protocol p)) "TCP"))
                 (target (cdr (assq 'targetPort p)))
                 (node-port (cdr (assq 'nodePort p))))
             (if node-port
                 (format "%s:%s→%s/%s" port node-port target proto)
               (format "%s→%s/%s" port target proto))))
         (append ports nil) ", ")
      "")))

(defvar-local k8s-services--traffic-history nil
  "Per-Services-buffer history hash for `IN/s' / `OUT/s' sparklines.
Populated by `k8s-services--traffic-tick'; consulted by
`k8s--insert-service-line' when `k8s-services-show-traffic' is non-nil.")

(defun k8s--insert-service-line (svc)
  "Insert a service summary line.
With `k8s-services-show-traffic' set (default `t'), appends
`IN/s' and `OUT/s' columns from `k8s-services--traffic-history'."
  (let* ((name (k8s--resource-name svc))
         (spec (cdr (assq 'spec svc)))
         (type (or (cdr (assq 'type spec)) "ClusterIP"))
         (cluster-ip (or (cdr (assq 'clusterIP spec)) ""))
         (ports (k8s--service-ports-string svc))
         (age (k8s--age-string (k8s--resource-creation-time svc)))
         (traffic-cells
          (and (bound-and-true-p k8s-services-show-traffic)
               k8s-services--traffic-history
               (concat
                (k8s-traffic-render-columns
                 name k8s-services--traffic-history)
                " "))))
    (magit-insert-section (service svc t)
      (magit-insert-heading
        (concat
         (format "  %-35s %-15s %-18s %-6s "
                 (propertize name 'font-lock-face 'k8s-resource-name)
                 (propertize type 'font-lock-face
                             (k8s--phase-face (if (string= type "ClusterIP")
                                                  "Active" type)))
                 cluster-ip
                 age)
         (or traffic-cells "")
         (format "%s\n" (propertize ports 'font-lock-face 'k8s-dim))))
      (let ((selector (cdr (assq 'selector spec)))
            (external-name (cdr (assq 'externalName spec))))
        (k8s--insert-selector selector "    ")
        (when external-name
          (insert (propertize (format "    External:  %s\n" external-name)
                              'font-lock-face 'k8s-dim)))
        (k8s--insert-labels (k8s--resource-labels svc) "    ")
        (insert "\n")))))

(defun k8s--services-column-header ()
  "Return the column header for the Services view, with or without
traffic columns depending on `k8s-services-show-traffic'."
  (if k8s-services-show-traffic
      (format "  %-35s %-15s %-18s %-6s %10s %10s %s\n"
              "NAME" "TYPE" "CLUSTER-IP" "AGE" "IN/s" "OUT/s" "PORTS")
    (format "  %-35s %-15s %-18s %-6s %s\n"
            "NAME" "TYPE" "CLUSTER-IP" "AGE" "PORTS")))

(k8s--define-view services
  "Major mode for viewing Kubernetes services."
  #'k8s-list-services
  (k8s--services-column-header)
  #'k8s--insert-service-line)

(keymap-set k8s-services-mode-map "l" #'k8s--multilog-at-point)
(keymap-set k8s-services-mode-map "M" #'k8s-service-traffic-at-point)

(defun k8s-service-traffic-at-point ()
  "Open the per-Service traffic dashboard for the service at point."
  (interactive)
  (let* ((sec (magit-current-section))
         (svc (and sec (eq (oref sec type) 'service) (oref sec value))))
    (unless svc (user-error "Not on a Service row"))
    (k8s-traffic-buffer
     (k8s--ensure-connection)
     (k8s--resource-namespace svc)
     (k8s--resource-name svc))))

;;; --- Background traffic poll for the Services view ------------------------

(defvar-local k8s-services--traffic-timer nil
  "Repeating timer that re-polls aggregate Service traffic.
Lives on the Services buffer; cancelled on kill-buffer.")

(defun k8s-services--traffic-tick (buf)
  "Poll one tick of aggregated Service traffic into BUF's history,
then schedule a re-render so the IN/s / OUT/s columns update."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (condition-case err
          (let* ((conn (k8s--ensure-connection))
                 (ns (or k8s--namespace
                         (k8s--connection-default-namespace conn))))
            (unless k8s-services--traffic-history
              (setq k8s-services--traffic-history
                    (make-hash-table :test 'equal)))
            (k8s-traffic-fold-into-history
             k8s-services--traffic-history
             (k8s-traffic-collect conn ns)
             (float-time))
            (revert-buffer nil t))
        (error
         (message "k8s-services traffic poll: %s"
                  (error-message-string err)))))))

(defun k8s-services--traffic-start ()
  "Kick off the traffic poll for the current Services buffer."
  (when (and k8s-services-show-traffic
             (derived-mode-p 'k8s-services-mode))
    (let ((buf (current-buffer)))
      (when (timerp k8s-services--traffic-timer)
        (cancel-timer k8s-services--traffic-timer))
      ;; Do an immediate first tick so the first poll's sample is in.
      (run-with-timer 0 nil #'k8s-services--traffic-tick buf)
      (setq k8s-services--traffic-timer
            (run-at-time k8s-metrics-refresh-interval
                         k8s-metrics-refresh-interval
                         #'k8s-services--traffic-tick buf)))))

(defun k8s-services--traffic-stop ()
  "Cancel the Services view's traffic poll timer."
  (when (timerp k8s-services--traffic-timer)
    (cancel-timer k8s-services--traffic-timer))
  (setq k8s-services--traffic-timer nil))

(add-hook 'k8s-services-mode-hook #'k8s-services--traffic-start)

;; Make sure the timer doesn't outlive the buffer.
(defun k8s-services--kill-hook ()
  (when (derived-mode-p 'k8s-services-mode)
    (k8s-services--traffic-stop)))
(add-hook 'kill-buffer-hook #'k8s-services--kill-hook)

;; Connection-helper used by the poll (one-liner if `k8s--connection'
;; has a default-namespace slot — fall back gracefully if it doesn't).
(defun k8s--connection-default-namespace (_conn)
  "Best-effort: return the namespace this connection prefers, or nil."
  (or (bound-and-true-p k8s--namespace) nil))

;;; ---------------------------------------------------------------------------
;;; Ingresses

(defun k8s--insert-ingress-line (ing)
  "Insert an ingress summary line.
Each rendered backend line carries a `k8s-jump-target' text property
\(value `(service NS NAME)') so `k8s-dwim-ret' can jump to it.
Ingress rules don't carry their own namespace — Ingress -> Service
references are always same-namespace, so we use the ingress's ns."
  (let* ((name (k8s--resource-name ing))
         (ns   (k8s--resource-namespace ing))
         (spec (cdr (assq 'spec ing)))
         (status (cdr (assq 'status ing)))
         (rules (cdr (assq 'rules spec)))
         (hosts (if (and rules (> (length rules) 0))
                    (mapconcat
                     (lambda (r) (or (cdr (assq 'host r)) "*"))
                     (append rules nil) ", ")
                  ""))
         (lb (cdr (assq 'ingress (cdr (assq 'loadBalancer status)))))
         (address (if (and lb (> (length lb) 0))
                      (or (cdr (assq 'ip (aref lb 0)))
                          (cdr (assq 'hostname (aref lb 0)))
                          "")
                    ""))
         (class (or (cdr (assq 'ingressClassName spec)) ""))
         (age (k8s--age-string (k8s--resource-creation-time ing))))
    (magit-insert-section (ingress ing t)
      (magit-insert-heading
        (format "  %-35s %-25s %-15s %-10s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize hosts 'font-lock-face 'k8s-dim)
                address
                (propertize class 'font-lock-face 'k8s-dim)
                age))
      ;; Detail: rules
      (when rules
        (seq-doseq (rule rules)
          (let ((host (or (cdr (assq 'host rule)) "*"))
                (paths (cdr (assq 'paths (cdr (assq 'http rule))))))
            (when paths
              (seq-doseq (path paths)
                (let* ((p (or (cdr (assq 'path path)) "/"))
                       (backend (cdr (assq 'backend path)))
                       (svc (cdr (assq 'service backend)))
                       (svc-name (or (cdr (assq 'name svc)) "?"))
                       (port-obj (cdr (assq 'port svc)))
                       (port-num (or (cdr (assq 'number port-obj)) "?")))
                  (insert (propertize
                           (format "    %s%s → %s:%s\n" host p svc-name port-num)
                           'font-lock-face 'k8s-dim
                           'k8s-jump-target (list 'service ns svc-name)
                           'help-echo (format "RET: jump to service %s/%s"
                                              ns svc-name)))))))))
      (k8s--insert-labels (k8s--resource-labels ing) "    ")
      (insert "\n"))))

(k8s--define-view ingresses
  "Major mode for viewing Kubernetes ingresses."
  #'k8s-list-ingresses
  (format "  %-35s %-25s %-15s %-10s %s\n" "NAME" "HOSTS" "ADDRESS" "CLASS" "AGE")
  #'k8s--insert-ingress-line)

;;; ---------------------------------------------------------------------------
;;; ConfigMaps

(defun k8s--insert-configmap-line (cm)
  "Insert a configmap summary line."
  (let* ((name (k8s--resource-name cm))
         (data (cdr (assq 'data cm)))
         (data-count (if data (length data) 0))
         (age (k8s--age-string (k8s--resource-creation-time cm))))
    (magit-insert-section (configmap cm t)
      (magit-insert-heading
        (format "  %-42s %-10s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (format "%d" data-count)
                age))
      ;; Show key names (not values — they can be huge)
      (when data
        (insert (propertize "    Keys: " 'font-lock-face 'k8s-dim))
        (let ((first t))
          (dolist (pair data)
            (unless first (insert (propertize "          " 'font-lock-face 'k8s-dim)))
            (insert (propertize (format "%s\n" (car pair))
                                'font-lock-face 'k8s-dim))
            (setq first nil))))
      (insert "\n"))))

(k8s--define-view configmaps
  "Major mode for viewing Kubernetes configmaps."
  #'k8s-list-configmaps
  (format "  %-42s %-10s %s\n" "NAME" "DATA" "AGE")
  #'k8s--insert-configmap-line)

;;; ---------------------------------------------------------------------------
;;; Secrets

(defun k8s--insert-secret-line (secret)
  "Insert a secret summary line."
  (let* ((name (k8s--resource-name secret))
         (type (or (cdr (assq 'type secret)) "Opaque"))
         (data (cdr (assq 'data secret)))
         (data-count (if data (length data) 0))
         (age (k8s--age-string (k8s--resource-creation-time secret))))
    (magit-insert-section (secret secret t)
      (magit-insert-heading
        (format "  %-35s %-40s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize type 'font-lock-face 'k8s-dim)
                (format "%d" data-count)
                age))
      ;; Show key names only (never values!)
      (when data
        (insert (propertize "    Keys: " 'font-lock-face 'k8s-dim))
        (let ((first t))
          (dolist (pair data)
            (unless first (insert (propertize "          " 'font-lock-face 'k8s-dim)))
            (insert (propertize (format "%s\n" (car pair))
                                'font-lock-face 'k8s-dim))
            (setq first nil))))
      (insert "\n"))))

(k8s--define-view secrets
  "Major mode for viewing Kubernetes secrets."
  #'k8s-list-secrets
  (format "  %-35s %-40s %-6s %s\n" "NAME" "TYPE" "DATA" "AGE")
  #'k8s--insert-secret-line)

;;; ---------------------------------------------------------------------------
;;; Sandboxes (agent-sandbox SIG — agents.x-k8s.io/v1alpha1)

(defun k8s--sandbox-ready (sandbox)
  "Return SANDBOX's readiness as a short string for the READY column.
Prefers the `Ready' condition; falls back to the latest condition's
type, or \"—\" when the status carries no conditions (e.g. the
agent-sandbox controller isn't running)."
  (let* ((conds (append (cdr (assq 'conditions
                                   (cdr (assq 'status sandbox))))
                        nil))
         (ready (seq-find (lambda (c) (equal (cdr (assq 'type c)) "Ready"))
                          conds)))
    (cond
     (ready (if (equal (cdr (assq 'status ready)) "True")
                "Ready"
              (or (cdr (assq 'reason ready)) "NotReady")))
     (conds (or (cdr (assq 'type (car (last conds)))) "—"))
     (t "—"))))

(defun k8s--insert-sandbox-line (sandbox)
  "Insert an agent-sandbox Sandbox summary line."
  (let* ((name (k8s--resource-name sandbox))
         (status (cdr (assq 'status sandbox)))
         (ready (k8s--sandbox-ready sandbox))
         (service (or (cdr (assq 'service status)) ""))
         (ips (append (cdr (assq 'podIPs status)) nil))
         (ip (or (car ips) ""))
         (age (k8s--age-string (k8s--resource-creation-time sandbox))))
    (magit-insert-section (sandbox sandbox t)
      (magit-insert-heading
        (format "  %-36s %-12s %-22s %-16s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize ready 'font-lock-face (k8s--phase-face ready))
                (propertize service 'font-lock-face 'k8s-dim)
                (propertize ip 'font-lock-face 'k8s-dim)
                age))
      (let ((fqdn (cdr (assq 'serviceFQDN status)))
            (replicas (cdr (assq 'replicas status))))
        (when fqdn
          (insert (propertize (format "    FQDN:      %s\n" fqdn)
                              'font-lock-face 'k8s-dim)))
        (when replicas
          (insert (propertize (format "    Replicas:  %s\n" replicas)
                              'font-lock-face 'k8s-dim)))
        (when (cdr ips)
          (insert (propertize (format "    Pod IPs:   %s\n"
                                      (mapconcat #'identity ips ", "))
                              'font-lock-face 'k8s-dim)))
        (seq-doseq (c (or (cdr (assq 'conditions status)) []))
          (insert (propertize
                   (format "    %-13s %s%s\n"
                           (concat (cdr (assq 'type c)) ":")
                           (cdr (assq 'status c))
                           (let ((r (cdr (assq 'reason c))))
                             (if (and r (> (length r) 0))
                                 (format "  (%s)" r) "")))
                   'font-lock-face 'k8s-dim)))
        (k8s--insert-labels (k8s--resource-labels sandbox) "    ")
        (insert "\n")))))

(k8s--define-view sandboxes
  "Major mode for viewing agent-sandbox Sandboxes."
  #'k8s-list-sandboxes
  (format "  %-36s %-12s %-22s %-16s %s\n"
          "NAME" "READY" "SERVICE" "POD IP" "AGE")
  #'k8s--insert-sandbox-line)

;;; ---------------------------------------------------------------------------
;;; HorizontalPodAutoscalers

(defun k8s--insert-hpa-line (hpa)
  "Insert an HPA summary line."
  (let* ((meta (cdr (assq 'metadata hpa)))
         (spec (cdr (assq 'spec hpa)))
         (status (cdr (assq 'status hpa)))
         (name (cdr (assq 'name meta)))
         (ref (cdr (assq 'scaleTargetRef spec)))
         (ref-str (format "%s/%s"
                          (or (cdr (assq 'kind ref)) "?")
                          (or (cdr (assq 'name ref)) "?")))
         (mn (or (cdr (assq 'minReplicas spec)) 0))
         (mx (or (cdr (assq 'maxReplicas spec)) 0))
         (curr (or (cdr (assq 'currentReplicas status)) 0))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (horizontalpodautoscaler hpa t)
      (magit-insert-heading
        (format "  %-30s %-32s %4d %4d %4d  %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize ref-str 'font-lock-face 'k8s-dim)
                mn mx curr age)))))

(k8s--define-view horizontalpodautoscalers
  "Major mode for HorizontalPodAutoscalers."
  #'k8s-list-hpas
  (format "  %-30s %-32s %4s %4s %4s  %s\n"
          "NAME" "REFERENCE" "MIN" "MAX" "CURR" "AGE")
  #'k8s--insert-hpa-line)

;;; ---------------------------------------------------------------------------
;;; PodDisruptionBudgets

(defun k8s--insert-pdb-line (pdb)
  (let* ((meta (cdr (assq 'metadata pdb)))
         (spec (cdr (assq 'spec pdb)))
         (status (cdr (assq 'status pdb)))
         (name (cdr (assq 'name meta)))
         (mn (or (cdr (assq 'minAvailable spec)) ""))
         (mx (or (cdr (assq 'maxUnavailable spec)) ""))
         (allowed (or (cdr (assq 'disruptionsAllowed status)) 0))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (poddisruptionbudget pdb t)
      (magit-insert-heading
        (format "  %-36s %-14s %-14s %12d  %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize (format "%s" mn) 'font-lock-face 'k8s-dim)
                (propertize (format "%s" mx) 'font-lock-face 'k8s-dim)
                allowed age)))))

(k8s--define-view poddisruptionbudgets
  "Major mode for PodDisruptionBudgets."
  #'k8s-list-pdbs
  (format "  %-36s %-14s %-14s %12s  %s\n"
          "NAME" "MIN-AVAILABLE" "MAX-UNAVAIL." "ALLOWED-DIS" "AGE")
  #'k8s--insert-pdb-line)

;;; ---------------------------------------------------------------------------
;;; PersistentVolumeClaims

(defun k8s--insert-pvc-line (pvc)
  (let* ((meta (cdr (assq 'metadata pvc)))
         (spec (cdr (assq 'spec pvc)))
         (status (cdr (assq 'status pvc)))
         (name (cdr (assq 'name meta)))
         (phase (or (cdr (assq 'phase status)) "?"))
         (volume (or (cdr (assq 'volumeName spec)) ""))
         (capacity (or (cdr (assq 'storage (cdr (assq 'capacity status))))
                        (cdr (assq 'storage (cdr (assq 'requests (cdr (assq 'resources spec))))))
                        "?"))
         (sc (or (cdr (assq 'storageClassName spec)) ""))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (persistentvolumeclaim pvc t)
      (magit-insert-heading
        (format "  %-30s %-10s %-30s %-10s %-22s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize phase 'font-lock-face (k8s--phase-face phase))
                (propertize volume 'font-lock-face 'k8s-dim)
                (propertize capacity 'font-lock-face 'k8s-dim)
                (propertize sc 'font-lock-face 'k8s-dim)
                age)))))

(k8s--define-view persistentvolumeclaims
  "Major mode for PersistentVolumeClaims."
  #'k8s-list-pvcs
  (format "  %-30s %-10s %-30s %-10s %-22s %s\n"
          "NAME" "STATUS" "VOLUME" "CAPACITY" "STORAGECLASS" "AGE")
  #'k8s--insert-pvc-line)

;;; ---------------------------------------------------------------------------
;;; PersistentVolumes (cluster-scoped)

(defun k8s--insert-pv-line (pv)
  (let* ((meta (cdr (assq 'metadata pv)))
         (spec (cdr (assq 'spec pv)))
         (status (cdr (assq 'status pv)))
         (name (cdr (assq 'name meta)))
         (capacity (or (cdr (assq 'storage (cdr (assq 'capacity spec))))
                        "?"))
         (modes (cdr (assq 'accessModes spec)))
         (am-str (mapconcat #'identity (append (or modes []) nil) ","))
         (reclaim (or (cdr (assq 'persistentVolumeReclaimPolicy spec)) "?"))
         (phase (or (cdr (assq 'phase status)) "?"))
         (claim-ref (cdr (assq 'claimRef spec)))
         (claim (if claim-ref
                    (format "%s/%s"
                            (cdr (assq 'namespace claim-ref))
                            (cdr (assq 'name claim-ref)))
                  ""))
         (sc (or (cdr (assq 'storageClassName spec)) ""))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (persistentvolume pv t)
      (magit-insert-heading
        (format "  %-36s %-10s %-12s %-10s %-12s %-30s %-22s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize capacity 'font-lock-face 'k8s-dim)
                (propertize am-str 'font-lock-face 'k8s-dim)
                (propertize reclaim 'font-lock-face 'k8s-dim)
                (propertize phase 'font-lock-face (k8s--phase-face phase))
                (propertize claim 'font-lock-face 'k8s-dim)
                (propertize sc 'font-lock-face 'k8s-dim)
                age)))))

(k8s--define-view persistentvolumes
  "Major mode for PersistentVolumes (cluster-scoped)."
  #'k8s-list-pvs
  (format "  %-36s %-10s %-12s %-10s %-12s %-30s %-22s %s\n"
          "NAME" "CAPACITY" "ACCESS" "RECLAIM" "STATUS" "CLAIM" "STORAGECLASS" "AGE")
  #'k8s--insert-pv-line)

;;; ---------------------------------------------------------------------------
;;; StorageClasses (cluster-scoped)

(defun k8s--insert-storageclass-line (sc)
  (let* ((meta (cdr (assq 'metadata sc)))
         (name (cdr (assq 'name meta)))
         (provisioner (or (cdr (assq 'provisioner sc)) "?"))
         (reclaim (or (cdr (assq 'reclaimPolicy sc)) "Delete"))
         (binding (or (cdr (assq 'volumeBindingMode sc)) "Immediate"))
         (allow-expand (cdr (assq 'allowVolumeExpansion sc)))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (storageclass sc t)
      (magit-insert-heading
        (format "  %-30s %-40s %-10s %-20s %-5s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize provisioner 'font-lock-face 'k8s-dim)
                (propertize reclaim 'font-lock-face 'k8s-dim)
                (propertize binding 'font-lock-face 'k8s-dim)
                (propertize (if allow-expand "yes" "no") 'font-lock-face 'k8s-dim)
                age)))))

(k8s--define-view storageclasses
  "Major mode for StorageClasses (cluster-scoped)."
  #'k8s-list-storageclasses
  (format "  %-30s %-40s %-10s %-20s %-5s %s\n"
          "NAME" "PROVISIONER" "RECLAIM" "BINDING" "EXPAND" "AGE")
  #'k8s--insert-storageclass-line)

;;; ---------------------------------------------------------------------------
;;; NetworkPolicies

(defun k8s--insert-networkpolicy-line (np)
  (let* ((meta (cdr (assq 'metadata np)))
         (spec (cdr (assq 'spec np)))
         (name (cdr (assq 'name meta)))
         (pod-sel (cdr (assq 'matchLabels (cdr (assq 'podSelector spec)))))
         (sel-str (if pod-sel
                       (mapconcat (lambda (kv)
                                    (format "%s=%s"
                                            (let ((k (car kv)))
                                              (if (symbolp k) (symbol-name k) k))
                                            (cdr kv)))
                                   pod-sel ",")
                     "(all pods)"))
         (types (cdr (assq 'policyTypes spec)))
         (types-str (mapconcat #'identity (append (or types []) nil) "+"))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (networkpolicy np t)
      (magit-insert-heading
        (format "  %-36s %-50s %-14s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize sel-str 'font-lock-face 'k8s-dim)
                (propertize types-str 'font-lock-face 'k8s-dim)
                age)))))

(k8s--define-view networkpolicies
  "Major mode for NetworkPolicies."
  #'k8s-list-networkpolicies
  (format "  %-36s %-50s %-14s %s\n"
          "NAME" "POD-SELECTOR" "TYPES" "AGE")
  #'k8s--insert-networkpolicy-line)

;;; ---------------------------------------------------------------------------
;;; RBAC views

(defun k8s--rbac--subject-summary (subjects)
  "Compactly summarise a list of RBAC subjects.
Example output: `user:alice + sa:default/foo + 2 more'."
  (let* ((subs (append (or subjects []) nil))
         (parts (mapcar
                  (lambda (s)
                    (let ((kind (cdr (assq 'kind s)))
                          (name (cdr (assq 'name s)))
                          (ns   (cdr (assq 'namespace s))))
                      (cond
                       ((equal kind "ServiceAccount")
                        (format "sa:%s/%s" (or ns "?") name))
                       ((equal kind "User")      (format "user:%s" name))
                       ((equal kind "Group")     (format "group:%s" name))
                       (t (format "%s:%s" (or kind "?") name)))))
                  subs))
         (n (length parts)))
    (cond
     ((zerop n) "")
     ((= n 1) (car parts))
     ((<= n 2) (mapconcat #'identity parts " + "))
     (t (format "%s + %d more" (car parts) (1- n))))))

(defun k8s--rbac--role-ref (ref)
  "Format a `roleRef' alist for the table."
  (format "%s/%s"
          (or (cdr (assq 'kind ref)) "?")
          (or (cdr (assq 'name ref)) "?")))

;;; --- ServiceAccounts ---

(defun k8s--insert-serviceaccount-line (sa)
  (let* ((meta (cdr (assq 'metadata sa)))
         (name (cdr (assq 'name meta)))
         (secrets (length (append (or (cdr (assq 'secrets sa)) []) nil)))
         (pulls (length (append
                          (or (cdr (assq 'imagePullSecrets sa)) []) nil)))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (serviceaccount sa t)
      (magit-insert-heading
        (format "  %-40s %-8d %-12d %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                secrets
                pulls
                age)))))

(k8s--define-view serviceaccounts
  "Major mode for ServiceAccounts."
  #'k8s-list-serviceaccounts
  (format "  %-40s %-8s %-12s %s\n"
          "NAME" "SECRETS" "PULL-SECRETS" "AGE")
  #'k8s--insert-serviceaccount-line)

;;; --- Roles ---

(defun k8s--insert-role-line (role)
  (let* ((meta (cdr (assq 'metadata role)))
         (name (cdr (assq 'name meta)))
         (rules (length (append (or (cdr (assq 'rules role)) []) nil)))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (role role t)
      (magit-insert-heading
        (format "  %-46s %-8d %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                rules
                age)))))

(k8s--define-view roles
  "Major mode for Roles (namespaced)."
  #'k8s-list-roles
  (format "  %-46s %-8s %s\n" "NAME" "RULES" "AGE")
  #'k8s--insert-role-line)

;;; --- RoleBindings ---

(defun k8s--insert-rolebinding-line (rb)
  (let* ((meta (cdr (assq 'metadata rb)))
         (name (cdr (assq 'name meta)))
         (role-ref (k8s--rbac--role-ref (cdr (assq 'roleRef rb))))
         (subjects (k8s--rbac--subject-summary (cdr (assq 'subjects rb))))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (rolebinding rb t)
      (magit-insert-heading
        (format "  %-40s %-32s %-40s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize role-ref 'font-lock-face 'eltainer-resource-secondary)
                (propertize subjects 'font-lock-face 'k8s-dim)
                age)))))

(k8s--define-view rolebindings
  "Major mode for RoleBindings (namespaced)."
  #'k8s-list-rolebindings
  (format "  %-40s %-32s %-40s %s\n"
          "NAME" "ROLE" "SUBJECTS" "AGE")
  #'k8s--insert-rolebinding-line)

;;; --- ClusterRoles ---

(defun k8s--insert-clusterrole-line (cr)
  (let* ((meta (cdr (assq 'metadata cr)))
         (name (cdr (assq 'name meta)))
         (rules (length (append (or (cdr (assq 'rules cr)) []) nil)))
         (aggr (cdr (assq 'aggregationRule cr)))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (clusterrole cr t)
      (magit-insert-heading
        (format "  %-50s %-8d %-12s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                rules
                (propertize (if aggr "aggregated" "direct")
                            'font-lock-face 'k8s-dim)
                age)))))

(k8s--define-view clusterroles
  "Major mode for ClusterRoles (cluster-scoped)."
  #'k8s-list-clusterroles
  (format "  %-50s %-8s %-12s %s\n"
          "NAME" "RULES" "MODE" "AGE")
  #'k8s--insert-clusterrole-line)

;;; --- ClusterRoleBindings ---

(defun k8s--insert-clusterrolebinding-line (crb)
  (let* ((meta (cdr (assq 'metadata crb)))
         (name (cdr (assq 'name meta)))
         (role-ref (k8s--rbac--role-ref (cdr (assq 'roleRef crb))))
         (subjects (k8s--rbac--subject-summary (cdr (assq 'subjects crb))))
         (age (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (clusterrolebinding crb t)
      (magit-insert-heading
        (format "  %-50s %-32s %-40s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize role-ref 'font-lock-face 'eltainer-resource-secondary)
                (propertize subjects 'font-lock-face 'k8s-dim)
                age)))))

(k8s--define-view clusterrolebindings
  "Major mode for ClusterRoleBindings (cluster-scoped)."
  #'k8s-list-clusterrolebindings
  (format "  %-50s %-32s %-40s %s\n"
          "NAME" "ROLE" "SUBJECTS" "AGE")
  #'k8s--insert-clusterrolebinding-line)

;;; ---------------------------------------------------------------------------
;;; Nodes (cluster-scoped — name/roles/status/version + live perf gauges)
;;
;; Bespoke rather than `k8s--define-view'-generated: nodes have no
;; namespace, so the macro's namespace grouping does not apply, and
;; the view folds in live CPU/memory/disk gauges (metrics-server +
;; kubelet) plus, when Prometheus is reachable, load averages and
;; hour-long trend sparklines.

(defvar-local k8s--nodes-cm-history nil
  "Hash NODE-NAME -> (:cpu-hist :mem-hist) for in-buffer trend sparklines.
Drives the gauge sparklines when Prometheus is unavailable; persists
across refreshes so the trend accumulates.")

(defvar-local k8s--nodes-timer nil
  "Repeating refresh timer for the current nodes buffer.")

(defun k8s--node-roles (node)
  "Return NODE's roles as a comma-joined string, or \"<none>\"."
  (let (roles)
    (dolist (pair (k8s--resource-labels node))
      (let ((k (symbol-name (car pair))))
        (when (string-prefix-p "node-role.kubernetes.io/" k)
          (push (substring k (length "node-role.kubernetes.io/")) roles))))
    (if roles (mapconcat #'identity (sort roles #'string<) ",") "<none>")))

(defun k8s--node-condition (node type)
  "Return the status string of NODE's condition TYPE, or nil."
  (catch 'found
    (seq-doseq (c (or (cdr (assq 'conditions (cdr (assq 'status node)))) []))
      (when (equal (cdr (assq 'type c)) type)
        (throw 'found (cdr (assq 'status c)))))
    nil))

(defun k8s--node-status (node)
  "Return NODE's display status: Ready / NotReady, plus SchedulingDisabled."
  (let ((ready (equal (k8s--node-condition node "Ready") "True"))
        (cordoned (eq (cdr (assq 'unschedulable (cdr (assq 'spec node)))) t)))
    (concat (if ready "Ready" "NotReady")
            (if cordoned ",SchedulingDisabled" ""))))

(defun k8s--node-address (node type)
  "Return NODE's address of TYPE (e.g. \"InternalIP\"), or nil."
  (catch 'found
    (seq-doseq (a (or (cdr (assq 'addresses (cdr (assq 'status node)))) []))
      (when (equal (cdr (assq 'type a)) type)
        (throw 'found (cdr (assq 'address a)))))
    nil))

(defun k8s--node-human-mem (qty)
  "Humanize a memory quantity string QTY (e.g. \"8141034Ki\"), or \"?\"."
  (if qty (eltainer-human-bytes (k8s-metrics--parse-memory qty)) "?"))

(defun k8s--fmt-load (n)
  "Format a load-average number N to two decimals, or \"—\" when nil."
  (if (numberp n) (format "%.2f" n) "—"))

(defun k8s--nodes-pod-counts (pods)
  "Return a hash NODE-NAME -> count of scheduled pods, from the PODS vector."
  (let ((h (make-hash-table :test 'equal)))
    (seq-doseq (p (or pods []))
      (let ((nn (cdr (assq 'nodeName (cdr (assq 'spec p))))))
        (when nn (puthash nn (1+ (gethash nn h 0)) h))))
    h))

(defun k8s--insert-node-gauges (metrics prom cm-hist)
  "Insert NODE's cpu/mem/disk gauge lines and, when present, a load line.
METRICS is the per-node plist from `k8s-metrics-collect-nodes';
PROM is the per-node Prometheus plist; CM-HIST is the in-buffer
\(:cpu-hist :mem-hist) trend plist.  Prometheus history wins over
the in-buffer trend when both exist."
  (when metrics
    (insert (eltainer-gauge-line
             "cpu" (plist-get metrics :cpu-used) (plist-get metrics :cpu-total)
             'alloc #'k8s-metrics--human-cpu
             (or (plist-get prom :cpu-hist) (plist-get cm-hist :cpu-hist))))
    (insert (eltainer-gauge-line
             "mem" (plist-get metrics :mem-used) (plist-get metrics :mem-total)
             'alloc #'eltainer-human-bytes
             (or (plist-get prom :mem-hist) (plist-get cm-hist :mem-hist))))
    (insert (eltainer-gauge-line
             "fs" (plist-get metrics :fs-used) (plist-get metrics :fs-total)
             'capacity #'eltainer-human-bytes)))
  (when prom
    (let ((l1 (plist-get prom :load1))
          (l5 (plist-get prom :load5))
          (l15 (plist-get prom :load15)))
      (when (or l1 l5 l15)
        (insert (propertize
                 (format "        load %s  %s  %s   (1m / 5m / 15m)\n"
                         (k8s--fmt-load l1) (k8s--fmt-load l5)
                         (k8s--fmt-load l15))
                 'font-lock-face 'eltainer-gauge-empty))))))

(defun k8s--insert-node-details (node metrics prom pod-count)
  "Insert the expandable detail body for NODE.
METRICS / PROM / POD-COUNT are as in `k8s--insert-node-section'."
  (let* ((status (cdr (assq 'status node)))
         (info (cdr (assq 'nodeInfo status)))
         (cap (cdr (assq 'capacity status)))
         (alloc (cdr (assq 'allocatable status)))
         (taints (cdr (assq 'taints (cdr (assq 'spec node))))))
    (insert (propertize "    Conditions: " 'font-lock-face 'k8s-dim))
    (let ((first t))
      (dolist (type '("Ready" "MemoryPressure" "DiskPressure"
                      "PIDPressure" "NetworkUnavailable"))
        (let ((st (k8s--node-condition node type)))
          (when st
            (unless first (insert "  "))
            (setq first nil)
            ;; Ready=True is healthy; a pressure condition True is not.
            (let ((good (if (equal type "Ready")
                            (equal st "True")
                          (not (equal st "True")))))
              (insert (propertize (format "%s=%s" type st)
                                  'font-lock-face
                                  (if good 'k8s-status-running
                                    'k8s-status-failed))))))))
    (insert "\n")
    (insert (propertize
             (format "    Capacity:   cpu %s   mem %s   pods %s\n"
                     (or (cdr (assq 'cpu cap)) "?")
                     (k8s--node-human-mem (cdr (assq 'memory cap)))
                     (or (cdr (assq 'pods cap)) "?"))
             'font-lock-face 'k8s-dim))
    (insert (propertize
             (format "    Pods:       %d / %s scheduled\n"
                     pod-count (or (cdr (assq 'pods alloc)) "?"))
             'font-lock-face 'k8s-dim))
    (let ((ip (k8s--node-address node "InternalIP"))
          (host (k8s--node-address node "Hostname")))
      (when (or ip host)
        (insert (propertize
                 (format "    Address:    %s%s\n"
                         (if ip (format "InternalIP %s" ip) "")
                         (if host (format "   Hostname %s" host) ""))
                 'font-lock-face 'k8s-dim))))
    (insert (propertize
             (format "    System:     %s / kernel %s / %s\n"
                     (or (cdr (assq 'osImage info)) "?")
                     (or (cdr (assq 'kernelVersion info)) "?")
                     (or (cdr (assq 'containerRuntimeVersion info)) "?"))
             'font-lock-face 'k8s-dim))
    (when (and taints (> (length taints) 0))
      (insert (propertize "    Taints:     " 'font-lock-face 'k8s-dim))
      (let (parts)
        (seq-doseq (tn taints)
          (let ((key (cdr (assq 'key tn)))
                (val (cdr (assq 'value tn)))
                (eff (cdr (assq 'effect tn))))
            (push (format "%s%s:%s" key
                          (if (and val (> (length val) 0)) (concat "=" val) "")
                          eff)
                  parts)))
        (insert (propertize (mapconcat #'identity (nreverse parts) "  ")
                            'font-lock-face 'k8s-dim)
                "\n")))
    (k8s--insert-labels (k8s--resource-labels node) "    ")
    (k8s--insert-node-gauges metrics prom
                             (and k8s--nodes-cm-history
                                  (gethash (k8s--resource-name node)
                                           k8s--nodes-cm-history)))
    (insert "\n")))

(defun k8s--insert-node-section (node metrics prom pod-count)
  "Insert a collapsible magit-section for NODE.
METRICS is NODE's plist from `k8s-metrics-collect-nodes' (or nil);
PROM is NODE's Prometheus plist (or nil); POD-COUNT is the number
of pods scheduled on it."
  (let* ((name (k8s--resource-name node))
         (roles (k8s--node-roles node))
         (status (k8s--node-status node))
         (info (cdr (assq 'nodeInfo (cdr (assq 'status node)))))
         (version (or (cdr (assq 'kubeletVersion info)) "?"))
         (age (k8s--age-string (k8s--resource-creation-time node)))
         (ready (string-prefix-p "Ready" status)))
    (magit-insert-section (node node t)
      (magit-insert-heading
        (format "  %-38s %-15s %-20s %-10s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize roles 'font-lock-face 'k8s-dim)
                (propertize status 'font-lock-face
                            (if ready 'k8s-status-running 'k8s-status-failed))
                (propertize version 'font-lock-face 'k8s-dim)
                age))
      (k8s--insert-node-details node metrics prom pod-count))))

(defun k8s--nodes-refresh ()
  "Re-fetch and re-render the nodes buffer.

The three independent fetches after the initial node list — pods (for
scheduled-count), per-node kubelet Summary (CPU/mem/fs gauges), and
the Prometheus query bundle (load avgs + history) — run *in parallel*
via `k8s--fan-out-sync'.  On a 10-node cluster this turns ~4–6 sync
round-trips into one parallel batch, dropping the 30 s tick from
seconds of UI-blocking to one round-trip's worth."
  (let* ((inhibit-read-only t)
         (ctx (k8s--save-point-context))
         (conn (k8s--ensure-connection))
         (nodes (k8s-list-nodes conn))
         (node-ips (let (out)
                     (seq-doseq (n nodes)
                       (push (cons (k8s--resource-name n)
                                   (k8s--node-address n "InternalIP"))
                             out))
                     (nreverse out)))
         (results (k8s--fan-out-sync
                   (list
                    (lambda (cb) (k8s-list-pods-async conn nil cb))
                    (lambda (cb) (k8s-metrics-collect-nodes-async
                                  conn nodes cb))
                    (lambda (cb) (k8s-prom-node-metrics-async
                                  conn node-ips cb)))))
         (pods (nth 0 results))
         (metrics-list (nth 1 results))
         (prom (nth 2 results))
         (metrics (let ((h (make-hash-table :test 'equal)))
                    (dolist (m metrics-list)
                      (puthash (plist-get m :name) m h))
                    h))
         (pod-counts (k8s--nodes-pod-counts pods)))
    (unless k8s--nodes-cm-history
      (setq k8s--nodes-cm-history (make-hash-table :test 'equal)))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-nodes-root)
      (k8s--insert-header "Nodes")
      (let ((ps (k8s-prom-status-string conn)))
        (insert (propertize "Prometheus: " 'font-lock-face 'k8s-dim)
                (if ps
                    (propertize ps 'font-lock-face 'k8s-status-running)
                  (propertize "not found — load averages + history disabled"
                              'font-lock-face 'k8s-dim))
                "\n\n"))
      (insert (propertize
               (format "  %-38s %-15s %-20s %-10s %s\n"
                       "NAME" "ROLES" "STATUS" "VERSION" "AGE")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (if (or (null nodes) (zerop (length nodes)))
          (insert (propertize "  no nodes — API unreachable.\n"
                              'font-lock-face 'k8s-dim))
        (seq-doseq (node nodes)
          (let* ((name (k8s--resource-name node))
                 (m (gethash name metrics)))
            ;; Sample cpu/mem into the in-buffer history so the trend
            ;; sparkline has data even with no Prometheus.
            (k8s-metrics-cm-sample k8s--nodes-cm-history name
                                   (and m (plist-get m :cpu-used))
                                   (and m (plist-get m :mem-used)))
            (k8s--insert-node-section
             node m (and prom (gethash name prom))
             (gethash name pod-counts 0))))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (k8s--restore-point-context ctx)))

(defvar k8s-nodes-mode-map (make-sparse-keymap)
  "Keymap for `k8s-nodes-mode'.")
(set-keymap-parent k8s-nodes-mode-map k8s-common-map)

(defun k8s--nodes-stop-timer ()
  "Cancel the nodes buffer's refresh timer."
  (when (timerp k8s--nodes-timer)
    (cancel-timer k8s--nodes-timer))
  (setq k8s--nodes-timer nil))

(define-derived-mode k8s-nodes-mode magit-section-mode "K8s:Nodes"
  "Major mode for the Kubernetes nodes view.

\\{k8s-nodes-mode-map}"
  :interactive nil
  :group 'k8s
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (k8s--nodes-refresh)))
  (add-hook 'kill-buffer-hook #'k8s--nodes-stop-timer nil t))

(defun k8s--nodes-tick (buf)
  "Refresh nodes BUF from its timer, when still live and in nodes-mode."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (derived-mode-p 'k8s-nodes-mode)
        (condition-case err
            (k8s--nodes-refresh)
          (error (message "k8s nodes: %s" (error-message-string err))))))))

(defun k8s--nodes-start-timer ()
  "(Re)start the nodes buffer's refresh timer."
  (k8s--nodes-stop-timer)
  (setq k8s--nodes-timer
        (run-at-time k8s-metrics-refresh-interval
                     k8s-metrics-refresh-interval
                     #'k8s--nodes-tick (current-buffer))))

;;;###autoload
(defun k8s-nodes ()
  "Display the cluster's nodes with live CPU / memory / disk gauges.
Each node expands (TAB) to conditions, capacity, addresses, system
info and taints.  When Prometheus is reachable, the gauges also
carry load averages and hour-long trend sparklines."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:nodes*")))
    (with-current-buffer buf
      ;; Guard the mode re-run: re-entering the major mode would
      ;; `kill-all-local-variables' and orphan the refresh timer.
      (unless (derived-mode-p 'k8s-nodes-mode)
        (k8s-nodes-mode))
      (k8s--ensure-connection)
      (k8s--nodes-refresh)
      (k8s--nodes-start-timer))
    (pop-to-buffer buf)))

(define-obsolete-function-alias 'k8s-nodes-metrics 'k8s-nodes "eltainer 0.2")

(push '("Nodes" . k8s-nodes) k8s--resource-types)

;;; ---------------------------------------------------------------------------
;;; Finalize resource type list (reverse so display order matches definition)

(setq k8s--resource-types (nreverse k8s--resource-types))

(provide 'k8s)
;;; k8s.el ends here
