;;; docker-metrics.el --- Container resource gauges for eltainer -*- lexical-binding: t -*-
;;
;; Per-container resource usage for the Docker view — CPU, memory,
;; block-I/O, network, PIDs — rendered as the shared `eltainer-gauge'
;; text gauges and sparklines.
;;
;; Source: `GET /containers/{id}/stats?stream=false' (one sample per
;; container).  CPU%, block-I/O and network rates are computed across
;; consecutive eltainer polls — the daemon's own `precpu_stats' window
;; is only milliseconds wide, too short to be useful.  Each container's
;; previous counters and trend rings live in a history hash the caller
;; (the containers view) owns; `docker-metrics-sample' folds one stats
;; snapshot in and returns the render-ready plist.
;;
;; Goes beyond the k8s gauges: CPU throttling, block-I/O throughput,
;; PID counts, network drop counters — things metrics-server never
;; exposed.  Block-I/O is absent on rootless cgroup-v2 daemons (the io
;; controller isn't delegated); the code degrades gracefully.

(require 'cl-lib)
(require 'seq)
(require 'eltainer-gauge)
(require 'docker-api)
(require 'docker-http)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup docker-metrics nil
  "Resource-usage gauges for the eltainer Docker views."
  :group 'docker)

(defcustom docker-metrics-refresh-interval 30
  "Seconds between container-stats polls while a containers buffer is open.
Each `/stats?stream=false' call samples a ~1s window on the daemon
side, so polling fast costs both eltainer and the daemon real
work; the default is relaxed to keep background traffic modest.
Lower it if you want gauges that move more visibly."
  :type 'integer
  :group 'docker-metrics)

