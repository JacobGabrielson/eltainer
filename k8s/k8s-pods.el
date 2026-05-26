;;; k8s-pods.el --- Interactive pod listing for eltainer -*- lexical-binding: t -*-
;;
;; Provides an interactive buffer showing all pods in the current
;; Kubernetes cluster, inspired by magit's section-based UI.
;;
;; Usage:
;;   M-x k8s-pods

(require 'cl-lib)
(require 'ansi-color)
(require 'magit-section)
(require 'docker-http)
(require 'k8s)
(require 'k8s-api)
(require 'k8s-dired)
(require 'k8s-metrics)

;; Declared up here so `k8s--insert-pod-details' (which reads the cache
;; to draw gauges) compiles without a free-variable warning; the
;; polling machinery that maintains them lives further down.
(defvar-local k8s--metrics-cache nil
  "Hash \"NS/POD\" -> ((CNAME . (CPU-MC . MEM-BYTES))...) for this buffer.
Populated by the metrics timer; read while rendering pod details to
draw per-container gauges.  nil means no metrics yet, or that
metrics-server is unavailable.")

(defvar-local k8s--summary-cache nil
  "Hash \"NS/POD\" -> kubelet Summary API pod entry, for this buffer.
Source of per-container disk usage and the raw network counters.
nil when the Summary API is unavailable.")

(defvar-local k8s--net-history nil
  "Hash \"NS/POD\" -> network-rate history plist (see `k8s-metrics-net-sample').
Persists across metrics polls so the network sparkline has a trend.")

(defvar-local k8s--cm-history nil
  "Hash \"NS/POD/CONTAINER\" -> cpu/mem history plist (see `k8s-metrics-cm-sample').
Persists across metrics polls so the cpu/mem trend sparklines have a trend.")

(defvar-local k8s--metrics-timer nil
  "Repeating timer polling metrics for this pods buffer.")

;;; ---------------------------------------------------------------------------
;;; Pod-specific helpers

(defun k8s--pod-phase (pod)
  "Return the phase (Running, Pending, Terminating, etc.) of POD.
Shows Terminating when deletionTimestamp is set (like kubectl does)."
  (if (cdr (assq 'deletionTimestamp (cdr (assq 'metadata pod))))
      "Terminating"
    (cdr (assq 'phase (cdr (assq 'status pod))))))

(defun k8s--pod-ip (pod)
  "Return the pod IP address."
  (cdr (assq 'podIP (cdr (assq 'status pod)))))

(defun k8s--pod-container-statuses (pod)
  "Return the vector of container statuses."
  (cdr (assq 'containerStatuses (cdr (assq 'status pod)))))

(defun k8s--pod-restarts (pod)
  "Return total restart count across all containers."
  (let ((statuses (k8s--pod-container-statuses pod))
        (total 0))
    (when statuses
      (seq-doseq (cs statuses)
        (cl-incf total (or (cdr (assq 'restartCount cs)) 0))))
    total))

(defun k8s--pod-ready-string (pod)
  "Return READY string like 1/2 for POD."
  (let ((statuses (k8s--pod-container-statuses pod)))
    (if statuses
        (let ((total (length statuses))
              (ready 0))
          (seq-doseq (cs statuses)
            (when (eq (cdr (assq 'ready cs)) t)
              (cl-incf ready)))
          (format "%d/%d" ready total))
      "0/0")))

;;; ---------------------------------------------------------------------------
;;; Section inserters

(defun k8s--insert-pod-line (pod)
  "Insert a single pod summary line as a section."
  (let* ((name (k8s--resource-name pod))
         (phase (k8s--pod-phase pod))
         (ready (k8s--pod-ready-string pod))
         (restarts (k8s--pod-restarts pod))
         (age (k8s--age-string (k8s--resource-creation-time pod)))
         (ip (or (k8s--pod-ip pod) "")))
    (magit-insert-section (pod pod t)
      (magit-insert-heading
        (format "  %-42s %-13s %-7s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize (or phase "?") 'font-lock-face (k8s--phase-face phase))
                ready
                (propertize (format "%d" restarts) 'font-lock-face 'k8s-dim)
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize ip 'font-lock-face 'k8s-dim)))
      ;; Collapsible detail body (hidden by default, expand with TAB)
      (k8s--insert-pod-details pod))))

(defun k8s--insert-pod-details (pod)
  "Insert expanded details for POD (containers, node, labels, metrics)."
  (let* ((spec (cdr (assq 'spec pod)))
         (node (or (cdr (assq 'nodeName spec)) "?"))
         (labels (k8s--resource-labels pod))
         (statuses (k8s--pod-container-statuses pod))
         (podkey (format "%s/%s"
                         (k8s--resource-namespace pod)
                         (k8s--resource-name pod)))
         (summary-pod (and k8s--summary-cache
                           (gethash podkey k8s--summary-cache))))
    ;; Node
    (insert (propertize (format "    Node:   %s\n" node)
                        'font-lock-face 'k8s-dim))
    ;; Labels
    (when labels
      (insert (propertize "    Labels: " 'font-lock-face 'k8s-dim))
      (let ((first t))
        (dolist (pair labels)
          (unless first (insert (propertize "            " 'font-lock-face 'k8s-dim)))
          (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                              'font-lock-face 'k8s-dim))
          (setq first nil))))
    ;; Network — pod-level (containers share a netns).
    (when k8s--net-history
      (when-let ((nl (k8s-metrics-pod-network-line
                      (gethash podkey k8s--net-history) "    ")))
        (insert nl)))
    ;; Containers — each as its own `container' subsection, so point
    ;; resting on one lets `l' / `e' / `f' target it directly.
    (when statuses
      (insert (propertize "    Containers:\n" 'font-lock-face 'k8s-dim))
      (seq-doseq (cs statuses)
        (let* ((cname (cdr (assq 'name cs)))
               (image (cdr (assq 'image cs)))
               (ready (cdr (assq 'ready cs)))
               (rc (or (cdr (assq 'restartCount cs)) 0))
               (per-cname (and k8s--metrics-cache
                               (gethash podkey k8s--metrics-cache)))
               (usage (and (hash-table-p per-cname)
                           (gethash cname per-cname)))
               (disk (and summary-pod
                          (k8s-metrics--summary-container-disk
                           summary-pod cname)))
               (cm-hist (and k8s--cm-history
                             (gethash (concat podkey "/" cname)
                                      k8s--cm-history))))
          (magit-insert-section (container cname)
            (insert (propertize
                     (format "      %-20s %-40s ready=%-5s restarts=%d\n"
                             cname
                             (or image "?")
                             (if (eq ready t) "yes" "no")
                             rc)
                     'font-lock-face 'k8s-dim))
            (when-let ((lines (k8s-metrics-container-lines
                               pod cname usage disk cm-hist)))
              (insert lines))))))
    (insert "\n")))

;;; ---------------------------------------------------------------------------
;;; Buffer refresh

(defun k8s--pods-refresh ()
  "Refresh the pods buffer content."
  (let* ((inhibit-read-only t)
         (ctx (k8s--save-point-context))
         (conn (k8s--ensure-connection))
         (pods (if (and k8s--resource-table
                        (> (hash-table-count k8s--resource-table) 0))
                   (vconcat (hash-table-values k8s--resource-table))
                 (k8s-list-pods conn k8s--namespace)))
         (grouped (k8s--group-by-namespace pods)))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-pods-root)
      (k8s--insert-header "Pods")
      (insert (propertize
               (format "  %-42s %-13s %-7s %-10s %-6s %s\n"
                       "NAME" "STATUS" "READY" "RESTARTS" "AGE" "IP")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (dolist (group grouped)
        (magit-insert-section (namespace (car group))
          (k8s--insert-namespace-heading (car group) (length (cdr group)))
          (dolist (pod (cdr group))
            (k8s--insert-pod-line pod))
          (insert "\n"))))
    ;; Cascade visibility: creates overlays for hidden sections
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (k8s--restore-point-context ctx)))

;;; ---------------------------------------------------------------------------
;;; Metrics polling
;;
;; Metrics are fetched on their own timer, *not* on the watch/event
;; refresh hot path (metrics-server only scrapes every ~15s anyway).
;; `k8s--insert-pod-details' just reads `k8s--metrics-cache' (declared
;; near the top of the file).

(defun k8s--metrics-stop ()
  "Stop metrics polling for the current pods buffer."
  (when (timerp k8s--metrics-timer)
    (cancel-timer k8s--metrics-timer))
  (setq k8s--metrics-timer nil))

(defun k8s--metrics-update-net-history (summary)
  "Fold the network counters in SUMMARY into `k8s--net-history'."
  (unless k8s--net-history
    (setq k8s--net-history (make-hash-table :test 'equal)))
  (let ((now (float-time)))
    (maphash
     (lambda (key pod-entry)
       (let ((net (k8s-metrics--summary-network pod-entry)))
         (when net
           (k8s-metrics-net-sample k8s--net-history key
                                   (car net) (cdr net) now))))
     summary)))

(defun k8s--metrics-update-cm-history (metrics)
  "Fold the per-container cpu/mem in METRICS into `k8s--cm-history'.
METRICS is the hash from `k8s-metrics-collect': \"NS/POD\" ->
hash-of CNAME -> (CPU . MEM)."
  (unless k8s--cm-history
    (setq k8s--cm-history (make-hash-table :test 'equal)))
  (maphash
   (lambda (podkey per-cname)
     (when (hash-table-p per-cname)
       (maphash (lambda (cname usage)
                  (k8s-metrics-cm-sample
                   k8s--cm-history
                   (concat podkey "/" cname)
                   (car usage) (cdr usage)))
                per-cname)))
   metrics))

(defun k8s--metrics-tick (buf)
  "Poll metrics for BUF and re-render.
Fetches both metrics-server CPU/memory and the kubelet Summary API
\(disk + network).  Each source degrades independently; polling
stops only when neither is available."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (derived-mode-p 'k8s-pods-mode)
        (condition-case err
            (let* ((conn (k8s--ensure-connection))
                   (m (k8s-metrics-collect conn k8s--namespace))
                   (s (k8s-metrics-collect-summary conn)))
              (when m
                (setq k8s--metrics-cache m)
                (k8s--metrics-update-cm-history m))
              (when s
                (setq k8s--summary-cache s)
                (k8s--metrics-update-net-history s))
              (cond
               ((or m s) (revert-buffer nil t))
               (t ;; nothing available — stop polling, say so once.
                (k8s--metrics-stop)
                (message
                 "k8s metrics: metrics-server / kubelet stats unavailable; \
gauges disabled"))))
          (error
           (message "k8s metrics: %s" (error-message-string err))))))))

(defun k8s--metrics-start ()
  "Begin metrics polling for the current pods buffer."
  (k8s--metrics-stop)
  (let ((buf (current-buffer)))
    ;; Immediate first poll so gauges appear without a full interval's wait.
    (run-at-time 0.2 nil #'k8s--metrics-tick buf)
    (setq k8s--metrics-timer
          (run-at-time k8s-metrics-refresh-interval
                       k8s-metrics-refresh-interval
                       #'k8s--metrics-tick buf)))
  (add-hook 'kill-buffer-hook #'k8s--metrics-stop nil t))

;;; ---------------------------------------------------------------------------
;;; Pod log viewer

(defun k8s--pod-container-names (pod)
  "Return a list of container names from POD spec."
  (let ((containers (cdr (assq 'containers (cdr (assq 'spec pod))))))
    (when containers
      (mapcar (lambda (c) (cdr (assq 'name c)))
              (append containers nil)))))

(defun k8s--pod-default-container (pod containers)
  "Return the default container name for POD given its CONTAINERS list.
Honors the `kubectl.kubernetes.io/default-container' annotation when it
names a real container (this is what `kubectl' itself defaults to);
otherwise falls back to the first container in the spec."
  (let ((annotated
         (cdr (assq 'kubectl.kubernetes.io/default-container
                    (cdr (assq 'annotations (cdr (assq 'metadata pod))))))))
    (if (and annotated (member annotated containers))
        annotated
      (car containers))))

;;; --- Container picker buffer -----------------------------------------------
;;
;; A self-contained picker buffer (like the `b' kubeconfig-context
;; picker) rather than `completing-read' — so it works identically no
;; matter what, or whether, the user has a minibuffer completion UI
;; (vertico / fido / plain) configured.  `k8s--read-pod-container'
;; pops the buffer and blocks in `recursive-edit'; RET / q hand the
;; result back through `k8s--container-pick-choice'.

(defvar k8s--container-pick-choice nil
  "Internal carrier for the container chosen in the picker buffer.
Dynamically bound by `k8s--read-pod-container' and set by the
picker commands while its `recursive-edit' is active.")

(defvar-keymap k8s-container-picker-mode-map
  :parent special-mode-map
  "RET" #'k8s-container-pick-select
  "n"   #'next-line
  "p"   #'previous-line
  "j"   #'next-line
  "k"   #'previous-line
  "q"   #'k8s-container-pick-cancel)

(define-derived-mode k8s-container-picker-mode special-mode "K8s:Container"
  "Picker buffer for choosing a container in a multi-container pod."
  (setq-local truncate-lines t))

(defun k8s-container-pick-select ()
  "Select the container on the current line and end the picker."
  (interactive)
  (let ((c (get-text-property (line-beginning-position) 'k8s-container)))
    (unless c (user-error "Not on a container line"))
    (setq k8s--container-pick-choice c)
    (exit-recursive-edit)))

(defun k8s-container-pick-cancel ()
  "Cancel the container picker."
  (interactive)
  (setq k8s--container-pick-choice nil)
  (exit-recursive-edit))

(defun k8s--pod+container-at-point ()
  "Resolve the section at point to a (POD . CONTAINER) cons.
POD is the pod alist.  CONTAINER is a container-name string when
point rests on a `container' subsection inside an expanded pod, or
nil when point is on the `pod' line itself (the caller then picks a
container).  Signals a `user-error' when point is on neither."
  (let ((sec (magit-current-section)))
    (unless sec (user-error "Not on a pod"))
    (pcase (oref sec type)
      ('container
       (let ((cname (oref sec value))
             (anc (oref sec parent)))
         (while (and anc (not (eq (oref anc type) 'pod)))
           (setq anc (oref anc parent)))
         (unless anc (user-error "Container section has no parent pod"))
         (cons (oref anc value) cname)))
      ('pod (cons (oref sec value) nil))
      (_ (user-error "Not on a pod or container")))))

(defun k8s--read-pod-container (action ns pod-name pod containers)
  "Read a container name for ACTION on pod NS/POD-NAME.
Single-container pods return their only container with no prompt.
For multi-container pods, pops a picker buffer listing every
container — the default (the `kubectl.kubernetes.io/default-container'
annotation, else the first spec container) listed first and tagged,
with point on it so a bare RET selects it.  Navigate with n/p, q
cancels."
  (if (= 1 (length containers))
      (car containers)
    (let* ((default (k8s--pod-default-container pod containers))
           (ordered (cons default (remove default containers)))
           (buf (get-buffer-create "*eltainer:container*"))
           (k8s--container-pick-choice nil)
           (saved-config (current-window-configuration)))
      (with-current-buffer buf
        (k8s-container-picker-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize
                   (format "%s — choose a container in %s/%s\n"
                           action ns pod-name)
                   'font-lock-face 'k8s-section-heading))
          (insert (propertize "  RET select   n/p move   q cancel\n\n"
                              'font-lock-face 'k8s-dim))
          (dolist (c ordered)
            (let ((start (point)))
              (insert "  "
                      (propertize c 'font-lock-face 'k8s-resource-name)
                      (if (equal c default)
                          (propertize "   (default)" 'font-lock-face 'k8s-dim)
                        "")
                      "\n")
              (add-text-properties start (point)
                                   (list 'k8s-container c))))
          ;; Point on the first (default) container row.
          (goto-char (point-min))
          (forward-line 3)))
      (let ((win (display-buffer
                  buf '((display-buffer-below-selected)
                        (window-height . fit-window-to-buffer)))))
        (select-window win)
        (unwind-protect
            (recursive-edit)
          (set-window-configuration saved-config)
          (when (buffer-live-p buf) (kill-buffer buf))))
      (or k8s--container-pick-choice
          (user-error "Container selection cancelled")))))

(defvar-local k8s--log-conn nil "Connection for log buffer.")
(defvar-local k8s--log-ns nil "Namespace for log buffer.")
(defvar-local k8s--log-pod nil "Pod name for log buffer.")
(defvar-local k8s--log-container nil "Container name for log buffer.")
(defvar-local k8s--log-process nil "Streaming HTTP process for this buffer.")

(defun k8s--log-cleanup ()
  "Tear down the streaming process attached to the current buffer."
  (when (process-live-p k8s--log-process)
    (delete-process k8s--log-process))
  (setq k8s--log-process nil))

(defun k8s--log-append (buf bytes)
  "Append BYTES to BUF, autoscrolling if point was at the end.
ANSI colour escapes in BYTES are translated to text properties via
`ansi-color-apply-on-region', which is stateful across calls (it
buffers partial escapes that span chunk boundaries) so the ^[[…m
junk doesn't leak through."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (at-end (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (let ((beg (point)))
            (insert bytes)
            (ansi-color-apply-on-region beg (point))))
        (when at-end (goto-char (point-max)))))))

(defun k8s--log-start (&optional tail-lines)
  "Open a streaming connection for the current log buffer.
TAIL-LINES bounds the initial history (default 500)."
  (k8s--log-cleanup)
  (let* ((cfg (k8s-connection-docker-cfg k8s--log-conn))
         (path (format "/api/v1/namespaces/%s/pods/%s/log"
                       k8s--log-ns k8s--log-pod))
         (query `(("follow" . "true")
                  ("tailLines" . ,(number-to-string (or tail-lines 500)))
                  ,@(when k8s--log-container
                      `(("container" . ,k8s--log-container)))))
         (buf (current-buffer)))
    (let ((inhibit-read-only t)) (erase-buffer))
    (setq k8s--log-process
          (docker-http-stream
           cfg "GET" path
           :query query
           ;; No Accept override — the k8s API server returns 406 when
           ;; asked for text/plain even though the /log endpoint
           ;; happens to emit plain text for success.  Use the default
           ;; `application/json' from `default-headers'; for /log the
           ;; server still sends raw stdout text.
           :on-chunk (lambda (bytes) (k8s--log-append buf bytes))
           :on-close (lambda ()
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (let ((inhibit-read-only t))
                             (save-excursion
                               (goto-char (point-max))
                               (insert "\n[stream closed]\n"))))))))))

(defun k8s--log-restart ()
  "Restart the streaming connection for this buffer."
  (interactive)
  (unless (and k8s--log-conn k8s--log-ns k8s--log-pod)
    (user-error "Not a k8s log buffer"))
  (k8s--log-start))

(defun k8s--log-quit ()
  "Stop the log stream and quit the window."
  (interactive)
  (k8s--log-cleanup)
  (quit-window t))

(defvar-keymap k8s-log-mode-map
  :parent special-mode-map
  "g" #'k8s--log-restart
  "G" #'end-of-buffer
  "q" #'k8s--log-quit)

(define-derived-mode k8s-log-mode special-mode "K8s:Log"
  "Major mode for streaming Kubernetes pod logs.

\\{k8s-log-mode-map}"
  :group 'k8s
  (setq-local truncate-lines nil)
  (hl-line-mode 1)
  (add-hook 'kill-buffer-hook #'k8s--log-cleanup nil t))

;; Defined in k8s-marks.el / k8s-multilog.el (k8s requires them).
(declare-function k8s--marked-resources         "k8s-marks")
(declare-function k8s-multilog-start-with-pods  "k8s-multilog")

(defun k8s-pods-multilog-marked ()
  "Tail logs from every marked pod in a single multilog buffer.
Mark pods with `m'; `L' here aggregates them into one
`*k8s:multilog:*' buffer with per-pod colour-coded prefixes.
Marked pods may span namespaces — each prefix carries the pod's
own namespace."
  (interactive)
  (unless (derived-mode-p 'k8s-pods-mode)
    (user-error "Not in a pods buffer"))
  (let ((marked (k8s--marked-resources)))
    (unless marked
      (user-error "No pods marked — `m' marks the pod at point"))
    (let ((conn (k8s--ensure-connection)))
      (k8s-multilog-start-with-pods
       conn marked 'marked
       (format "%d-pods" (length marked))))))

(defun k8s--open-pod-log-buffer (conn ns pod-name container)
  "Open a streaming-logs buffer for NS/POD-NAME[CONTAINER] via CONN.
Shared entry point for the pods view's `l' and the CronJobs view's
last-run-logs action."
  (let ((buf (get-buffer-create
              (format "*k8s:logs:%s/%s[%s]*" ns pod-name container))))
    (with-current-buffer buf
      (k8s-log-mode)
      (setq k8s--log-conn conn
            k8s--log-ns ns
            k8s--log-pod pod-name
            k8s--log-container container)
      (k8s--log-start))
    (pop-to-buffer buf)
    (message "Streaming %s/%s[%s] — g=restart, q=quit" ns pod-name container)))

(defun k8s-pod-view-logs ()
  "Show tailing logs for the pod at point.
With point on a container subsection (inside an expanded pod), logs
that container directly; on the pod line, picks a container."
  (interactive)
  (let* ((target (k8s--pod+container-at-point))
         (pod (car target))
         (preselected (cdr target))
         (name (k8s--resource-name pod))
         (ns (k8s--resource-namespace pod))
         (containers (k8s--pod-container-names pod))
         (container (or preselected
                        (and containers
                             (k8s--read-pod-container "Logs for" ns name
                                                      pod containers))))
         (conn (k8s--ensure-connection)))
    (k8s--open-pod-log-buffer conn ns name container)))

(defun k8s-pod-exec-at-point ()
  "Open an interactive TTY exec into the pod at point.

With point on a container subsection (inside an expanded pod) that
container is used directly.  Otherwise, for multi-container pods a
picker buffer chooses the container; single-container pods skip it.

Then prompts for the command to run, pre-filled with `/bin/sh'.
Accepting that default (a bare RET) triggers a shell probe — eltainer
tries each entry in `k8s-exec-shell-candidates' and execs the first
that exists, so the default still works on images whose shell isn't
at /bin/sh.  Type anything else to run it verbatim."
  (interactive)
  (require 'k8s-exec)
  (let* ((target (k8s--pod+container-at-point))
         (pod (car target))
         (preselected (cdr target)))
    (let* ((name (k8s--resource-name pod))
           (ns (k8s--resource-namespace pod))
           (containers (k8s--pod-container-names pod))
           (container (or preselected
                          (and containers
                               (k8s--read-pod-container "Exec" ns name
                                                        pod containers))))
           (conn (k8s--ensure-connection))
           (input (read-shell-command (format "Exec in %s/%s: " ns name)
                                      "/bin/sh"))
           (cmd
            (if (equal input "/bin/sh")
                ;; The default — find a shell that actually exists.
                (progn
                  (message "k8s exec: probing for a shell in %s/%s ..."
                           ns name)
                  (let ((shell (k8s-exec-find-shell conn ns name container)))
                    (unless shell
                      (user-error
                       "No shell in %s/%s: tried %s.  Image is likely \
distroless/scratch — re-run `e' and type a binary the image ships, \
or `kubectl debug --image=busybox -it %s --target=%s'"
                       ns name
                       (mapconcat #'identity k8s-exec-shell-candidates ", ")
                       name (or container "<container>")))
                    (message "k8s exec: using %s" shell)
                    (list shell)))
              (split-string-shell-command input))))
      (k8s-exec-interactive conn ns name container cmd))))

(defun k8s-pod-metrics-at-point ()
  "Open the metrics buffer for the pod at point.
Works on a pod line or a container subsection — the metrics buffer
covers every container in the pod either way."
  (interactive)
  (let* ((target (k8s--pod+container-at-point))
         (pod (car target)))
    (k8s-metrics-buffer (k8s--ensure-connection)
                        (k8s--resource-namespace pod)
                        (k8s--resource-name pod))))

;;; ---------------------------------------------------------------------------
;;; Major mode

;; Inherit shared k8s view keys via :parent (`k8s-common-map' is
;; defined in k8s-marks.el, which loads before any view file);
;; pod-specific keys layered on top.  Plain `defvar' rather than
;; `defvar-keymap' so the bindings below — and the parent link —
;; re-install idempotently on every `eltainer-reload'.
(defvar k8s-pods-mode-map (make-sparse-keymap)
  "Keymap for `k8s-pods-mode'.")
(set-keymap-parent k8s-pods-mode-map k8s-common-map)
(pcase-dolist (`(,k ,cmd)
               '(("l" k8s-pod-view-logs)
                 ("e" k8s-pod-exec-at-point)
                 ("f" k8s-dired-browse-at-point)
                 ("M" k8s-pod-metrics-at-point)
                 ("L" k8s-pods-multilog-marked)))
  (keymap-set k8s-pods-mode-map k cmd))

(define-derived-mode k8s-pods-mode magit-section-mode "K8s:Pods"
  "Major mode for viewing Kubernetes pods.

\\{k8s-pods-mode-map}"
  :interactive nil
  :group 'k8s
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (k8s--pods-refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              '(:eval (k8s--watch-mode-line)) "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces))
  (add-hook 'kill-buffer-hook #'k8s--watch-stop-for-buffer nil t))

;;; ---------------------------------------------------------------------------
;;; Interactive command

;;;###autoload
(defun k8s-pods ()
  "Display all pods in the current Kubernetes cluster."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:pods*")))
    (with-current-buffer buf
      (k8s-pods-mode)
      (k8s--ensure-connection)
      (setq k8s--api-path-fn
            (lambda (ns) (k8s--list-path 'pods ns)))
      (k8s--pods-refresh)
      (k8s--metrics-start))
    (pop-to-buffer buf)))

(provide 'k8s-pods)
;;; k8s-pods.el ends here
