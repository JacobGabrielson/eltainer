;;; k8s-metrics.el --- Resource-usage metrics + gauges for eltainer k8s -*- lexical-binding: t -*-
;;
;; Phase 1 of docs/metrics-plan.md: CPU + memory usage for pod
;; containers, fetched from the `metrics.k8s.io' aggregated API
;; (served by metrics-server) and rendered as compact text gauges.
;;
;; Pure Elisp — quantity parsing, gauge drawing (Unicode block
;; elements + faces), and the existing `docker-http' transport.  No
;; new package dependencies.
;;
;; Disk usage is out of scope for phase 1 (metrics.k8s.io does not
;; expose it — see the plan doc).

(require 'cl-lib)
(require 'k8s-api)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup k8s-metrics nil
  "Resource-usage gauges for the eltainer Kubernetes views."
  :group 'k8s)

(defcustom k8s-metrics-gauge-width 16
  "Width, in characters, of a usage gauge bar (excluding end-caps)."
  :type 'integer
  :group 'k8s-metrics)

(defcustom k8s-metrics-gauge-style 'blocks
  "How to draw gauge bars.
`blocks' uses Unicode block elements with 1/8-cell precision;
`ascii' uses plain `#' / `-' for fonts or terminals without the
block glyphs."
  :type '(choice (const blocks) (const ascii))
  :group 'k8s-metrics)

(defcustom k8s-metrics-refresh-interval 15
  "Seconds between metrics polls while a pods buffer is open.
metrics-server itself only scrapes every ~15s, so polling faster
buys nothing."
  :type 'integer
  :group 'k8s-metrics)

(defconst k8s-metrics--mid-threshold 0.70
  "Fraction at/above which a gauge turns from low to mid colour.")

(defconst k8s-metrics--high-threshold 0.90
  "Fraction at/above which a gauge turns to the high colour.")

;;; ---------------------------------------------------------------------------
;;; Faces

(defface k8s-gauge-low '((t :inherit success))
  "Face for the filled part of a gauge below the mid threshold."
  :group 'k8s-metrics)

(defface k8s-gauge-mid '((t :inherit warning))
  "Face for the filled part of a gauge in the mid band."
  :group 'k8s-metrics)

(defface k8s-gauge-high '((t :inherit error))
  "Face for the filled part of a gauge over the high threshold."
  :group 'k8s-metrics)

(defface k8s-gauge-empty '((t :inherit shadow))
  "Face for the unfilled track of a gauge."
  :group 'k8s-metrics)

;;; ---------------------------------------------------------------------------
;;; Resource-quantity parsers

(defun k8s-metrics--parse-cpu (s)
  "Parse a Kubernetes CPU quantity string S into millicores (float).
Returns nil when S is nil or unparseable.  Handles the `n'/`u'/`m'
suffixes metrics-server emits as well as bare cores and the larger
decimal suffixes."
  (when (and (stringp s)
             (string-match "\\`\\([0-9]*\\.?[0-9]+\\)\\([a-zA-Z]*\\)\\'" s))
    (let ((num (string-to-number (match-string 1 s)))
          (suf (match-string 2 s)))
      (* 1000.0 num
         (pcase suf
           ("n" 1e-9) ("u" 1e-6) ("m" 1e-3)
           ("" 1.0)
           ("k" 1e3) ("M" 1e6) ("G" 1e9)
           ("T" 1e12) ("P" 1e15) ("E" 1e18)
           (_ 1.0))))))

(defun k8s-metrics--parse-memory (s)
  "Parse a Kubernetes memory quantity string S into bytes (integer).
Returns nil when S is nil or unparseable.  Handles binary suffixes
\(Ki/Mi/Gi/...) and decimal suffixes (k/M/G/...)."
  (when (and (stringp s)
             (string-match
              "\\`\\([0-9]*\\.?[0-9]+\\)\\(Ki\\|Mi\\|Gi\\|Ti\\|Pi\\|Ei\\|[kKMGTPE]?\\)\\'"
              s))
    (let ((num (string-to-number (match-string 1 s)))
          (suf (match-string 2 s)))
      (round (* num
                (pcase suf
                  ("Ki" 1024.0) ("Mi" (expt 1024.0 2)) ("Gi" (expt 1024.0 3))
                  ("Ti" (expt 1024.0 4)) ("Pi" (expt 1024.0 5))
                  ("Ei" (expt 1024.0 6))
                  ((or "k" "K") 1e3) ("M" 1e6) ("G" 1e9)
                  ("T" 1e12) ("P" 1e15) ("E" 1e18)
                  ("" 1.0)
                  (_ 1.0)))))))

;;; ---------------------------------------------------------------------------
;;; Humanizers

(defun k8s-metrics--human-cpu (millicores)
  "Format MILLICORES (a number) the k8s way, e.g. \"250m\"."
  (if (numberp millicores)
      (format "%dm" (round millicores))
    "?"))

(defun k8s-metrics--human-bytes (n)
  "Format N bytes with a binary-unit suffix, e.g. \"218Mi\"."
  (cond
   ((not (numberp n)) "?")
   ((< n 1024) (format "%dB" n))
   ((< n (* 1024 1024)) (format "%dKi" (round (/ n 1024.0))))
   ((< n (* 1024 1024 1024))
    (format "%dMi" (round (/ n (* 1024.0 1024)))))
   (t (format "%.1fGi" (/ n (* 1024.0 1024 1024))))))

;;; ---------------------------------------------------------------------------
;;; Gauge rendering

(defun k8s-metrics--gauge-face (fraction)
  "Return the gauge face for FRACTION (0.0..1.0)."
  (cond
   ((>= fraction k8s-metrics--high-threshold) 'k8s-gauge-high)
   ((>= fraction k8s-metrics--mid-threshold)  'k8s-gauge-mid)
   (t 'k8s-gauge-low)))

(defun k8s-metrics--bar (fraction width)
  "Return a propertized WIDTH-cell bar string for FRACTION (0.0..1.0)."
  (let* ((f (max 0.0 (min 1.0 (or fraction 0.0))))
         (face (k8s-metrics--gauge-face f)))
    (pcase k8s-metrics-gauge-style
      ('ascii
       (let ((full (round (* f width))))
         (concat (propertize (make-string full ?#) 'font-lock-face face)
                 (propertize (make-string (- width full) ?-)
                             'font-lock-face 'k8s-gauge-empty))))
      (_
       (let* ((eighths (round (* f width 8)))
              (full (/ eighths 8))
              (rem (% eighths 8))
              (parts ["" "▏" "▎" "▍" "▌" "▋" "▊" "▉"])
              (filled (concat (make-string full ?█)
                              (unless (zerop rem) (aref parts rem))))
              (empty (make-string (max 0 (- width (length filled))) ?░)))
         (concat (propertize filled 'font-lock-face face)
                 (propertize empty 'font-lock-face 'k8s-gauge-empty)))))))

(defun k8s-metrics-gauge (fraction)
  "Return a complete gauge string (end-caps + bar) for FRACTION."
  (concat (propertize "▏" 'font-lock-face 'k8s-gauge-empty)
          (k8s-metrics--bar fraction k8s-metrics-gauge-width)
          (propertize "▕" 'font-lock-face 'k8s-gauge-empty)))

;;; ---------------------------------------------------------------------------
;;; Fetch + cache

(defun k8s-metrics-collect (conn &optional namespace)
  "Fetch pod metrics via CONN, optionally limited to NAMESPACE.
Return a hash table keyed \"NS/POD\" whose values are alists of
\(CONTAINER-NAME . (CPU-MILLICORES . MEM-BYTES)).  Returns nil when
the `metrics.k8s.io' API is unavailable (no metrics-server)."
  (let ((items (k8s-metrics-list-pods conn namespace)))
    (when items
      (let ((table (make-hash-table :test 'equal)))
        (seq-doseq (pm items)
          (let* ((meta (cdr (assq 'metadata pm)))
                 (ns (cdr (assq 'namespace meta)))
                 (name (cdr (assq 'name meta)))
                 (key (format "%s/%s" ns name))
                 acc)
            (seq-doseq (c (cdr (assq 'containers pm)))
              (let ((cn (cdr (assq 'name c)))
                    (usage (cdr (assq 'usage c))))
                (push (cons cn
                            (cons (k8s-metrics--parse-cpu
                                   (cdr (assq 'cpu usage)))
                                  (k8s-metrics--parse-memory
                                   (cdr (assq 'memory usage)))))
                      acc)))
            (puthash key acc table)))
        table))))

;;; ---------------------------------------------------------------------------
;;; Per-container rendering

(defun k8s-metrics--spec-container (pod cname)
  "Return the `spec.containers' entry named CNAME in POD, or nil."
  (let ((containers (cdr (assq 'containers (cdr (assq 'spec pod))))))
    (seq-find (lambda (c) (equal (cdr (assq 'name c)) cname))
              (append containers nil))))

(defun k8s-metrics--denominator (spec-container kind)
  "Return (VALUE . BASIS) for KIND of SPEC-CONTAINER.
KIND is `cpu' (VALUE in millicores) or `memory' (VALUE in bytes).
BASIS is `limit' or `request'; (nil . nil) when neither is set."
  (let* ((res (cdr (assq 'resources spec-container)))
         (key (if (eq kind 'cpu) 'cpu 'memory))
         (parse (if (eq kind 'cpu)
                    #'k8s-metrics--parse-cpu
                  #'k8s-metrics--parse-memory))
         (lim (cdr (assq key (cdr (assq 'limits res)))))
         (req (cdr (assq key (cdr (assq 'requests res))))))
    (cond
     (lim (cons (funcall parse lim) 'limit))
     (req (cons (funcall parse req) 'request))
     (t (cons nil nil)))))

(defun k8s-metrics--line (label used denom basis humanizer)
  "Format one indented gauge LABEL line.
USED and DENOM are numbers (DENOM may be nil); BASIS is a symbol;
HUMANIZER formats a raw number for display."
  (let* ((frac (and used denom (> denom 0) (/ (float used) denom)))
         (gauge (if frac
                    (k8s-metrics-gauge frac)
                  ;; No denominator — pad so the text column still lines up.
                  (make-string (+ 2 k8s-metrics-gauge-width) ?\s)))
         (rhs (if frac
                  (format "%s / %s  %d%% %s"
                          (funcall humanizer used)
                          (funcall humanizer denom)
                          (round (* 100 frac))
                          basis)
                (format "%s / —  (no limit/request)"
                        (funcall humanizer used)))))
    (format "        %-4s %s  %s\n"
            label gauge
            (propertize rhs 'font-lock-face 'k8s-dim))))

(defun k8s-metrics-container-lines (pod cname usage)
  "Return the indented CPU/memory gauge lines for container CNAME of POD.
USAGE is (CPU-MILLICORES . MEM-BYTES) from `k8s-metrics-collect', or
nil — in which case this returns nil (no gauges to draw)."
  (when usage
    (let* ((spec-c (k8s-metrics--spec-container pod cname))
           (cpu-d (k8s-metrics--denominator spec-c 'cpu))
           (mem-d (k8s-metrics--denominator spec-c 'memory)))
      (concat
       (k8s-metrics--line "cpu" (car usage) (car cpu-d) (cdr cpu-d)
                          #'k8s-metrics--human-cpu)
       (k8s-metrics--line "mem" (cdr usage) (car mem-d) (cdr mem-d)
                          #'k8s-metrics--human-bytes)))))

(provide 'k8s-metrics)
;;; k8s-metrics.el ends here
