;;; docker-pulse.el --- Single-host docker pulse dashboard -*- lexical-binding: t -*-
;;
;; `M-x docker-pulse' (or `p' on the dashboard) opens `*docker:pulse*'
;; — a one-buffer health summary for the local docker daemon.
;; Mirrors the k8s cluster-pulse view but for a single docker host.
;;
;; Sections:
;; - Containers by state (running / paused / exited / restarting / …)
;; - Stacks summary (count of compose projects, totally / partially up)
;; - Top CPU + memory consumers among running containers
;; - Disk usage from `/system/df' (containers + images + volumes +
;;   build-cache layers)
;; - Daemon info (version, OS, total memory)

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'eltainer-gauge)
(require 'docker-config)
(require 'docker-api)
(require 'docker-ps)
(require 'docker-stacks)
(require 'docker-metrics)
(require 'docker)

(defgroup docker-pulse nil
  "Single-host docker pulse dashboard."
  :group 'docker
  :prefix "docker-pulse-")

(defcustom docker-pulse-top-consumers 5
  "Number of rows in Top CPU / Top memory lists."
  :type 'integer :group 'docker-pulse)

(defcustom docker-pulse-refresh-interval 30
  "Seconds between auto-refreshes of the docker-pulse buffer."
  :type 'integer :group 'docker-pulse)

;;; ---------------------------------------------------------------------------
;;; Data collection

(defun docker-pulse--state-counts (containers)
  "Return `((STATE . COUNT) ...)' from CONTAINERS, count-desc."
  (let ((tbl (make-hash-table :test 'equal)))
    (seq-doseq (c containers)
      (let ((s (or (docker-container-state c) "unknown")))
        (puthash s (1+ (gethash s tbl 0)) tbl)))
    (let (out)
      (maphash (lambda (k v) (push (cons k v) out)) tbl)
      (sort out (lambda (a b)
                  (or (> (cdr a) (cdr b))
                      (and (= (cdr a) (cdr b))
                           (string< (car a) (car b)))))))))

(defun docker-pulse--stack-summary (stacks)
  "Return (TOTAL UP-FULLY DOWN-OR-PARTIAL)."
  (let ((up 0) (mixed 0))
    (dolist (s stacks)
      (let* ((entry (cdr s))
             (total (plist-get entry :total))
             (running (plist-get entry :running)))
        (cond ((and (> total 0) (= running total)) (cl-incf up))
              (t (cl-incf mixed)))))
    (list (length stacks) up mixed)))

(defun docker-pulse--cpu-percent (stats)
  "Compute CPU% from a `?stream=false' /stats response.
Engine includes both `cpu_stats' (now) and `precpu_stats' (one
tick earlier) in the same payload, so a single call is enough."
  (let* ((cs (cdr (assq 'cpu_stats stats)))
         (ps (cdr (assq 'precpu_stats stats)))
         (total (cdr (assq 'total_usage (cdr (assq 'cpu_usage cs)))))
         (ptotal (cdr (assq 'total_usage (cdr (assq 'cpu_usage ps)))))
         (system (cdr (assq 'system_cpu_usage cs)))
         (psystem (cdr (assq 'system_cpu_usage ps)))
         (ncpu (or (cdr (assq 'online_cpus cs)) 1))
         (cd (when (and total ptotal) (- total ptotal)))
         (sd (when (and system psystem) (- system psystem))))
    (if (and cd sd (> sd 0) (>= cd 0))
        (* 100.0 (/ (float cd) sd) ncpu)
      0.0)))

(defun docker-pulse--collect-stats (cfg containers)
  "Synchronously gather per-container CPU and memory stats.
Returns a list of plists `(:name :id :cpu-pct :mem-bytes :mem-pct)'.
Skips non-running containers (they have no live stats)."
  (let (out)
    (seq-doseq (c containers)
      (when (equal (docker-container-state c) "running")
        (let* ((id (docker-container-id c))
               (stats (condition-case nil
                          (docker-engine-get
                           cfg
                           (format "/containers/%s/stats" id)
                           :query '(("stream" . "false")))
                        (error nil))))
          (when stats
            (let* ((cpu (docker-pulse--cpu-percent stats))
                   (mem-bytes (or (cdr (assq 'usage (cdr (assq 'memory_stats stats)))) 0))
                   (mem-limit (or (cdr (assq 'limit (cdr (assq 'memory_stats stats)))) 0))
                   (mem-pct (if (and (> mem-limit 0)
                                      (not (zerop mem-limit)))
                                (* 100.0 (/ mem-bytes (float mem-limit)))
                              0.0)))
              (push (list :name (docker-container-name c)
                          :id id :cpu-pct cpu
                          :mem-bytes mem-bytes
                          :mem-pct mem-pct)
                    out))))))
    out))

(defun docker-pulse--disk-usage (cfg)
  "Return docker daemon's `/system/df' info or nil."
  (condition-case _err
      (docker-engine-get cfg "/system/df")
    (error nil)))

(defun docker-pulse--version (cfg)
  (condition-case _err
      (docker-engine-get cfg "/version")
    (error nil)))

(defun docker-pulse--info (cfg)
  (condition-case _err
      (docker-engine-get cfg "/info")
    (error nil)))

;;; ---------------------------------------------------------------------------
;;; Rendering helpers

(defun docker-pulse--state-face (state)
  (cond
   ((equal state "running")     'eltainer-status-running)
   ((member state '("paused" "restarting" "created"))
    'eltainer-status-warn)
   ((member state '("exited" "dead" "removing"))
    'eltainer-status-error)
   (t 'eltainer-status-other)))

(defun docker-pulse--insert-state-row (state count max)
  (let* ((width 14)
         (frac (if (and max (> max 0)) (/ (float count) max) 0.0))
         (filled (round (* width frac))))
    (insert (format "  %-14s %5d  "
                    (propertize state 'font-lock-face
                                (docker-pulse--state-face state))
                    count))
    (insert (propertize (make-string filled ?█)
                        'font-lock-face (docker-pulse--state-face state)))
    (insert (propertize (make-string (- width filled) ?·)
                        'font-lock-face 'eltainer-dim))
    (insert "\n")))

(defun docker-pulse--insert-top-row (row metric)
  (let ((value (plist-get row metric))
        (name (plist-get row :name)))
    (insert (format "  %-12s %s\n"
                    (cond
                     ((eq metric :cpu-pct)
                      (propertize (format "%5.1f%%" value)
                                  'font-lock-face 'eltainer-resource-name))
                     (t
                      (propertize (eltainer-human-bytes
                                   (or (plist-get row :mem-bytes) 0))
                                  'font-lock-face 'eltainer-resource-name)))
                    (propertize name 'font-lock-face 'eltainer-dim)))))

(defun docker-pulse--insert-df (df)
  "Render `/system/df' summary DF."
  (when df
    (let* ((layers (cdr (assq 'LayersSize df)))
           (images (append (or (cdr (assq 'Images df)) []) nil))
           (containers (append (or (cdr (assq 'Containers df)) []) nil))
           (volumes (append (or (cdr (assq 'Volumes df)) []) nil))
           (bcache (append (or (cdr (assq 'BuildCache df)) []) nil))
           (sum (lambda (key items)
                  (apply #'+ (mapcar (lambda (i) (or (cdr (assq key i)) 0))
                                     items)))))
      (insert (format "  %-18s %12s   (%d objects)\n"
                      (propertize "Images" 'font-lock-face 'eltainer-resource-name)
                      (eltainer-human-bytes (or layers (funcall sum 'Size images)))
                      (length images)))
      (insert (format "  %-18s %12s   (%d objects)\n"
                      (propertize "Containers" 'font-lock-face 'eltainer-resource-name)
                      (eltainer-human-bytes (funcall sum 'SizeRw containers))
                      (length containers)))
      (insert (format "  %-18s %12s   (%d objects)\n"
                      (propertize "Volumes" 'font-lock-face 'eltainer-resource-name)
                      (eltainer-human-bytes
                       (apply #'+
                              (mapcar
                               (lambda (v)
                                 (or (cdr (assq 'Size (cdr (assq 'UsageData v))))
                                     0))
                               volumes)))
                      (length volumes)))
      (when bcache
        (insert (format "  %-18s %12s   (%d objects)\n"
                        (propertize "Build cache" 'font-lock-face 'eltainer-resource-name)
                        (eltainer-human-bytes (funcall sum 'Size bcache))
                        (length bcache)))))))

;;; ---------------------------------------------------------------------------
;;; Refresh

(defvar-local docker-pulse--timer nil)

(defun docker-pulse-refresh ()
  "Re-collect everything and re-render the pulse buffer."
  (interactive)
  (let* ((cfg (docker--ensure-config))
         (containers (docker-list-containers cfg :all t))
         (states (docker-pulse--state-counts containers))
         (max-state-count (apply #'max 0 (mapcar #'cdr states)))
         (stacks (docker-stacks-collect cfg))
         (stack-sum (docker-pulse--stack-summary stacks))
         (top-rows (and docker-pulse-top-consumers
                        (docker-pulse--collect-stats cfg containers)))
         (top-cpu (and top-rows
                       (seq-take
                        (sort (copy-sequence top-rows)
                              (lambda (a b)
                                (> (or (plist-get a :cpu-pct) 0)
                                   (or (plist-get b :cpu-pct) 0))))
                        docker-pulse-top-consumers)))
         (top-mem (and top-rows
                       (seq-take
                        (sort (copy-sequence top-rows)
                              (lambda (a b)
                                (> (or (plist-get a :mem-bytes) 0)
                                   (or (plist-get b :mem-bytes) 0))))
                        docker-pulse-top-consumers)))
         (df (docker-pulse--disk-usage cfg))
         (info (docker-pulse--info cfg))
         (version (docker-pulse--version cfg))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (docker-pulse-root)
      (insert (propertize "Docker pulse\n" 'font-lock-face 'eltainer-section-heading))
      (when version
        (insert (propertize
                 (format "  Engine %s · API %s · %s\n\n"
                         (or (cdr (assq 'Version version)) "?")
                         (or (cdr (assq 'ApiVersion version)) "?")
                         (or (cdr (assq 'Os version)) "?"))
                 'font-lock-face 'eltainer-dim)))
      ;; Containers
      (magit-insert-section (docker-pulse-containers)
        (magit-insert-heading
          (propertize (format "Containers (%d)\n" (length containers))
                      'font-lock-face 'eltainer-section-heading))
        (if (null states)
            (insert (propertize "  (none)\n" 'font-lock-face 'eltainer-dim))
          (dolist (sc states)
            (docker-pulse--insert-state-row (car sc) (cdr sc) max-state-count)))
        (insert "\n"))
      ;; Stacks
      (magit-insert-section (docker-pulse-stacks)
        (magit-insert-heading
          (propertize "Stacks\n" 'font-lock-face 'eltainer-section-heading))
        (insert (format "  %-16s %5d\n"
                        (propertize "Total" 'font-lock-face 'eltainer-dim)
                        (nth 0 stack-sum)))
        (insert (format "  %-16s %5d\n"
                        (propertize "Fully up" 'font-lock-face 'eltainer-status-running)
                        (nth 1 stack-sum)))
        (when (> (nth 2 stack-sum) 0)
          (insert (format "  %-16s %5d\n"
                          (propertize "Partial / down" 'font-lock-face 'eltainer-status-warn)
                          (nth 2 stack-sum))))
        (insert "\n"))
      ;; Disk usage
      (when df
        (magit-insert-section (docker-pulse-df)
          (magit-insert-heading
            (propertize "Disk usage (system df)\n"
                        'font-lock-face 'eltainer-section-heading))
          (docker-pulse--insert-df df)
          (insert "\n")))
      ;; Top consumers
      (when top-cpu
        (magit-insert-section (docker-pulse-top-cpu)
          (magit-insert-heading
            (propertize (format "Top %d CPU consumers\n"
                                docker-pulse-top-consumers)
                        'font-lock-face 'eltainer-section-heading))
          (dolist (row top-cpu)
            (docker-pulse--insert-top-row row :cpu-pct))
          (insert "\n")))
      (when top-mem
        (magit-insert-section (docker-pulse-top-mem)
          (magit-insert-heading
            (propertize (format "Top %d memory consumers\n"
                                docker-pulse-top-consumers)
                        'font-lock-face 'eltainer-section-heading))
          (dolist (row top-mem)
            (docker-pulse--insert-top-row row :mem-bytes))
          (insert "\n")))
      ;; Daemon info footer
      (when info
        (let ((kernel (cdr (assq 'KernelVersion info)))
              (cpus (cdr (assq 'NCPU info)))
              (mem (cdr (assq 'MemTotal info))))
          (insert (propertize
                   (format "Host: %d CPUs, %s RAM · kernel %s\n"
                           (or cpus 0)
                           (if mem (eltainer-human-bytes mem) "?")
                           (or kernel "?"))
                   'font-lock-face 'eltainer-dim)))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Mode + entry

(defvar docker-pulse-mode-map (make-sparse-keymap))
(defvar docker-common-map)
(set-keymap-parent docker-pulse-mode-map
                   (or (bound-and-true-p docker-common-map)
                       (make-sparse-keymap)))
(keymap-set docker-pulse-mode-map "g" #'docker-pulse-refresh)

(define-derived-mode docker-pulse-mode magit-section-mode "Docker:Pulse"
  "Single-host docker pulse dashboard.

\\{docker-pulse-mode-map}"
  :interactive nil
  :group 'docker-pulse
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function (lambda (_a _b) (docker-pulse-refresh)))
  (add-hook 'kill-buffer-hook #'docker-pulse--stop-timer nil t))

(defun docker-pulse--stop-timer ()
  (when (timerp docker-pulse--timer)
    (cancel-timer docker-pulse--timer))
  (setq docker-pulse--timer nil))

;;;###autoload
(defun docker-pulse ()
  "Open the single-host docker pulse dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*docker:pulse*")))
    (with-current-buffer buf
      (docker-pulse-mode)
      (docker-pulse-refresh)
      (docker-pulse--stop-timer)
      (setq docker-pulse--timer
            (run-at-time docker-pulse-refresh-interval
                         docker-pulse-refresh-interval
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (condition-case err
                                   (docker-pulse-refresh)
                                 (error
                                  (message
                                   "docker-pulse: refresh failed: %s"
                                   (error-message-string err))))))))))
    (pop-to-buffer buf)))

(provide 'docker-pulse)
;;; docker-pulse.el ends here
