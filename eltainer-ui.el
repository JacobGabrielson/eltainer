;;; eltainer-ui.el --- Shared magit-section UI scaffolding -*- lexical-binding: t -*-
;;
;; The bits both `docker.el' and `k8s.el' duplicate: status-classified
;; faces, an ISO-timestamp-to-age formatter, a length-bounded truncator,
;; and the recursive alist/vector pretty-printer the inspect buffers
;; use.  Phase C of the merge plan; see `docs/merge-emak8s.md'.
;;
;; The domain modules (`docker.el', `k8s.el') inherit from the generic
;; faces, so individual look-and-feel customizations only need to be
;; made once.  The lifecycle-state -> face dispatchers stay in each
;; module — docker says "running"/"exited", k8s says
;; "Running"/"Failed", they just hand back one of the generic faces
;; below.

(require 'cl-lib)
(require 'magit-section)

(defgroup eltainer nil
  "Shared UI primitives for the docker + k8s halves."
  :group 'tools)

;;; ---------------------------------------------------------------------------
;;; Faces

(defface eltainer-section-heading
  '((t :inherit magit-section-heading))
  "Heading face for tabular columns and inspect-buffer keys."
  :group 'eltainer)

(defface eltainer-resource-name
  '((t :inherit magit-branch-local))
  "Default face for the primary identifier in a row (container, pod, …)."
  :group 'eltainer)

(defface eltainer-resource-secondary
  '((t :inherit magit-tag))
  "Secondary identifier (image tag, namespace, …)."
  :group 'eltainer)

(defface eltainer-status-running
  '((t :inherit success))
  "`Running' / `Active' / `Bound' — happy state."
  :group 'eltainer)

(defface eltainer-status-warn
  '((t :inherit warning))
  "`Pending' / `up but degraded' — soft-yellow state."
  :group 'eltainer)

(defface eltainer-status-error
  '((t :inherit error))
  "`Exited' / `Failed' / `Terminating' — hard-red state."
  :group 'eltainer)

(defface eltainer-status-other
  '((t :inherit shadow))
  "Fallback for states we don't classify."
  :group 'eltainer)

(defface eltainer-dim
  '((t :inherit shadow))
  "Generic dim/secondary text."
  :group 'eltainer)

;;; ---------------------------------------------------------------------------
;;; Helpers

(defun eltainer-ui-age-string (timestamp)
  "Convert an ISO-8601 TIMESTAMP to a short human age string.
Returns \"5d\" / \"2h\" / \"30m\" / \"15s\".  nil → \"?\"."
  (if (null timestamp)
      "?"
    (let* ((then (float-time (date-to-time timestamp)))
           (now (float-time))
           (secs (- now then)))
      (cond
       ((< secs 60)    (format "%ds" (truncate secs)))
       ((< secs 3600)  (format "%dm" (truncate (/ secs 60))))
       ((< secs 86400) (format "%dh" (truncate (/ secs 3600))))
       (t              (format "%dd" (truncate (/ secs 86400))))))))

(defun eltainer-ui-truncate (str width)
  "Truncate STR to WIDTH chars; appends an ellipsis if it had to."
  (if (and (stringp str) (> (length str) width))
      (concat (substring str 0 (max 0 (- width 3))) "...")
    (or str "")))

(defun eltainer-ui-describe-value (value indent &optional heading-face)
  "Pretty-print VALUE (alist, vector, scalar) with INDENT spaces.
HEADING-FACE is applied to alist keys (default `eltainer-section-heading')."
  (let ((face (or heading-face 'eltainer-section-heading)))
    (cond
     ((null value)    (insert "nil\n"))
     ((stringp value) (insert value "\n"))
     ((numberp value) (insert (format "%s\n" value)))
     ((eq value t)    (insert "true\n"))
     ((vectorp value)
      (insert "\n")
      (seq-doseq (item (append value nil))
        (insert (make-string indent ?\s) "- ")
        (eltainer-ui-describe-value item (+ indent 2) face)))
     ((and (listp value) (consp (car value)))
      ;; alist
      (insert "\n")
      (dolist (pair value)
        (let ((key (format "%s" (car pair))))
          (insert (make-string indent ?\s)
                  (propertize (concat key ": ") 'font-lock-face face))
          (eltainer-ui-describe-value (cdr pair) (+ indent 2) face))))
     (t (insert (format "%S\n" value))))))

(provide 'eltainer-ui)
;;; eltainer-ui.el ends here
