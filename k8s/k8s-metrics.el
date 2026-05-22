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

(defcustom k8s-metrics-history-length 24
  "How many recent network-rate samples to keep per pod.
The network sparkline draws (up to) this many points."
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

(defun k8s-metrics--sparkline (values &optional width)
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
KIND is `cpu' (VALUE in millicores), `memory' or `disk' (VALUE in
bytes — `disk' reads the `ephemeral-storage' resource).  BASIS is
`limit' or `request'; (nil . nil) when neither is set."
  (let* ((res (cdr (assq 'resources spec-container)))
         (key (pcase kind
                ('cpu 'cpu)
                ('memory 'memory)
                ('disk 'ephemeral-storage)))
         (parse (if (eq kind 'cpu)
                    #'k8s-metrics--parse-cpu
                  #'k8s-metrics--parse-memory))
         (lim (cdr (assq key (cdr (assq 'limits res)))))
         (req (cdr (assq key (cdr (assq 'requests res))))))
    (cond
     (lim (cons (funcall parse lim) 'limit))
     (req (cons (funcall parse req) 'request))
     (t (cons nil nil)))))

(defun k8s-metrics--line (label used denom basis humanizer &optional trend)
  "Format one indented gauge LABEL line.
USED and DENOM are numbers (DENOM may be nil); BASIS is a symbol;
HUMANIZER formats a raw number for display.  TREND, when given a
list of past values, appends a small trend sparkline."
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
    (concat
     (format "        %-4s %s  %s"
             label gauge
             (propertize rhs 'font-lock-face 'k8s-dim))
     (if (and trend (cdr trend))        ; ≥2 points before it reads as a trend
         (concat "  " (propertize (k8s-metrics--sparkline trend 10)
                                  'font-lock-face 'k8s-gauge-empty))
       "")
     "\n")))

(defun k8s-metrics-cm-sample (history key cpu mem)
  "Append CPU/MEM samples for KEY to HISTORY (a hash the caller owns).
KEY is usually \"NS/POD/CONTAINER\".  Returns the updated
\(:cpu-hist :mem-hist) plist."
  (let* ((e (gethash key history))
         (ch (last (append (plist-get e :cpu-hist) (list (or cpu 0)))
                   k8s-metrics-history-length))
         (mh (last (append (plist-get e :mem-hist) (list (or mem 0)))
                   k8s-metrics-history-length))
         (new (list :cpu-hist ch :mem-hist mh)))
    (puthash key new history)
    new))

(defun k8s-metrics-container-lines (pod cname usage &optional disk-used cm-hist)
  "Return the indented CPU/memory/disk gauge lines for CNAME of POD.
USAGE is (CPU-MILLICORES . MEM-BYTES) from `k8s-metrics-collect', or
nil.  DISK-USED is the container's rootfs bytes from the kubelet
Summary API, or nil.  CM-HIST, when given, is a (:cpu-hist :mem-hist)
plist whose rings drive the per-line trend sparklines.  Returns nil
when there is nothing to draw."
  (let ((spec-c (k8s-metrics--spec-container pod cname))
        (lines nil))
    (when usage
      (let ((cpu-d (k8s-metrics--denominator spec-c 'cpu))
            (mem-d (k8s-metrics--denominator spec-c 'memory)))
        (push (k8s-metrics--line "cpu" (car usage) (car cpu-d) (cdr cpu-d)
                                 #'k8s-metrics--human-cpu
                                 (plist-get cm-hist :cpu-hist))
              lines)
        (push (k8s-metrics--line "mem" (cdr usage) (car mem-d) (cdr mem-d)
                                 #'k8s-metrics--human-bytes
                                 (plist-get cm-hist :mem-hist))
              lines)))
    (when disk-used
      (let ((disk-d (k8s-metrics--denominator spec-c 'disk)))
        (push (k8s-metrics--line "disk" disk-used (car disk-d) (cdr disk-d)
                                 #'k8s-metrics--human-bytes)
              lines)))
    (when lines
      (apply #'concat (nreverse lines)))))

;;; ---------------------------------------------------------------------------
;;; Disk + network — kubelet Summary API (phase 2)

(defun k8s-metrics-collect-summary (conn)
  "Fetch the kubelet Summary API for every node reachable via CONN.
Returns a hash \"NS/POD\" -> that pod's summary entry alist (it
carries `network' byte counters and per-container `rootfs' disk
usage), or nil when the Summary API is unavailable on every node
\(no `nodes/proxy' RBAC, kubelet unreachable, ...)."
  (let ((nodes (ignore-errors
                 (cdr (assq 'items (k8s-get conn "/api/v1/nodes")))))
        (table (make-hash-table :test 'equal))
        (any nil))
    (seq-doseq (node (or nodes []))
      (let* ((nname (cdr (assq 'name (cdr (assq 'metadata node)))))
             (summary (and nname (k8s-stats-summary conn nname))))
        (when summary
          (setq any t)
          (seq-doseq (p (cdr (assq 'pods summary)))
            (let* ((ref (cdr (assq 'podRef p)))
                   (ns (cdr (assq 'namespace ref)))
                   (nm (cdr (assq 'name ref))))
              (when (and ns nm)
                (puthash (format "%s/%s" ns nm) p table)))))))
    (and any table)))

(defun k8s-metrics--summary-container-disk (summary-pod cname)
  "Return CNAME's rootfs used-bytes from SUMMARY-POD, or nil."
  (let ((c (seq-find (lambda (c) (equal (cdr (assq 'name c)) cname))
                     (append (cdr (assq 'containers summary-pod)) nil))))
    (and c (cdr (assq 'usedBytes (cdr (assq 'rootfs c)))))))

(defun k8s-metrics--summary-network (summary-pod)
  "Return (RX-BYTES . TX-BYTES) cumulative counters for SUMMARY-POD, or nil."
  (let ((net (cdr (assq 'network summary-pod))))
    (when net
      (let ((rx (cdr (assq 'rxBytes net)))
            (tx (cdr (assq 'txBytes net))))
        (and rx tx (cons rx tx))))))

(defun k8s-metrics-net-sample (history key rx tx now)
  "Record cumulative counters RX/TX at time NOW for pod KEY in HISTORY.
HISTORY is a hash table the caller owns (one per buffer).  Computes
the byte/sec rate against the previous sample, appends it to the
per-pod ring buffers, and returns the updated entry plist with
keys :rx :tx :time :rx-rate :tx-rate :rx-hist :tx-hist."
  (let* ((e (gethash key history))
         (prev-rx (plist-get e :rx))
         (prev-tx (plist-get e :tx))
         (prev-t  (plist-get e :time))
         (dt (and prev-t (- now prev-t)))
         (rx-rate (if (and dt (> dt 0) prev-rx)
                      (max 0.0 (/ (- rx prev-rx) dt))
                    0.0))
         (tx-rate (if (and dt (> dt 0) prev-tx)
                      (max 0.0 (/ (- tx prev-tx) dt))
                    0.0))
         (rx-hist (plist-get e :rx-hist))
         (tx-hist (plist-get e :tx-hist)))
    ;; Skip the very first sample — no delta to form a rate from yet.
    (when dt
      (setq rx-hist (last (append rx-hist (list rx-rate))
                          k8s-metrics-history-length)
            tx-hist (last (append tx-hist (list tx-rate))
                          k8s-metrics-history-length)))
    (let ((entry (list :rx rx :tx tx :time now
                       :rx-rate rx-rate :tx-rate tx-rate
                       :rx-hist rx-hist :tx-hist tx-hist)))
      (puthash key entry history)
      entry)))

(defun k8s-metrics-pod-network-line (net-entry &optional indent)
  "Return the pod network line for NET-ENTRY (from `k8s-metrics-net-sample').
INDENT is the leading-space string (defaults to 4 spaces).  Two
sparklines — rx and tx — each with the current rate.  Before the
second poll there is no rate yet, so a `(sampling…)' placeholder is
shown instead — the row is never just absent.  Returns nil only
when NET-ENTRY itself is nil."
  (when net-entry
    (let ((indent (or indent "    ")))
      (if (null (plist-get net-entry :rx-hist))
          ;; Counters captured, no delta yet — show a placeholder.
          (concat
           (propertize (format "%snet   " indent) 'font-lock-face 'k8s-dim)
           (propertize "(sampling…)\n" 'font-lock-face 'k8s-gauge-empty))
        (let ((rx (k8s-metrics--sparkline (plist-get net-entry :rx-hist) 12))
              (tx (k8s-metrics--sparkline (plist-get net-entry :tx-hist) 12))
              (rxr (k8s-metrics--human-bytes
                    (round (or (plist-get net-entry :rx-rate) 0))))
              (txr (k8s-metrics--human-bytes
                    (round (or (plist-get net-entry :tx-rate) 0)))))
          (concat
           (propertize (format "%snet   rx " indent) 'font-lock-face 'k8s-dim)
           (propertize rx 'font-lock-face 'k8s-gauge-low)
           (propertize (format " %9s/s    tx " (concat rxr))
                       'font-lock-face 'k8s-dim)
           (propertize tx 'font-lock-face 'k8s-gauge-mid)
           (propertize (format " %9s/s\n" (concat txr))
                       'font-lock-face 'k8s-dim)))))))

;;; ---------------------------------------------------------------------------
;;; Per-pod metrics buffer
;;
;; A focused `*k8s:metrics:NS/POD*' buffer reachable with `M' from the
;; pods view (see `k8s-pod-metrics-at-point').  Shows every container's
;; CPU/memory gauges without needing the pod section expanded, and
;; self-refreshes on its own timer.

(defvar-local k8s-metrics--conn nil
  "Connection for the current metrics buffer.")
(defvar-local k8s-metrics--ns nil
  "Namespace of the pod shown in the current metrics buffer.")
(defvar-local k8s-metrics--pod nil
  "Name of the pod shown in the current metrics buffer.")
(defvar-local k8s-metrics--timer nil
  "Repeating refresh timer for the current metrics buffer.")
(defvar-local k8s-metrics--net-history nil
  "Hash of network-rate history for this buffer's pod (one key).")
(defvar-local k8s-metrics--cm-history nil
  "Hash \"NS/POD/CONTAINER\" -> cpu/mem history for this buffer's pod.")

(defun k8s-metrics--buffer-stop-timer ()
  "Cancel the current metrics buffer's refresh timer."
  (when (timerp k8s-metrics--timer)
    (cancel-timer k8s-metrics--timer))
  (setq k8s-metrics--timer nil))

(defvar-keymap k8s-metrics-mode-map
  :parent special-mode-map
  "g" #'k8s-metrics-buffer-refresh
  "q" #'quit-window)

(define-derived-mode k8s-metrics-mode special-mode "K8s:Metrics"
  "Major mode for the per-pod metrics buffer."
  :group 'k8s-metrics
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'k8s-metrics--buffer-stop-timer nil t))

(defun k8s-metrics-buffer-refresh ()
  "Re-fetch and re-render the current metrics buffer."
  (interactive)
  (unless (derived-mode-p 'k8s-metrics-mode)
    (user-error "Not a k8s metrics buffer"))
  (let* ((conn k8s-metrics--conn)
         (ns k8s-metrics--ns)
         (name k8s-metrics--pod)
         (key (format "%s/%s" ns name))
         (pod (ignore-errors
                (k8s-get-resource
                 conn (format "/api/v1/namespaces/%s/pods/%s" ns name))))
         (metrics (k8s-metrics-collect conn ns))
         (usage (and metrics (gethash key metrics)))
         (summary (k8s-metrics-collect-summary conn))
         (summary-pod (and summary (gethash key summary)))
         (net-entry
          (when summary-pod
            (let ((net (k8s-metrics--summary-network summary-pod)))
              (when net
                (unless k8s-metrics--net-history
                  (setq k8s-metrics--net-history
                        (make-hash-table :test 'equal)))
                (k8s-metrics-net-sample k8s-metrics--net-history key
                                        (car net) (cdr net)
                                        (float-time))))))
         (inhibit-read-only t)
         (pt (point)))
    (erase-buffer)
    (cond
     ((null pod)
      (insert (format "Pod %s/%s not found.\n" ns name)))
     (t
      (let ((node (or (cdr (assq 'nodeName (cdr (assq 'spec pod)))) "?")))
        (insert (propertize (format "Pod  %s" name)
                            'font-lock-face 'k8s-section-heading)
                (propertize (format "   namespace %s   node %s\n\n" ns node)
                            'font-lock-face 'k8s-dim)))
      (when-let ((nl (k8s-metrics-pod-network-line net-entry "  ")))
        (insert nl "\n"))
      (if (and (null metrics) (null summary-pod))
          (insert (propertize
                   "  metrics-server / kubelet stats unavailable.\n"
                   'font-lock-face 'k8s-dim))
        (let ((statuses (cdr (assq 'containerStatuses
                                   (cdr (assq 'status pod))))))
          (if (or (null statuses) (zerop (length statuses)))
              (insert (propertize "  (pod has no running containers)\n"
                                  'font-lock-face 'k8s-dim))
            (unless k8s-metrics--cm-history
              (setq k8s-metrics--cm-history (make-hash-table :test 'equal)))
            (seq-doseq (cs statuses)
              (let* ((cname (cdr (assq 'name cs)))
                     (u (cdr (assoc cname usage)))
                     (disk (and summary-pod
                                (k8s-metrics--summary-container-disk
                                 summary-pod cname)))
                     (cm (when u
                           (k8s-metrics-cm-sample
                            k8s-metrics--cm-history
                            (format "%s/%s" key cname)
                            (car u) (cdr u)))))
                (insert (propertize (format "  %s\n" cname)
                                    'font-lock-face 'k8s-resource-name))
                (insert (or (k8s-metrics-container-lines pod cname u disk cm)
                            (propertize "        (no metrics yet)\n"
                                        'font-lock-face 'k8s-dim)))
                (insert "\n"))))))))
    (goto-char (min pt (point-max)))))

(defun k8s-metrics--buffer-start-timer ()
  "(Re)start the current metrics buffer's refresh timer."
  (k8s-metrics--buffer-stop-timer)
  (let ((buf (current-buffer)))
    ;; The buffer's kill-buffer-hook cancels this timer; the
    ;; `buffer-live-p' guard just covers the race.
    (setq k8s-metrics--timer
          (run-at-time k8s-metrics-refresh-interval
                       k8s-metrics-refresh-interval
                       (lambda ()
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (k8s-metrics-buffer-refresh))))))))

(defun k8s-metrics-buffer (conn ns pod-name)
  "Open and display the metrics buffer for pod NS/POD-NAME via CONN."
  (let ((buf (get-buffer-create (format "*k8s:metrics:%s/%s*" ns pod-name))))
    (with-current-buffer buf
      (k8s-metrics-mode)
      (setq k8s-metrics--conn conn
            k8s-metrics--ns ns
            k8s-metrics--pod pod-name)
      (k8s-metrics-buffer-refresh)
      (k8s-metrics--buffer-start-timer))
    (pop-to-buffer buf)
    (message "k8s metrics: %s/%s — g refreshes, q quits" ns pod-name)))

;;; ---------------------------------------------------------------------------
;;; Node-level metrics view

(declare-function k8s--ensure-connection "k8s")

(defun k8s-metrics-collect-nodes (conn)
  "Return a list of per-node metric plists via CONN, or nil if unavailable.
Each plist: :name :cpu-used :cpu-total :mem-used :mem-total
:fs-used :fs-total.  CPU values are millicores, the rest bytes;
usage fields are nil when the kubelet Summary API is unavailable."
  (let ((nodes (ignore-errors
                 (cdr (assq 'items (k8s-get conn "/api/v1/nodes"))))))
    (when nodes
      (let (out)
        (seq-doseq (node nodes)
          (let* ((meta (cdr (assq 'metadata node)))
                 (nname (cdr (assq 'name meta)))
                 (alloc (cdr (assq 'allocatable (cdr (assq 'status node)))))
                 (cpu-total (k8s-metrics--parse-cpu (cdr (assq 'cpu alloc))))
                 (mem-total (k8s-metrics--parse-memory
                             (cdr (assq 'memory alloc))))
                 (summary (and nname (k8s-stats-summary conn nname)))
                 (snode (and summary (cdr (assq 'node summary))))
                 (cpu-nano (and snode (cdr (assq 'usageNanoCores
                                                 (cdr (assq 'cpu snode))))))
                 (mem (and snode (cdr (assq 'memory snode))))
                 (fs (and snode (cdr (assq 'fs snode)))))
            (push (list :name nname
                        :cpu-used (and cpu-nano (/ cpu-nano 1e6))
                        :cpu-total cpu-total
                        :mem-used (and mem (cdr (assq 'workingSetBytes mem)))
                        :mem-total mem-total
                        :fs-used (and fs (cdr (assq 'usedBytes fs)))
                        :fs-total (and fs (cdr (assq 'capacityBytes fs))))
                  out)))
        (nreverse out)))))

(defvar-local k8s-nodes--conn nil
  "Connection for the current node-metrics buffer.")
(defvar-local k8s-nodes--timer nil
  "Repeating refresh timer for the current node-metrics buffer.")
(defvar-local k8s-nodes--cm-history nil
  "Hash NODE-NAME -> cpu/mem history, for the node trend sparklines.")

(defun k8s-nodes--stop-timer ()
  "Cancel the node-metrics buffer's refresh timer."
  (when (timerp k8s-nodes--timer)
    (cancel-timer k8s-nodes--timer))
  (setq k8s-nodes--timer nil))

(defvar-keymap k8s-nodes-metrics-mode-map
  :parent special-mode-map
  "g" #'k8s-nodes-metrics-refresh
  "q" #'quit-window)

(define-derived-mode k8s-nodes-metrics-mode special-mode "K8s:Nodes"
  "Major mode for the cluster node-metrics view."
  :group 'k8s-metrics
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'k8s-nodes--stop-timer nil t))

(defun k8s-nodes-metrics-refresh ()
  "Re-fetch and re-render the node-metrics buffer."
  (interactive)
  (unless (derived-mode-p 'k8s-nodes-metrics-mode)
    (user-error "Not a k8s node-metrics buffer"))
  (let* ((nodes (k8s-metrics-collect-nodes k8s-nodes--conn))
         (inhibit-read-only t)
         (pt (point)))
    (unless k8s-nodes--cm-history
      (setq k8s-nodes--cm-history (make-hash-table :test 'equal)))
    (erase-buffer)
    (insert (propertize "Cluster nodes" 'font-lock-face 'k8s-section-heading)
            (propertize "   g refreshes, q quits\n\n" 'font-lock-face 'k8s-dim))
    (if (null nodes)
        (insert (propertize
                 "  no nodes — API unreachable.\n" 'font-lock-face 'k8s-dim))
      (dolist (n nodes)
        (let* ((name (plist-get n :name))
               (cm (k8s-metrics-cm-sample k8s-nodes--cm-history name
                                          (plist-get n :cpu-used)
                                          (plist-get n :mem-used))))
          (insert (propertize (format "Node  %s\n" name)
                              'font-lock-face 'k8s-resource-name))
          (insert (k8s-metrics--line "cpu" (plist-get n :cpu-used)
                                     (plist-get n :cpu-total) 'alloc
                                     #'k8s-metrics--human-cpu
                                     (plist-get cm :cpu-hist)))
          (insert (k8s-metrics--line "mem" (plist-get n :mem-used)
                                     (plist-get n :mem-total) 'alloc
                                     #'k8s-metrics--human-bytes
                                     (plist-get cm :mem-hist)))
          (insert (k8s-metrics--line "fs" (plist-get n :fs-used)
                                     (plist-get n :fs-total) 'capacity
                                     #'k8s-metrics--human-bytes))
          (insert "\n"))))
    (goto-char (min pt (point-max)))))

(defun k8s-nodes--start-timer ()
  "(Re)start the node-metrics buffer's refresh timer."
  (k8s-nodes--stop-timer)
  (let ((buf (current-buffer)))
    (setq k8s-nodes--timer
          (run-at-time k8s-metrics-refresh-interval
                       k8s-metrics-refresh-interval
                       (lambda ()
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (k8s-nodes-metrics-refresh))))))))

;;;###autoload
(defun k8s-nodes-metrics ()
  "Open the cluster node-metrics view (per-node CPU / memory / disk)."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:metrics:nodes*"))
        (conn (k8s--ensure-connection)))
    (with-current-buffer buf
      (k8s-nodes-metrics-mode)
      (setq k8s-nodes--conn conn)
      (k8s-nodes-metrics-refresh)
      (k8s-nodes--start-timer))
    (pop-to-buffer buf)
    (message "k8s node metrics — g refreshes, q quits")))

(provide 'k8s-metrics)
;;; k8s-metrics.el ends here
