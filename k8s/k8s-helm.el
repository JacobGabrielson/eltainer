;;; k8s-helm.el --- Helm 3 release view (read-only) -*- lexical-binding: t -*-
;;
;; Helm 3 stores each release revision as a Secret in its namespace,
;; labelled `owner=helm,name=<release>,status=<state>,version=<rev>'.
;; The Secret's `data.release' field is a base64 (transport) of a
;; base64 (helm encoding) of a gzipped JSON release document.
;;
;; That means we can list, inspect, and decode releases without ever
;; touching the `helm' CLI — straight through the K8s API.  v1 is
;; read-only (list / values / manifest).  Upgrade / rollback /
;; uninstall would need template rendering (Go templates + sprig
;; functions) which Elisp can't reproduce cleanly; defer to v2.
;;
;; Design: docs/helm-plan.md.

(require 'cl-lib)
(require 'json)
(require 'magit-section)
(require 'eltainer-ui)
(require 'k8s-api)
(require 'k8s)

;; Cross-module references — declared so byte-compile is quiet.
(declare-function k8s-common-map "k8s-marks")

;;; ---------------------------------------------------------------------------
;;; Release decoder
;;
;; The transport: API server -> base64(helm-encoded-blob) ; the inner
;; encoding (helm/pkg/storage/driver/util.go): base64(gzip(json)).  Two
;; nested base64 plus a gzip — straightforward to undo with the
;; built-in primitives.

(defun k8s-helm--gunzip-string (gzipped)
  "Decompress GZIPPED unibyte string and return the inflated bytes.
Uses Emacs's built-in `zlib-decompress-region', which understands
the gzip wrapper as well as raw deflate."
  (unless (fboundp 'zlib-decompress-region)
    (error "k8s-helm: this Emacs has no zlib support"))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert gzipped)
    (unless (zlib-decompress-region (point-min) (point-max))
      (error "k8s-helm: zlib-decompress-region failed"))
    (buffer-string)))

