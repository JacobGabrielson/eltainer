;;; eltainer-gauge.el --- Text gauges + sparklines for eltainer -*- lexical-binding: t -*-
;;
;; Backend-agnostic rendering primitives shared by the Kubernetes and
;; Docker metrics code: a 1/8-cell-precision bar gauge, a block-element
;; sparkline, a byte humanizer, a gauge-line formatter, and a
;; ring-buffer helper for trend history.  Pure text + faces — no images,
;; no package dependencies.
;;
;; Extracted from k8s-metrics.el so docker-metrics.el can reuse it
;; without a cross-dependency on the k8s side.

(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup eltainer-gauge nil
  "Text gauges and sparklines for eltainer's metrics views."
  :group 'eltainer)

(defcustom eltainer-gauge-width 16
  "Width, in characters, of a usage gauge bar (excluding end-caps)."
  :type 'integer
  :group 'eltainer-gauge)

(defcustom eltainer-gauge-style 'blocks
  "How to draw gauge bars.
`blocks' uses Unicode block elements with 1/8-cell precision;
`ascii' uses plain `#' / `-' for fonts or terminals without the
block glyphs."
  :type '(choice (const blocks) (const ascii))
  :group 'eltainer-gauge)

(defcustom eltainer-gauge-history-length 24
  "How many recent samples to keep in a trend ring buffer.
Sparklines draw (up to) this many points."
  :type 'integer
  :group 'eltainer-gauge)

(defconst eltainer-gauge--mid-threshold 0.70
  "Fraction at/above which a gauge turns from low to mid colour.")

(defconst eltainer-gauge--high-threshold 0.90
  "Fraction at/above which a gauge turns to the high colour.")

;;; ---------------------------------------------------------------------------
;;; Faces

(defface eltainer-gauge-low '((t :inherit success))
  "Face for the filled part of a gauge below the mid threshold."
  :group 'eltainer-gauge)

(defface eltainer-gauge-mid '((t :inherit warning))
  "Face for the filled part of a gauge in the mid band."
  :group 'eltainer-gauge)

(defface eltainer-gauge-high '((t :inherit error))
  "Face for the filled part of a gauge over the high threshold."
  :group 'eltainer-gauge)

(defface eltainer-gauge-empty '((t :inherit shadow))
  "Face for the unfilled track of a gauge, and for dim gauge text."
  :group 'eltainer-gauge)

;;; ---------------------------------------------------------------------------
;;; Humanizer

(defun eltainer-human-bytes (n)
  "Format N bytes with a binary-unit suffix, e.g. \"218Mi\"."
  (cond
   ((not (numberp n)) "?")
   ((< n 1024) (format "%dB" n))
   ((< n (* 1024 1024)) (format "%dKi" (round (/ n 1024.0))))
   ((< n (* 1024 1024 1024))
    (format "%dMi" (round (/ n (* 1024.0 1024)))))
   (t (format "%.1fGi" (/ n (* 1024.0 1024 1024))))))

;;; ---------------------------------------------------------------------------
;;; Gauge bar

(defun eltainer-gauge--face (fraction)
  "Return the gauge face for FRACTION (0.0..1.0)."
  (cond
   ((>= fraction eltainer-gauge--high-threshold) 'eltainer-gauge-high)
   ((>= fraction eltainer-gauge--mid-threshold)  'eltainer-gauge-mid)
   (t 'eltainer-gauge-low)))

(defun eltainer-gauge--bar (fraction width)
  "Return a propertized WIDTH-cell bar string for FRACTION (0.0..1.0)."
  (let* ((f (max 0.0 (min 1.0 (or fraction 0.0))))
         (face (eltainer-gauge--face f)))
    (pcase eltainer-gauge-style
      ('ascii
       (let ((full (round (* f width))))
         (concat (propertize (make-string full ?#) 'font-lock-face face)
                 (propertize (make-string (- width full) ?-)
                             'font-lock-face 'eltainer-gauge-empty))))
      (_
       (let* ((eighths (round (* f width 8)))
              (full (/ eighths 8))
              (rem (% eighths 8))
              (parts ["" "▏" "▎" "▍" "▌" "▋" "▊" "▉"])
              (filled (concat (make-string full ?█)
                              (unless (zerop rem) (aref parts rem))))
              (empty (make-string (max 0 (- width (length filled))) ?░)))
         (concat (propertize filled 'font-lock-face face)
                 (propertize empty 'font-lock-face 'eltainer-gauge-empty)))))))

(defun eltainer-gauge (fraction)
  "Return a complete gauge string (end-caps + bar) for FRACTION."
  (concat (propertize "▏" 'font-lock-face 'eltainer-gauge-empty)
          (eltainer-gauge--bar fraction eltainer-gauge-width)
          (propertize "▕" 'font-lock-face 'eltainer-gauge-empty)))

;;; ---------------------------------------------------------------------------
;;; Sparkline

(defun eltainer-sparkline (values &optional width)
  "Render VALUES (numbers, oldest first) as a block-character sparkline.
WIDTH caps to the most-recent values.  Bars scale to the window
peak, so the shape stays legible at any throughput."
  (if (null values)
      ""
    (let* ((bars "▁▂▃▄▅▆▇█")
           (vs (if (and width (> (length values) width))
                   (last values width)
                 values))
           (peak (apply #'max 1.0 (mapcar #'float vs))))
      (mapconcat
       (lambda (v)
         (char-to-string
          (aref bars (min 7 (max 0 (floor (* (/ (float v) peak) 7)))))))
       vs ""))))

;;; ---------------------------------------------------------------------------
;;; Gauge line + ring buffer

(defun eltainer-gauge-line (label used denom basis humanizer &optional trend)
  "Format one indented gauge LABEL line.
USED and DENOM are numbers (DENOM may be nil); BASIS is a symbol
naming the denominator; HUMANIZER formats a raw number for display.
TREND, when a list of past values, appends a small trend sparkline."
  (let* ((frac (and used denom (> denom 0) (/ (float used) denom)))
         (gauge (if frac
                    (eltainer-gauge frac)
                  ;; No denominator — pad so the text column still lines up.
                  (make-string (+ 2 eltainer-gauge-width) ?\s)))
         (rhs (if frac
                  (format "%s / %s  %d%% %s"
                          (funcall humanizer used)
                          (funcall humanizer denom)
                          (round (* 100 frac))
                          basis)
                (format "%s / —  (no limit)"
                        (funcall humanizer used)))))
    (concat
     (format "        %-4s %s  %s"
             label gauge
             (propertize rhs 'font-lock-face 'eltainer-gauge-empty))
     (if (and trend (cdr trend))        ; ≥2 points before it reads as a trend
         (concat "  " (propertize (eltainer-sparkline trend 10)
                                  'font-lock-face 'eltainer-gauge-empty))
       "")
     "\n")))

(defun eltainer-ring-add (ring value)
  "Return RING with VALUE appended, capped at `eltainer-gauge-history-length'."
  (last (append ring (list value)) eltainer-gauge-history-length))

(provide 'eltainer-gauge)
;;; eltainer-gauge.el ends here
