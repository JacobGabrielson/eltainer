;;; k8s-crds.el --- Generic CustomResourceDefinition browser -*- lexical-binding: t -*-
;;
;; Discovers every `CustomResourceDefinition' on the cluster and
;; renders one generic view per CRD using its `additionalPrinterColumns'.
;; No code-per-CRD needed: the columns come from the CRD spec itself.
;;
;; v1 scope:
;; - Read-only list of CRDs (cluster-scoped — CRDs are cluster-scoped).
;; - RET on a CRD row drills into a list of its instances.
;; - The instance view honours the CRD's `additionalPrinterColumns'
;;   (priority 0 only; the "wide" priority-1+ columns are out of v1).
;; - Falls back to NAME + AGE when a CRD declares no printer columns.
;; - JSONPath evaluator supports the K8s subset:
;;     dotted access:  .metadata.name
;;     array index:    .status.podIPs[0].ip
;;     equality filter:  .status.conditions[?(@.type=="Ready")].status
;;   Anything else falls back to `?' in the cell.

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'eltainer-filter)
(require 'k8s-api)
(require 'k8s-marks)            ; for `k8s-common-map'
(require 'k8s)                  ; for `k8s--ensure-connection', `k8s--insert-header', etc.

(defgroup k8s-crds nil
  "Generic browser for CustomResourceDefinitions."
  :group 'k8s
  :prefix "k8s-crds-")

;;; ---------------------------------------------------------------------------
;;; JSONPath subset evaluator

(defun k8s-crds--tokenize (jp)
  "Tokenize a CRD `additionalPrinterColumns' JSONPath JP.
Returns a list of steps, each:
  (key NAME)
  (index N)
  (filter PROPERTY \"==\" VALUE)
…or nil when the path uses syntax we don't support yet."
  (let ((rest jp) tokens (ok t))
    (while (and ok (> (length rest) 0))
      (cond
       ((string-match "\\`\\.\\([A-Za-z_][A-Za-z0-9_]*\\)" rest)
        (push (list 'key (match-string 1 rest)) tokens)
        (setq rest (substring rest (match-end 0))))
       ((string-match "\\`\\[\\([0-9]+\\)\\]" rest)
        (push (list 'index (string-to-number (match-string 1 rest)))
              tokens)
        (setq rest (substring rest (match-end 0))))
       ((string-match
         "\\`\\[\\?(@\\.\\([A-Za-z_][A-Za-z0-9_]*\\)==[\"']\\([^\"']+\\)[\"'])\\]"
         rest)
        (push (list 'filter
                    (match-string 1 rest)
                    "=="
                    (match-string 2 rest))
              tokens)
        (setq rest (substring rest (match-end 0))))
       (t (setq ok nil))))
    (and ok (nreverse tokens))))

(defun k8s-crds--eval-step (step obj)
  "Apply one tokenizer STEP to OBJ; return the resolved value or nil."
  (when obj
    (pcase step
      (`(key ,k)
       (cdr (assq (intern k) obj)))
      (`(index ,i)
       (cond
        ((vectorp obj) (and (< i (length obj)) (aref obj i)))
        ((listp obj)   (nth i obj))))
      (`(filter ,prop "==" ,val)
       (let ((items (cond ((vectorp obj) (append obj nil))
                          ((listp obj)   obj))))
         (cl-find-if (lambda (item)
                       (equal (cdr (assq (intern prop) item))
                              val))
                     items))))))

(defun k8s-crds--eval-jsonpath (jp obj)
  "Evaluate JSONPath JP (a string from a CRD's `additionalPrinterColumns')
against OBJ (a resource alist).  Returns the resolved scalar or nil."
  (let ((tokens (k8s-crds--tokenize jp)))
    (when tokens
      (cl-reduce (lambda (cur step) (k8s-crds--eval-step step cur))
                 tokens :initial-value obj))))

(defun k8s-crds--render-cell (col obj)
  "Render the value for printer COL on OBJ.
COL is an alist with `name', `type', `jsonPath', and (optionally)
`priority' from `additionalPrinterColumns'.  Date type → age string."
  (let* ((path  (cdr (assq 'jsonPath col)))
         (type  (or (cdr (assq 'type col)) "string"))
         (value (and path (k8s-crds--eval-jsonpath path obj))))
    (cond
     ((null value) "")
     ((equal type "date")
      (eltainer-ui-age-render value))
     ((or (vectorp value) (consp value))
      ;; Complex nested value (we resolved to a sub-object) -- the
      ;; printer-column wanted a scalar.  Stringify lossily.
      (format "%S" value))
     (t (format "%s" value)))))

;;; ---------------------------------------------------------------------------
;;; CRD discovery

(defun k8s-crds-list (conn)
  "List every CRD on the cluster via CONN.  Returns the items vector."
  (cdr (assq 'items
             (k8s-get conn
                      "/apis/apiextensions.k8s.io/v1/customresourcedefinitions"))))

(defun k8s-crds--active-version (crd)
  "Return the (alist) active version of CRD — the one served *and*
selected for storage.  Falls back to the first served version."
  (let* ((versions (append (cdr (assq 'versions
                                       (cdr (assq 'spec crd))))
                           nil)))
    (or (cl-find-if (lambda (v)
                      (and (eq (cdr (assq 'served v)) t)
                           (eq (cdr (assq 'storage v)) t)))
                    versions)
        (cl-find-if (lambda (v) (eq (cdr (assq 'served v)) t)) versions)
        (car versions))))

(defun k8s-crds--printer-columns (crd)
  "Return the priority-0 `additionalPrinterColumns' for CRD's active version.
Filtering out priority > 0 keeps the row width sane; users can drop
into describe (`i') for the wide columns."
  (let* ((v (k8s-crds--active-version crd))
         (cols (append (cdr (assq 'additionalPrinterColumns v)) nil)))
    (cl-remove-if (lambda (c)
                    (let ((p (cdr (assq 'priority c))))
                      (and p (> p 0))))
                  cols)))

(defun k8s-crds--list-path (crd &optional namespace)
  "Return the API list path for instances of CRD.
NAMESPACE only used when the CRD is namespaced; ignored otherwise.
Encodes any active label-selector from `eltainer-filter--state'."
  (let* ((spec (cdr (assq 'spec crd)))
         (group (cdr (assq 'group spec)))
         (plural (cdr (assq 'plural (cdr (assq 'names spec)))))
         (scope (cdr (assq 'scope spec)))
         (version (cdr (assq 'name (k8s-crds--active-version crd))))
         (base
          (if (and (equal scope "Namespaced") namespace)
              (format "/apis/%s/%s/namespaces/%s/%s"
                      group version namespace plural)
            (format "/apis/%s/%s/%s" group version plural)))
         (label-sel (and (bound-and-true-p eltainer-filter--state)
                         (eltainer-filter-label-selector
                          eltainer-filter--state))))
    (if (and label-sel (not (string-empty-p label-sel)))
        (format "%s?labelSelector=%s"
                base (url-hexify-string label-sel))
      base)))

(defun k8s-crds--list-instances (conn crd &optional namespace)
  "Return the items vector of instances of CRD via CONN.
NAMESPACE is honoured only for `scope: Namespaced' CRDs."
  (let ((path (k8s-crds--list-path crd namespace)))
    (cdr (assq 'items
               (condition-case err
                   (k8s-get conn path)
                 (error
                  (message "k8s-crds: GET %s failed: %s"
                           path (error-message-string err))
                  nil))))))

;;; ---------------------------------------------------------------------------
;;; The CRD listing view

(defvar-local k8s-crds--crd-cache nil
  "All CRDs from the cluster, cached on the listing buffer.")

(defun k8s-crds--insert-crd-line (crd)
  "One row of the CRDs listing: NAME / GROUP / SCOPE / KIND / AGE."
  (let* ((meta (cdr (assq 'metadata crd)))
         (spec (cdr (assq 'spec crd)))
         (name (cdr (assq 'name meta)))
         (group (cdr (assq 'group spec)))
         (scope (cdr (assq 'scope spec)))
         (kind (cdr (assq 'kind (cdr (assq 'names spec)))))
         (age  (k8s--age-string (cdr (assq 'creationTimestamp meta)))))
    (magit-insert-section (crd crd t)
      (magit-insert-heading
        (format "  %-45s %-30s %-12s %-22s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize group 'font-lock-face 'k8s-dim)
                (propertize scope 'font-lock-face
                            (if (equal scope "Namespaced")
                                'eltainer-status-running
                              'k8s-dim))
                (propertize kind 'font-lock-face 'k8s-dim)
                age)))))

(defun k8s-crds--group-by-group (crds)
  "Group CRDS by their `.spec.group' for tabular display."
  (let ((tbl (make-hash-table :test 'equal)))
    (seq-doseq (crd crds)
      (let ((g (cdr (assq 'group (cdr (assq 'spec crd))))))
        (push crd (gethash g tbl nil))))
    (let (out)
      (maphash (lambda (g vs) (push (cons g (nreverse vs)) out)) tbl)
      (sort out (lambda (a b) (string< (car a) (car b)))))))

(defun k8s--crds-refresh ()
  "Refresh the CRDs buffer.
Honours the active `eltainer-filter''s name-regex client-side."
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (crds (k8s-crds-list conn))
         (filter eltainer-filter--state)
         (crds (if (and filter
                        (let ((nr (eltainer-filter-name-regex filter)))
                          (and nr (not (string-empty-p nr)))))
                   (seq-filter
                    (lambda (c)
                      (eltainer-filter-match-name-p
                       filter (cdr (assq 'name (cdr (assq 'metadata c))))))
                    crds)
                 crds))
         (groups (k8s-crds--group-by-group crds)))
    (setq k8s-crds--crd-cache crds)
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-root)
      (k8s--insert-header "CRDs")
      (insert (propertize
               (format "  %-45s %-30s %-12s %-22s %s\n"
                       "NAME" "GROUP" "SCOPE" "KIND" "AGE")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (if (null crds)
          (insert (propertize "  (no CRDs installed)\n"
                              'font-lock-face 'k8s-dim))
        (dolist (group groups)
          (magit-insert-section (group (car group))
            (magit-insert-heading
              (propertize (format "%s (%d)\n"
                                  (if (string-empty-p (car group))
                                      "(core)"
                                    (car group))
                                  (length (cdr group)))
                          'font-lock-face 'k8s-namespace))
            (dolist (item (cdr group))
              (k8s-crds--insert-crd-line item))
            (insert "\n")))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))))

(defun k8s-crds--crd-at-point ()
  "Return the CRD alist on the current line, or signal."
  (let ((sec (magit-current-section)))
    (unless (and sec (eq (oref sec type) 'crd))
      (user-error "Not on a CRD row"))
    (oref sec value)))

(defun k8s-crds-instances-at-point ()
  "Drill into the CRD on the current line: list its instances."
  (interactive)
  (k8s-crd-instances (k8s-crds--crd-at-point)))

;;; --- Major mode for the CRDs listing -------------------------------------

(defvar k8s-crds-mode-map (make-sparse-keymap)
  "Keymap for `k8s-crds-mode'.")
(set-keymap-parent k8s-crds-mode-map k8s-common-map)
(keymap-set k8s-crds-mode-map "RET" #'k8s-crds-instances-at-point)

(define-derived-mode k8s-crds-mode magit-section-mode "K8s:CRDs"
  "Read-only listing of every CustomResourceDefinition on the cluster.

\\{k8s-crds-mode-map}"
  :interactive nil
  :group 'k8s-crds
  (setq-local revert-buffer-function
              (lambda (_ig _nc) (k8s--crds-refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              '(:eval (k8s--filter-mode-line)) "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces)))

;;;###autoload
(defun k8s-crds ()
  "Browse every CRD installed on the active cluster."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:crds*")))
    (with-current-buffer buf
      (k8s-crds-mode)
      (k8s--ensure-connection)
      (k8s--crds-refresh))
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Per-CRD instance view

(defvar-local k8s-crd-instances--crd nil
  "The CRD this instance buffer is showing (alist).")

(defun k8s-crd-instances--column-header (crd)
  "Return the column header for instances of CRD."
  (let ((cols (k8s-crds--printer-columns crd)))
    (concat
     "  "
     (format "%-40s " "NAME")
     (mapconcat (lambda (c)
                  (format "%-20s" (or (cdr (assq 'name c)) "?")))
                cols
                "")
     (unless (cl-find-if (lambda (c)
                           (equal (downcase (or (cdr (assq 'name c)) ""))
                                  "age"))
                         cols)
       "AGE")
     "\n")))

(defun k8s-crd-instances--insert-line (obj cols crd-scope)
  "Insert one instance line for OBJ using COLS (printer columns)."
  (let* ((meta (cdr (assq 'metadata obj)))
         (name (cdr (assq 'name meta)))
         (ns   (cdr (assq 'namespace meta)))
         (age  (k8s--age-string (cdr (assq 'creationTimestamp meta))))
         (own-age-col (cl-find-if (lambda (c)
                                    (equal (downcase
                                            (or (cdr (assq 'name c)) ""))
                                           "age"))
                                  cols))
         (display-name (if (and (equal crd-scope "Namespaced") ns)
                           (format "%s/%s" ns name)
                         name)))
    (magit-insert-section (crd-instance obj t)
      (magit-insert-heading
        (concat
         "  "
         (propertize (format "%-40s " display-name)
                     'font-lock-face 'k8s-resource-name)
         (mapconcat (lambda (c)
                      (format "%-20s"
                              (k8s-crds--render-cell c obj)))
                    cols
                    "")
         (unless own-age-col
           (concat age))
         "\n")))))

(defun k8s-crd-instances--refresh ()
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (crd k8s-crd-instances--crd)
         (spec (cdr (assq 'spec crd)))
         (scope (cdr (assq 'scope spec)))
         (kind (cdr (assq 'kind (cdr (assq 'names spec)))))
         (group (cdr (assq 'group spec)))
         (ns (and (equal scope "Namespaced")
                  (or k8s--namespace nil)))
         (cols (k8s-crds--printer-columns crd))
         (items (k8s-crds--list-instances conn crd ns))
         (filter eltainer-filter--state)
         (items (if (and filter
                         (let ((nr (eltainer-filter-name-regex filter)))
                           (and nr (not (string-empty-p nr)))))
                    (seq-filter
                     (lambda (it)
                       (eltainer-filter-match-name-p
                        filter (k8s--resource-name it)))
                     items)
                  items)))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-root)
      (k8s--insert-header (format "%s.%s" kind group))
      (insert (propertize (k8s-crd-instances--column-header crd)
                          'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (if (or (null items) (zerop (length items)))
          (insert (propertize (format "  (no %s found%s)\n"
                                      kind (if ns (format " in %s" ns) ""))
                              'font-lock-face 'k8s-dim))
        (seq-doseq (it items)
          (k8s-crd-instances--insert-line it cols scope))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))))

(defvar k8s-crd-instances-mode-map (make-sparse-keymap)
  "Keymap for `k8s-crd-instances-mode'.")
(set-keymap-parent k8s-crd-instances-mode-map k8s-common-map)

(define-derived-mode k8s-crd-instances-mode magit-section-mode "K8s:CRD"
  "Read-only listing of one CRD's instances.

\\{k8s-crd-instances-mode-map}"
  :interactive nil
  :group 'k8s-crds
  (setq-local revert-buffer-function
              (lambda (_ig _nc) (k8s-crd-instances--refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              '(:eval (k8s--filter-mode-line)) "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces)))

;;;###autoload
(defun k8s-crd-instances (crd)
  "Open a buffer listing every instance of CRD."
  (interactive)
  (let* ((spec (cdr (assq 'spec crd)))
         (group (cdr (assq 'group spec)))
         (plural (cdr (assq 'plural (cdr (assq 'names spec)))))
         (buf (get-buffer-create
               (format "*k8s:crd:%s.%s*" plural group))))
    (with-current-buffer buf
      (k8s-crd-instances-mode)
      (k8s--ensure-connection)
      (setq k8s-crd-instances--crd crd)
      (k8s-crd-instances--refresh))
    (pop-to-buffer buf)))

(provide 'k8s-crds)
;;; k8s-crds.el ends here
