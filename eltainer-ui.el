;;; eltainer-ui.el --- Shared magit-section UI scaffolding -*- lexical-binding: t -*-
;;
;; The bits both `docker.el' and `k8s.el' duplicate: status-classified
;; faces, an ISO-timestamp-to-age formatter, a length-bounded truncator,
;; and the recursive alist/vector pretty-printer the inspect buffers
;; use.
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

;; Age-tier faces.  The boundaries (1h / 1d / 1w / 30d) map to the
;; five faces below.  Very fresh resources draw attention because
;; "just started" often means "still stabilising" or "just deployed";
;; old ones dim out because they're the boring background.

(defface eltainer-age-very-new
  '((t :inherit warning))
  "Age < 1 hour.  Default: yellow / orange — \"just appeared\"."
  :group 'eltainer)

(defface eltainer-age-new
  '((t :inherit success))
  "Age < 1 day.  Default: green — recent but settled."
  :group 'eltainer)

(defface eltainer-age-medium
  '((t :inherit default))
  "Age 1 day to 1 week.  Default: foreground colour."
  :group 'eltainer)

(defface eltainer-age-old
  '((t :inherit shadow))
  "Age 1 week to 30 days.  Default: dim."
  :group 'eltainer)

(defface eltainer-age-ancient
  '((t :inherit shadow :weight light))
  "Age >= 30 days.  Default: dim + light weight."
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

(defun eltainer-ui-age-face (timestamp)
  "Return the age-tier face appropriate for ISO-8601 TIMESTAMP.
Tier boundaries: 1h / 1d / 1w / 30d.  nil → `eltainer-dim'.
Used by callers that propertise the result of
`eltainer-ui-age-string'."
  (if (null timestamp)
      'eltainer-dim
    (let* ((then (float-time (date-to-time timestamp)))
           (secs (- (float-time) then)))
      (cond
       ((< secs 3600)         'eltainer-age-very-new)
       ((< secs 86400)        'eltainer-age-new)
       ((< secs 604800)       'eltainer-age-medium)
       ((< secs 2592000)      'eltainer-age-old)
       (t                     'eltainer-age-ancient)))))

(defun eltainer-ui-age-render (timestamp)
  "Format TIMESTAMP as a propertised age string with the tier face.
Convenience for the common pattern of `(propertize (age-string …)
\\='font-lock-face (age-face …))'."
  (propertize (eltainer-ui-age-string timestamp)
              'font-lock-face (eltainer-ui-age-face timestamp)))

(defun eltainer-ui-bytes-rate (n)
  "Format N bytes/second with a decimal-unit suffix (KB/s, MB/s, ...).
Decimal units match what network tools (`iftop`, `nload`, cloud
metrics dashboards) consistently use for throughput — even when
they use binary units for storage.  nil → \"?\"."
  (cond
   ((not (numberp n)) "?")
   ((< n 1000)              (format "%dB/s"   (truncate n)))
   ((< n 1000000)           (format "%.1fKB/s" (/ n 1000.0)))
   ((< n 1000000000)        (format "%.1fMB/s" (/ n 1000000.0)))
   (t                       (format "%.2fGB/s" (/ n 1000000000.0)))))

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
      (seq-doseq (item value)
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
