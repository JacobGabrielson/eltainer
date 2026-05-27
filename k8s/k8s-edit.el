;;; k8s-edit.el --- YAML edit + apply for any resource -*- lexical-binding: t -*-
;;
;; `Y' on any resource row fetches the object via the API, drops the
;; YAML into a buffer, and applies it back with `C-c C-c'.  The
;; content-type negotiation does the YAML round-trip on the server
;; side — no in-Emacs YAML parser required.
;;
;; PUT (not PATCH) is used so the user sees exactly what's being
;; sent.  The server enforces optimistic concurrency via the
;; `metadata.resourceVersion' field in the body — if someone else
;; mutated the resource since we fetched it, the apply fails with a
;; 409 and we tell the user to refetch.

(require 'cl-lib)
(require 'docker-http)
(require 'k8s-api)
(require 'k8s-marks)
(require 'k8s)

;; yaml-mode is optional — the buffer falls back to fundamental-mode
;; with prog-mode-like indentation if it isn't installed.
(declare-function yaml-mode "yaml-mode")

(defgroup k8s-edit nil
  "YAML edit + apply for Kubernetes resources."
  :group 'k8s
  :prefix "k8s-edit-")

;;; ---------------------------------------------------------------------------
;;; HTTP helpers (YAML content-type)

(defun k8s-edit--get-yaml (conn path)
  "GET PATH and return the response body as YAML (Accept: application/yaml).
The K8s API server transcodes server-side."
  (let* ((cfg (k8s-connection-docker-cfg conn))
         (resp (docker-http-request
                cfg "GET" path
                :headers '(("Accept" . "application/yaml")))))
    (unless (docker-http-ok-p resp)
      (error "K8s edit GET %s failed [%d]: %s"
             path (docker-http-response-status resp)
             (or (docker-http-response-body resp) "")))
    (docker-http-response-body resp)))

(defun k8s-edit--put-yaml (conn path body)
  "PUT BODY (YAML string) to PATH.  Returns the response struct.
Caller is responsible for status-checking — we surface both 2xx
and the error body so the calling code can do its own UX."
  (let* ((cfg (k8s-connection-docker-cfg conn)))
    (docker-http-request
     cfg "PUT" path
     :headers '(("Content-Type" . "application/yaml")
                ("Accept" . "application/yaml"))
     :body body)))

;;; ---------------------------------------------------------------------------
;;; At-point dispatch

(defun k8s-edit--object-path (kind ns name)
  "Return the API path for resource (KIND NS NAME), or nil if
unknown.  KIND is the section-type symbol (pod / deployment / …)."
  (let ((tpl (cdr (assq kind k8s--resource-api-paths))))
    (and tpl (format tpl ns name))))

(defun k8s-edit--resource-at-point ()
  "Return (KIND NS NAME PATH) for the current line, or signal.
Reads from the magit-section's type + value."
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (val  (and sec (oref sec value))))
    (unless (and val (listp val) (assq 'metadata val))
      (user-error "Not on an editable resource row"))
    (let* ((meta (cdr (assq 'metadata val)))
           (ns   (cdr (assq 'namespace meta)))
           (name (cdr (assq 'name meta)))
           (path (k8s-edit--object-path type ns name)))
      (unless path
        (user-error "k8s-edit: no API-path template for section type %S"
                    type))
      (list type ns name path))))

;;; ---------------------------------------------------------------------------
;;; Edit buffer

(defvar-local k8s-edit--conn nil)
(defvar-local k8s-edit--path nil)
(defvar-local k8s-edit--kind nil)
(defvar-local k8s-edit--name nil)

(defun k8s-edit--maybe-yaml-mode ()
  "Drop into `yaml-mode' if available; else stay in fundamental-mode."
  (cond
   ((fboundp 'yaml-mode)
    (yaml-mode))
   (t
    (setq-local indent-tabs-mode nil)
    (setq-local tab-width 2)))
  ;; Re-bind our keymap on top of whatever mode set its own.
  (use-local-map (copy-keymap (or (current-local-map)
                                  (make-sparse-keymap))))
  (local-set-key (kbd "C-c C-c") #'k8s-edit-apply)
  (local-set-key (kbd "C-c C-k") #'kill-current-buffer))

(defun k8s-edit--insert-header (kind ns name)
  "Insert a `#'-prefixed banner explaining the edit-and-apply UX."
  (insert
   (format
    "# Editing %s %s%s
# `C-c C-c' applies via PUT (the API server enforces resourceVersion).
# `C-c C-k' cancels — kills this buffer without applying.
# Lines above the second `---' (and the YAML below it) are sent as-is.
"
    kind
    (if ns (format "%s/" ns) "")
    name))
  (insert "---\n"))

;;;###autoload
(defun k8s-edit-at-point ()
  "Open the YAML of the resource at point for editing.
`C-c C-c' applies via PUT; `C-c C-k' cancels."
  (interactive)
  (pcase-let* ((`(,kind ,ns ,name ,path) (k8s-edit--resource-at-point))
               (conn (k8s--ensure-connection))
               (yaml (k8s-edit--get-yaml conn path))
               (buf  (get-buffer-create
                      (format "*k8s:edit:%s/%s/%s*"
                              (or ns "_cluster") kind name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (k8s-edit--maybe-yaml-mode)
        (k8s-edit--insert-header kind ns name)
        (let ((header-end (point)))
          (insert yaml)
          (goto-char header-end))
        (setq k8s-edit--conn conn
              k8s-edit--path path
              k8s-edit--kind kind
              k8s-edit--name name
              ;; Don't mark the buffer modified on open.
              buffer-undo-list nil)
        (set-buffer-modified-p nil)))
    (pop-to-buffer buf)
    (message
     "%s: edit; `C-c C-c' applies, `C-c C-k' cancels"
     (buffer-name buf))))

(defun k8s-edit--strip-header ()
  "Return the YAML body of the current edit buffer with the leading
`#' comment lines + `---' separator stripped."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^---[ \t]*\n" nil t)
        (buffer-substring-no-properties (point) (point-max))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun k8s-edit-apply ()
  "Apply the current edit buffer via PUT to its source resource.
Pops a confirmation prompt summarising what's about to change."
  (interactive)
  (unless k8s-edit--path
    (user-error "Not a k8s-edit buffer"))
  (let* ((body (k8s-edit--strip-header))
         (resp (when (yes-or-no-p
                      (format "PUT %s back to the cluster? "
                              k8s-edit--path))
                 (k8s-edit--put-yaml k8s-edit--conn k8s-edit--path body))))
    (cond
     ((null resp)
      (message "k8s-edit: cancelled."))
     ((docker-http-ok-p resp)
      (message "k8s-edit: applied %s." k8s-edit--name)
      (set-buffer-modified-p nil)
      ;; Reload the edited resource into the buffer (server may have
      ;; added defaults / new resourceVersion).
      (let ((inhibit-read-only t)
            (yaml (k8s-edit--get-yaml k8s-edit--conn k8s-edit--path))
            (point (point)))
        (erase-buffer)
        (k8s-edit--maybe-yaml-mode)
        (k8s-edit--insert-header k8s-edit--kind nil k8s-edit--name)
        (insert yaml)
        (goto-char (min point (point-max)))
        (set-buffer-modified-p nil)))
     (t
      (let* ((status (docker-http-response-status resp))
             (rbody (docker-http-response-body resp)))
        (with-current-buffer (get-buffer-create "*k8s:edit:error*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "PUT %s failed [%d]\n\n%s\n"
                            k8s-edit--path status rbody))
            (goto-char (point-min))
            (special-mode)))
        (pop-to-buffer "*k8s:edit:error*")
        (message "k8s-edit: PUT failed (HTTP %d) — see *k8s:edit:error*"
                 status))))))

(provide 'k8s-edit)
;;; k8s-edit.el ends here