(defun k8s-helm--decode-release (data-field)
  "Decode the `data.release' DATA-FIELD of a Helm release secret.
Returns the release alist.  Signals if any layer doesn't decode."
  ;; data-field as returned by `k8s-get' on a Secret is the
  ;; transport-base64 string the API server emitted.
  (let* ((once   (base64-decode-string data-field))
         (twice  (base64-decode-string once))
         (gz-decoded (k8s-helm--gunzip-string twice))
         (json-object-type 'alist)
         (json-array-type 'vector)
         (json-key-type 'symbol))
    (json-read-from-string gz-decoded)))

(defun k8s-helm--decode-secret (secret)
  "Return the decoded release alist for SECRET, or nil if not Helm.
SECRET is the alist as returned by the K8s API list call."
  (let* ((meta (cdr (assq 'metadata secret)))
         (labels (cdr (assq 'labels meta)))
         (data (cdr (assq 'data secret)))
         (release (cdr (assq 'release data))))
    (when (and release
               (equal "helm" (cdr (assq 'owner labels))))
      (condition-case err
          (k8s-helm--decode-release release)
        (error
         (message "k8s-helm: failed to decode %s/%s: %s"
                  (cdr (assq 'namespace meta))
                  (cdr (assq 'name meta))
                  (error-message-string err))
         nil)))))

;;; ---------------------------------------------------------------------------
;;; Release listing
;;
;; We want one row per release — the *current* revision.  Helm sets
;; `status=deployed' (or `failed' / `pending-*' / `uninstalled') on
;; the live revision and `status=superseded' on the older ones.  The
;; cleanest single-shot fetch: `?labelSelector=owner=helm,status!=superseded'.

(defconst k8s-helm--active-label-selector
  "owner=helm,status!=superseded"
  "Label selector that returns one Secret per Helm release (the
current revision, never the older superseded ones).")

(defun k8s-helm-list-releases (conn &optional namespace)
  "Return the list of decoded release alists in NAMESPACE via CONN.
NAMESPACE nil means cluster-wide.  Filters server-side via the
helm-owner label so we don't drag every secret in the cluster."
  (let* ((path (k8s--list-path 'secrets namespace
                               k8s-helm--active-label-selector))
         (items (cdr (assq 'items (k8s-get conn path))))
         (out nil))
    (seq-doseq (s items)
      (let ((rel (k8s-helm--decode-secret s)))
        (when rel
          ;; Attach the source secret's metadata so the view can show
          ;; the secret's creation-time as the release's age.
          (push (cons (cons 'secret-metadata
                            (cdr (assq 'metadata s)))
                      rel)
                out))))
    (nreverse out)))

;;; ---------------------------------------------------------------------------
;;; Field accessors (on the decoded release alist)

(defun k8s-helm--rel-name (rel)        (cdr (assq 'name rel)))
(defun k8s-helm--rel-namespace (rel)   (cdr (assq 'namespace rel)))
(defun k8s-helm--rel-version (rel)     (cdr (assq 'version rel)))
(defun k8s-helm--rel-info (rel)        (cdr (assq 'info rel)))
(defun k8s-helm--rel-status (rel)
  (cdr (assq 'status (k8s-helm--rel-info rel))))
(defun k8s-helm--rel-notes (rel)
  (cdr (assq 'notes (k8s-helm--rel-info rel))))
(defun k8s-helm--rel-chart-name (rel)
  (cdr (assq 'name
             (cdr (assq 'metadata (cdr (assq 'chart rel)))))))
(defun k8s-helm--rel-chart-version (rel)
  (cdr (assq 'version
             (cdr (assq 'metadata (cdr (assq 'chart rel)))))))
(defun k8s-helm--rel-chart-app-version (rel)
  (cdr (assq 'appVersion
             (cdr (assq 'metadata (cdr (assq 'chart rel)))))))
(defun k8s-helm--rel-values (rel)      (cdr (assq 'config rel)))
(defun k8s-helm--rel-manifest (rel)    (cdr (assq 'manifest rel)))
(defun k8s-helm--rel-secret-creation (rel)
  (cdr (assq 'creationTimestamp (cdr (assq 'secret-metadata rel)))))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defface k8s-helm-status-deployed '((t :inherit success))
  "Status face for a healthy `deployed' Helm release."
  :group 'k8s)

(defface k8s-helm-status-failed '((t :inherit error))
  "Status face for a `failed' Helm release."
  :group 'k8s)

(defface k8s-helm-status-other '((t :inherit warning))
  "Status face for pending / unknown Helm release states."
  :group 'k8s)

(defun k8s-helm--status-face (status)
  (cond
   ((equal status "deployed") 'k8s-helm-status-deployed)
   ((equal status "failed")   'k8s-helm-status-failed)
   (t                          'k8s-helm-status-other)))

(defconst k8s-helm--column-header
  (format "  %-25s %-3s %-12s %-25s %-12s %s\n"
          "NAME" "REV" "STATUS" "CHART" "APP" "AGE")
  "Column titles for the helm view.")

(defun k8s-helm--insert-line (rel)
  "Insert one row for RELEASE."
  (let* ((name    (k8s-helm--rel-name rel))
         (rev     (or (k8s-helm--rel-version rel) "?"))
         (status  (or (k8s-helm--rel-status rel) "?"))
         (chart   (format "%s-%s"
                          (or (k8s-helm--rel-chart-name rel) "?")
                          (or (k8s-helm--rel-chart-version rel) "?")))
         (app     (or (k8s-helm--rel-chart-app-version rel) "?"))
         (age     (k8s--age-string (k8s-helm--rel-secret-creation rel))))
    (magit-insert-section (helm-release rel t)
      (magit-insert-heading
        (format "  %-25s %-3s %-12s %-25s %-12s %s\n"
                (propertize (or name "?") 'font-lock-face 'k8s-resource-name)
                (format "%s" rev)
                (propertize status 'font-lock-face
                            (k8s-helm--status-face status))
                (propertize chart 'font-lock-face 'k8s-dim)
                (propertize app 'font-lock-face 'k8s-dim)
                age))
      ;; Detail: NOTES.txt if any.
      (let ((notes (k8s-helm--rel-notes rel)))
        (when (and notes (not (string-empty-p notes)))
          (insert (propertize "    NOTES:\n" 'font-lock-face 'k8s-section-heading))
          (dolist (line (split-string notes "\n"))
            (insert (propertize (concat "      " line "\n")
                                'font-lock-face 'k8s-dim)))))
      (insert "\n"))))

(defun k8s--helm-refresh ()
  "Refresh the helm releases buffer."
  (let* ((inhibit-read-only t)
         (ctx (k8s--save-point-context))
         (conn (k8s--ensure-connection))
         (releases (k8s-helm-list-releases conn k8s--namespace))
         ;; group by namespace for visual parity with other views
         (grouped (k8s--group-by-namespace
                   (apply #'vector
                          (mapcar
                           (lambda (rel)
                             ;; Synthesise a `metadata' alist so the
                             ;; existing `k8s--group-by-namespace' (and
                             ;; `k8s--resource-namespace') just work.
                             (let ((ns (k8s-helm--rel-namespace rel)))
                               (cons (cons 'metadata
                                           (list (cons 'name (k8s-helm--rel-name rel))
                                                 (cons 'namespace ns)))
                                     rel)))
                           releases)))))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-root)
      (k8s--insert-header "Helm")
      (insert (propertize k8s-helm--column-header
                          'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (if (null releases)
          (insert (propertize "  (no helm releases found)\n"
                              'font-lock-face 'k8s-dim))
        (dolist (group grouped)
          (magit-insert-section (namespace (car group))
            (k8s--insert-namespace-heading (car group) (length (cdr group)))
            (dolist (item (cdr group))
              ;; The grouped items carry the synthesised metadata
              ;; wrapper — unwrap to get the original release alist.
              (k8s-helm--insert-line (cdr item)))
            (insert "\n")))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (k8s--restore-point-context ctx)))

;;; ---------------------------------------------------------------------------
;;; Per-release actions

(defun k8s-helm--release-at-point ()
  "Return the release alist on the current line, or signal."
  (let ((sec (magit-current-section)))
    (unless (and sec (eq (oref sec type) 'helm-release))
      (user-error "Not on a Helm release row"))
    (oref sec value)))

(defun k8s-helm-view-values ()
  "Pop a read-only buffer showing the current release's values.yaml."
  (interactive)
  (let* ((rel (k8s-helm--release-at-point))
         (values (k8s-helm--rel-values rel))
         (name (k8s-helm--rel-name rel))
         (buf (get-buffer-create (format "*k8s:helm:%s:values*" name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (with-temp-buffer
                  (eltainer-ui-describe-value (or values "{}") 0)
                  (buffer-string)))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buf)))

(defun k8s-helm-view-manifest ()
  "Pop a read-only buffer showing the current release's rendered manifest."
  (interactive)
  (let* ((rel (k8s-helm--release-at-point))
         (manifest (k8s-helm--rel-manifest rel))
         (name (k8s-helm--rel-name rel))
         (buf (get-buffer-create (format "*k8s:helm:%s:manifest*" name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or manifest "(no rendered manifest)"))
        (goto-char (point-min))
        (special-mode)
        (when (fboundp 'yaml-mode) (yaml-mode))))
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar k8s-helm-mode-map (make-sparse-keymap)
  "Keymap for `k8s-helm-mode'.")
(set-keymap-parent k8s-helm-mode-map k8s-common-map)
(pcase-dolist (`(,k ,cmd) '(("v" k8s-helm-view-values)
                             ("m" k8s-helm-view-manifest)))
  (keymap-set k8s-helm-mode-map k cmd))

(define-derived-mode k8s-helm-mode magit-section-mode "K8s:Helm"
  "Read-only view of Helm 3 releases.

Decodes each release's Secret directly (`owner=helm' label) — no
`helm' CLI shelled out.  `v' views the release's values.yaml; `m'
views the rendered manifest; `g' refreshes.

\\{k8s-helm-mode-map}"
  :interactive nil
  :group 'k8s
  (setq-local revert-buffer-function
              (lambda (_ignore _noconfirm) (k8s--helm-refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              '(:eval (k8s--filter-mode-line)) "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces)))

;;;###autoload
(defun k8s-helm ()
  "Open the read-only Helm releases view."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:helm*")))
    (with-current-buffer buf
      (k8s-helm-mode)
      (k8s--ensure-connection)
      (k8s--helm-refresh))
    (pop-to-buffer buf)))

(provide 'k8s-helm)
;;; k8s-helm.el ends here