(defcustom docker-metrics-max-containers 40
  "Skip the stats poll when more than this many containers are running.
`/stats' is one call per container; this caps the cost on big hosts."
  :type 'integer
  :group 'docker-metrics)

;;; ---------------------------------------------------------------------------
;;; Async fetch
;;
;; `/stats?stream=false' costs the daemon ~1.5s (it samples a window),
;; so it is fetched over an asynchronous network process — the request
;; runs in the background and CALLBACK fires when the response lands,
;; never blocking Emacs.

(defun docker-metrics-fetch-async (cfg id callback)
  "Asynchronously fetch a one-shot `/stats' sample for container ID.
CALLBACK is called with the decoded stats alist, or nil on failure.
Returns immediately — the request runs over `docker-http-stream'."
  (let ((acc "") (ok t))
    (condition-case nil
        (docker-http-stream
         cfg "GET" (format "/containers/%s/stats" id)
         :query '(("stream" . "false"))
         :on-headers (lambda (status &rest _)
                       (setq ok (and status (= status 200))))
         :on-chunk (lambda (bytes) (when ok (setq acc (concat acc bytes))))
         :on-close
         (lambda ()
           (funcall callback
                    (and ok (> (length acc) 0)
                         (ignore-errors
                           (json-parse-string
                            acc :object-type 'alist :array-type 'array
                            :null-object nil :false-object :false))))))
      (error (funcall callback nil)))))

;;; ---------------------------------------------------------------------------
;;; Sampling

(defun docker-metrics-sample (history id stats host-mem now)
  "Fold STATS for container ID into HISTORY at time NOW.
HISTORY is a hash table the caller owns; HOST-MEM is the daemon's
total RAM (to tell an unlimited container's memory apart from a real
limit).  Computes CPU% / block-I/O / network rates against the
previous sample for ID.  Returns — and stores — the render plist."
  (let* ((prev (gethash id history))
         (ptime (plist-get prev :prev-time))
         (dt (and ptime (> now ptime) (- now ptime)))
         ;; --- CPU ---
         (cs (cdr (assq 'cpu_stats stats)))
         (total (cdr (assq 'total_usage (cdr (assq 'cpu_usage cs)))))
         (system (cdr (assq 'system_cpu_usage cs)))
         (ncpu (or (cdr (assq 'online_cpus cs)) 1))
         (ptotal (plist-get prev :cpu-prev-total))
         (psystem (plist-get prev :cpu-prev-system))
         (cpu-frac (when (and ptotal psystem total system)
                     (let ((cd (- total ptotal)) (sd (- system psystem)))
                       (when (and (> sd 0) (>= cd 0))
                         (/ (float cd) sd)))))
         (cpu-pct (and cpu-frac (* cpu-frac ncpu 100)))
         (throttle (cdr (assq 'throttling_data cs)))
         (thr-periods (cdr (assq 'periods throttle)))
         (thr-pct (when (and thr-periods (> thr-periods 0))
                    (* 100.0 (/ (float (or (cdr (assq 'throttled_periods
                                                       throttle))
                                           0))
                                thr-periods))))
         ;; --- memory ---
         (ms (cdr (assq 'memory_stats stats)))
         (musage (cdr (assq 'usage ms)))
         (mst (cdr (assq 'stats ms)))
         ;; cgroup v2: inactive_file is the reclaimable cache; v1: cache.
         (inactive (or (cdr (assq 'inactive_file mst))
                       (cdr (assq 'cache mst)) 0))
         (mused (and musage (max 0 (- musage inactive))))
         (mlimit-raw (cdr (assq 'limit ms)))
         ;; A container with no memory limit reports `limit' = host RAM;
         ;; in that case gauge against the whole box (basis `host'),
         ;; otherwise against the real limit (basis `limit').
         (mlimit-real (when (and mlimit-raw host-mem
                                 (< mlimit-raw (* host-mem 0.99)))
                        mlimit-raw))
         (mem-limit (or mlimit-real host-mem))
         (mem-basis (if mlimit-real 'limit 'host))
         ;; --- network (sum every interface) ---
         (nets (cdr (assq 'networks stats)))
         (rx 0) (tx 0) (rx-drop 0) (tx-drop 0)
         ;; --- block I/O ---
         (blk (cdr (assq 'io_service_bytes_recursive
                         (cdr (assq 'blkio_stats stats)))))
         (rd 0) (wr 0)
         (have-net (and nets t))
         (have-io (and blk (> (length blk) 0))))
    (when nets
      (dolist (iface nets)
        (let ((v (cdr iface)))
          (setq rx (+ rx (or (cdr (assq 'rx_bytes v)) 0))
                tx (+ tx (or (cdr (assq 'tx_bytes v)) 0))
                rx-drop (+ rx-drop (or (cdr (assq 'rx_dropped v)) 0))
                tx-drop (+ tx-drop (or (cdr (assq 'tx_dropped v)) 0))))))
    (when have-io
      (seq-doseq (e blk)
        (let ((op (downcase (or (cdr (assq 'op e)) "")))
              (val (or (cdr (assq 'value e)) 0)))
          (cond ((equal op "read")  (setq rd (+ rd val)))
                ((equal op "write") (setq wr (+ wr val)))))))
    (cl-flet ((rate (cur prev-key)
                (let ((p (plist-get prev prev-key)))
                  (and dt p (max 0.0 (/ (- cur p) dt)))))
              (ring (key val)
                (if val (eltainer-ring-add (plist-get prev key) val)
                  (plist-get prev key))))
      (let* ((net-rx-rate (and have-net (rate rx :net-prev-rx)))
             (net-tx-rate (and have-net (rate tx :net-prev-tx)))
             (io-rd-rate  (and have-io  (rate rd :io-prev-rd)))
             (io-wr-rate  (and have-io  (rate wr :io-prev-wr)))
             (new (list
                   :prev-time now
                   :cpu-prev-total total :cpu-prev-system system
                   :net-prev-rx (and have-net rx) :net-prev-tx (and have-net tx)
                   :io-prev-rd (and have-io rd) :io-prev-wr (and have-io wr)
                   :ncpu ncpu :cpu-frac cpu-frac :cpu-pct cpu-pct
                   :throttle-pct thr-pct
                   :mem-used mused :mem-limit mem-limit :mem-basis mem-basis
                   :pids (cdr (assq 'current (cdr (assq 'pids_stats stats))))
                   :have-net have-net :have-io have-io
                   :net-rx-rate net-rx-rate :net-tx-rate net-tx-rate
                   :net-rx-drop rx-drop :net-tx-drop tx-drop
                   :io-rd-rate io-rd-rate :io-wr-rate io-wr-rate
                   :cpu-hist (ring :cpu-hist cpu-pct)
                   :mem-hist (ring :mem-hist mused)
                   :net-rx-hist (ring :net-rx-hist net-rx-rate)
                   :net-tx-hist (ring :net-tx-hist net-tx-rate)
                   :io-rd-hist (ring :io-rd-hist io-rd-rate)
                   :io-wr-hist (ring :io-wr-hist io-wr-rate))))
        (puthash id new history)
        new))))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun docker-metrics--line (label fraction rhs &optional trend)
  "Format an indented gauge LABEL line for 0..1 FRACTION with RHS text.
FRACTION nil draws a blank gauge column.  TREND appends a sparkline."
  (concat
   (format "        %-4s %s  %s"
           label
           (if fraction (eltainer-gauge fraction)
             (make-string (+ 2 eltainer-gauge-width) ?\s))
           (propertize rhs 'font-lock-face 'eltainer-gauge-empty))
   (if (and trend (cdr trend))
       (concat "  " (propertize (eltainer-sparkline trend 10)
                                'font-lock-face 'eltainer-gauge-empty))
     "")
   "\n"))

(defun docker-metrics--rate-line (label a-tag a-hist a-rate b-tag b-hist b-rate)
  "Render a two-sparkline rate LABEL line (network rx/tx, block-io rd/wr).
Shows `(sampling…)' until the second poll gives the first rate."
  (if (null a-hist)
      (concat (propertize (format "        %-4s " label)
                          'font-lock-face 'eltainer-gauge-empty)
              (propertize "(sampling…)\n" 'font-lock-face 'eltainer-gauge-empty))
    (concat
     (propertize (format "        %-4s %s " label a-tag)
                 'font-lock-face 'eltainer-gauge-empty)
     (propertize (eltainer-sparkline a-hist 12) 'font-lock-face 'eltainer-gauge-low)
     (propertize (format " %9s/s   %s "
                         (eltainer-human-bytes (round (or a-rate 0))) b-tag)
                 'font-lock-face 'eltainer-gauge-empty)
     (propertize (eltainer-sparkline b-hist 12) 'font-lock-face 'eltainer-gauge-mid)
     (propertize (format " %9s/s\n" (eltainer-human-bytes (round (or b-rate 0))))
                 'font-lock-face 'eltainer-gauge-empty))))

(defun docker-metrics-container-lines (m)
  "Return the indented gauge / sparkline lines for metrics plist M, or nil."
  (when m
    (let ((parts nil)
          (frac (plist-get m :cpu-frac)))
      ;; CPU
      (push (if frac
                (docker-metrics--line
                 "cpu" frac
                 (let ((thr (plist-get m :throttle-pct)))
                   (concat (format "%d%%  of %d core%s"
                                   (round (plist-get m :cpu-pct))
                                   (plist-get m :ncpu)
                                   (if (= (plist-get m :ncpu) 1) "" "s"))
                           (if (and thr (>= thr 1))
                               (format "   throttled %d%%" (round thr))
                             "")))
                 (plist-get m :cpu-hist))
              (docker-metrics--line "cpu" nil "(sampling…)"))
            parts)
      ;; Memory
      (when (plist-get m :mem-used)
        (push (eltainer-gauge-line "mem" (plist-get m :mem-used)
                                   (plist-get m :mem-limit)
                                   (plist-get m :mem-basis)
                                   #'eltainer-human-bytes
                                   (plist-get m :mem-hist))
              parts))
      ;; Block I/O (absent on rootless cgroup-v2)
      (when (plist-get m :have-io)
        (push (docker-metrics--rate-line
               "io" "rd" (plist-get m :io-rd-hist) (plist-get m :io-rd-rate)
               "wr" (plist-get m :io-wr-hist) (plist-get m :io-wr-rate))
              parts))
      ;; Network
      (when (plist-get m :have-net)
        (push (concat
               (docker-metrics--rate-line
                "net" "rx" (plist-get m :net-rx-hist) (plist-get m :net-rx-rate)
                "tx" (plist-get m :net-tx-hist) (plist-get m :net-tx-rate))
               (let ((d (+ (or (plist-get m :net-rx-drop) 0)
                           (or (plist-get m :net-tx-drop) 0))))
                 (if (> d 0)
                     (propertize
                      (format "             ⚠ %d dropped packet%s\n"
                              d (if (= d 1) "" "s"))
                      'font-lock-face 'eltainer-gauge-high)
                   "")))
              parts))
      ;; PIDs
      (when (plist-get m :pids)
        (push (propertize (format "        pids %d\n" (plist-get m :pids))
                          'font-lock-face 'eltainer-gauge-empty)
              parts))
      (when parts (apply #'concat (nreverse parts))))))

;;; ---------------------------------------------------------------------------
;;; Per-container metrics buffer

(defvar-local docker-metrics--cfg nil
  "Docker connection config for the current metrics buffer.")
(defvar-local docker-metrics--id nil
  "Container id shown in the current metrics buffer.")
(defvar-local docker-metrics--name nil
  "Container name shown in the current metrics buffer.")
(defvar-local docker-metrics--history nil
  "Per-container metrics history hash for this buffer (one key).")
(defvar-local docker-metrics--host-mem nil
  "Cached daemon total RAM for the current metrics buffer.")
(defvar-local docker-metrics--timer nil
  "Repeating refresh timer for the current metrics buffer.")

(defun docker-metrics--buffer-stop-timer ()
  "Cancel the metrics buffer's refresh timer."
  (when (timerp docker-metrics--timer)
    (cancel-timer docker-metrics--timer))
  (setq docker-metrics--timer nil))

(defvar-keymap docker-metrics-mode-map
  :parent special-mode-map
  "g" #'docker-metrics-buffer-refresh
  "q" #'quit-window)

(define-derived-mode docker-metrics-mode special-mode "Docker:Metrics"
  "Major mode for the per-container metrics buffer."
  :group 'docker-metrics
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'docker-metrics--buffer-stop-timer nil t))

(defun docker-metrics--buffer-render (stats)
  "Render STATS (a stats alist, or nil) into the current metrics buffer."
  ;; The history hash can be wiped between firing the request and this
  ;; callback (a major-mode re-run calls `kill-all-local-variables').
  (unless docker-metrics--history
    (setq docker-metrics--history (make-hash-table :test 'equal)))
  (let ((inhibit-read-only t)
        (pt (point)))
    (erase-buffer)
    (insert (propertize (format "Container  %s" docker-metrics--name)
                        'font-lock-face 'bold)
            (propertize "   g refreshes, q quits\n\n"
                        'font-lock-face 'eltainer-gauge-empty))
    (if (null stats)
        (insert (propertize "  not running — no stats to show.\n"
                            'font-lock-face 'eltainer-gauge-empty))
      (let ((m (docker-metrics-sample docker-metrics--history
                                      docker-metrics--id stats
                                      docker-metrics--host-mem (float-time))))
        (insert (or (docker-metrics-container-lines m)
                    (propertize "  (sampling…)\n"
                                'font-lock-face 'eltainer-gauge-empty)))))
    (goto-char (min pt (point-max)))))

(defun docker-metrics-buffer-refresh ()
  "Re-fetch (asynchronously) and re-render the current metrics buffer."
  (interactive)
  (unless (derived-mode-p 'docker-metrics-mode)
    (user-error "Not a docker metrics buffer"))
  (unless docker-metrics--history
    (setq docker-metrics--history (make-hash-table :test 'equal)))
  (unless docker-metrics--host-mem
    (let ((info (docker-host-info docker-metrics--cfg)))
      (setq docker-metrics--host-mem
            (and info (cdr (assq 'MemTotal info))))))
  (let ((buf (current-buffer)))
    (docker-metrics-fetch-async
     docker-metrics--cfg docker-metrics--id
     (lambda (stats)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (docker-metrics--buffer-render stats)))))))

(defun docker-metrics--buffer-start-timer ()
  "(Re)start the metrics buffer's refresh timer."
  (docker-metrics--buffer-stop-timer)
  (let ((buf (current-buffer)))
    (setq docker-metrics--timer
          (run-at-time docker-metrics-refresh-interval
                       docker-metrics-refresh-interval
                       (lambda ()
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (docker-metrics-buffer-refresh))))))))

(defun docker-metrics-buffer (cfg id name)
  "Open and display the metrics buffer for container NAME (ID) via CFG."
  (let ((buf (get-buffer-create (format "*docker:metrics:%s*" name))))
    (with-current-buffer buf
      ;; Enter the mode only once — re-running it would orphan the
      ;; refresh timer and wipe the history hash mid-flight.
      (unless (derived-mode-p 'docker-metrics-mode)
        (docker-metrics-mode))
      (setq docker-metrics--cfg cfg
            docker-metrics--id id
            docker-metrics--name name)
      (docker-metrics-buffer-refresh)
      (docker-metrics--buffer-start-timer))
    (pop-to-buffer buf)
    (message "docker metrics: %s — g refreshes, q quits" name)))

(provide 'docker-metrics)
;;; docker-metrics.el ends here
