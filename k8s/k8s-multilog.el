;;; k8s-multilog.el --- Multi-pod log tail for k8s workloads -*- lexical-binding: t -*-
;;
;; `stern'-style: a single buffer that follows every selected pod's
;; stdout/stderr, interleaved by arrival, each pod prefix-tagged in a
;; distinct colour.  Reuses the existing streaming HTTP transport
;; (`docker-http-stream') so there's no external `stern' binary.
;;
;; Triggered from the deployment / statefulset / daemonset / job /
;; service views (see `k8s--multilog-at-point' in k8s.el).
;;
;; See `docs/multipod-logs-plan.md' for the full design.

(require 'cl-lib)
(require 'ansi-color)
(require 'docker-http)
(require 'docker-stream)
(require 'k8s-api)

;; k8s.el requires k8s-multilog, so we can't `require' k8s here
;; without a cycle.  declare-function silences the byte-compile
;; warning; the symbol resolves at call time once k8s.el is loaded.
(declare-function k8s--resource-name       "k8s")
(declare-function k8s--resource-namespace  "k8s")

(defun k8s-multilog--first-container (pod)
  "Return the first container name from POD's spec, or nil.
Inlined here rather than calling `k8s--pod-container-names' so
this module doesn't depend on k8s-pods.el (which would create a
require cycle: k8s -> k8s-multilog -> k8s-pods -> k8s)."
  (let ((containers (cdr (assq 'containers (cdr (assq 'spec pod))))))
    (cond
     ((and (vectorp containers) (> (length containers) 0))
      (cdr (assq 'name (aref containers 0))))
     ((and (listp containers) containers)
      (cdr (assq 'name (car containers)))))))

(defgroup k8s-multilog nil
  "Multi-pod log tailing for Kubernetes workloads."
  :group 'k8s
  :prefix "k8s-multilog-")

(defcustom k8s-multilog-max-pods 10
  "Soft cap on how many pods a single multilog buffer tails by default.
When a workload has more pods than this, eltainer prompts before
opening that many concurrent log streams."
  :type 'integer
  :group 'k8s-multilog)

(defcustom k8s-multilog-tail-lines 100
  "Initial line count requested from each pod's `/log' endpoint."
  :type 'integer
  :group 'k8s-multilog)

(defcustom k8s-multilog-timestamps t
  "Non-nil to pass `timestamps=true' to the K8s log endpoint.
The apiserver then prefixes each line with an RFC3339 stamp,
which makes inter-pod ordering legible even though streams
interleave by arrival."
  :type 'boolean
  :group 'k8s-multilog)

;;; ---------------------------------------------------------------------------
;;; Colour palette
;;
;; Sasha Trubetskoy's "20 simple distinct colors"
;; <https://sashamaps.net/docs/resources/20-colors/> — vetted for
;; qualitative legibility across viz libs (Bokeh, Plotly, observable).
;; First 12: avoids red/green confusion + drops the lighter pastels
;; that read poorly on white.

(defconst k8s-multilog--palette
  '(("#e6194B" . "red")
    ("#3cb44b" . "green")
    ("#4363d8" . "blue")
    ("#f58231" . "orange")
    ("#911eb4" . "purple")
    ("#42d4f4" . "cyan")
    ("#f032e6" . "magenta")
    ("#bfef45" . "lime")
    ("#469990" . "teal")
    ("#9A6324" . "brown")
    ("#800000" . "maroon")
    ("#aaffc3" . "mint")))

(defconst k8s-multilog--palette-size (length k8s-multilog--palette))

;; Pre-define the 12 faces.  Generated to keep the source compact.
(dotimes (i k8s-multilog--palette-size)
  (let* ((entry (nth i k8s-multilog--palette))
         (hex (car entry))
         (name (cdr entry))
         (sym (intern (format "k8s-multilog-pod-%d" (1+ i)))))
    (eval `(defface ,sym
             '((t :foreground ,hex :weight bold))
             ,(format "Pod-prefix colour slot %d (%s) for `k8s-multilog'."
                      (1+ i) name)
             :group 'k8s-multilog))))

(defun k8s-multilog--face-for-slot (n)
  "Return the face for pod slot N (1-based).
Cycles through `k8s-multilog--palette' past the 12th pod."
  (let ((cycle (mod (1- n) k8s-multilog--palette-size)))
    (intern (format "k8s-multilog-pod-%d" (1+ cycle)))))

;;; ---------------------------------------------------------------------------
;;; Line splitter
;;
;; Same shape as `docker-stream-make-ndjson' (PR-2's scratch-buffer +
;; finalizer pattern), but split on `\n' and pass the raw decoded
;; line string instead of parsing JSON.  The closure recognises a
;; `cleanup' sentinel for prompt release; a finalizer also runs on GC.

(defun k8s-multilog--make-line-splitter (on-line)
  "Return a closure that splits incoming bytes into lines and calls ON-LINE.
ON-LINE is `(lambda (LINE-STRING))'.  Lines are UTF-8 decoded
before being handed off."
  (let* ((scratch (let ((b (generate-new-buffer " *k8s-multilog-split*" t)))
                    (with-current-buffer b (set-buffer-multibyte nil))
                    b))
         (finalizer (make-finalizer
                     (lambda ()
                       (when (buffer-live-p scratch)
                         (kill-buffer scratch))))))
    (lambda (bytes)
      (ignore finalizer)
      (cond
       ((eq bytes 'cleanup)
        (when (buffer-live-p scratch) (kill-buffer scratch)))
       ((null bytes) nil)
       ((buffer-live-p scratch)
        (with-current-buffer scratch
          (goto-char (point-max))
          (insert bytes)
          (goto-char (point-min))
          (while (search-forward "\n" nil t)
            (let* ((raw (buffer-substring-no-properties
                         (point-min) (1- (point))))
                   (line (decode-coding-string raw 'utf-8)))
              (delete-region (point-min) (point))
              (funcall on-line line)
              (goto-char (point-min))))))))))

;;; ---------------------------------------------------------------------------
;;; Major mode + buffer state

(defvar-local k8s-multilog--conn nil
  "Connection feeding the streams in this buffer.")
(defvar-local k8s-multilog--ns nil
  "Namespace this buffer is tailing in.")
(defvar-local k8s-multilog--kind nil
  "Workload kind (`deployment', `service', …) — used for the header.")
(defvar-local k8s-multilog--name nil
  "Workload name — used for the header.")
(defvar-local k8s-multilog--pods nil
  "List of pod alists currently tailed.  Used by `g' to restart.")
(defvar-local k8s-multilog--prefix-width 0
  "Padded width of the bracketed pod-name prefix column.")
(defvar-local k8s-multilog--processes nil
  "List of (PROC . SPLITTER) for every live stream; cleaned up on kill.")
(defvar-local k8s-multilog--pod-slots nil
  "Hash POD-NAME -> integer slot, picked in resolution order.")
(defvar-local k8s-multilog--paused nil
  "Non-nil while rendering is paused.")
(defvar-local k8s-multilog--paused-queue nil
  "Lines accumulated while paused; flushed in order on resume.")

(defvar-keymap k8s-multilog-mode-map
  :parent special-mode-map
  "g" #'k8s-multilog-restart
  "q" #'quit-window
  "p" #'k8s-multilog-pause-toggle
  "c" #'k8s-multilog-clear)

(define-derived-mode k8s-multilog-mode special-mode "K8s:Multilog"
  "Major mode for multi-pod log tailing.

\\{k8s-multilog-mode-map}"
  :group 'k8s-multilog
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook #'k8s-multilog--cleanup nil t))

;;; ---------------------------------------------------------------------------
;;; Stream lifecycle

(defun k8s-multilog--cleanup ()
  "Tear down every active stream in the current buffer."
  (dolist (entry k8s-multilog--processes)
    (let ((proc (car entry))
          (splitter (cdr entry)))
      (when (process-live-p proc)
        (ignore-errors (delete-process proc)))
      (when splitter
        (ignore-errors (funcall splitter 'cleanup))))))

(defun k8s-multilog--insert-line (prefix face line)
  "Insert one tail line at point-max, autoscrolling if at the tail.
PREFIX is the padded `[ns/pod]' tag; FACE colours it; LINE is the
log line body (already UTF-8 decoded).

Auto-follow checks both the buffer's point *and* the showing
windows' points — a user who hits `M->' in the window expects
the tail to keep following even if buffer-point hadn't been
moved yet."
  (let* ((inhibit-read-only t)
         (buf (current-buffer))
         (windows (get-buffer-window-list buf nil t))
         (was-at-end (or (= (point) (point-max))
                         (cl-some (lambda (w)
                                    (= (window-point w) (point-max)))
                                  windows))))
    (save-excursion
      (goto-char (point-max))
      (let ((body-beg (progn
                        (insert (propertize prefix 'font-lock-face face)
                                "  ")
                        (point))))
        (insert line "\n")
        (ansi-color-apply-on-region body-beg (1- (point)))))
    (when was-at-end
      (goto-char (point-max))
      (dolist (w windows) (set-window-point w (point-max))))))

(defun k8s-multilog--append-line (prefix face line)
  "Render or queue a line based on the pause state."
  (if k8s-multilog--paused
      (push (list prefix face line) k8s-multilog--paused-queue)
    (k8s-multilog--insert-line prefix face line)))

(defun k8s-multilog--padded-prefix (pod)
  "Return the column-aligned `[ns/pod]' prefix string for POD.
Reads the pod's own metadata.namespace so marked-pod sets can
span namespaces and still produce honest prefixes."
  (let* ((bare (format "[%s/%s]"
                       (k8s--resource-namespace pod)
                       (k8s--resource-name pod)))
         (pad (max 0 (- k8s-multilog--prefix-width (length bare)))))
    (concat bare (make-string pad ?\s))))

(defun k8s-multilog--start-pod-stream (pod slot)
  "Open the follow stream for POD, recording its (proc . splitter) pair."
  (let* ((conn k8s-multilog--conn)
         (cfg (k8s-connection-docker-cfg conn))
         (ns (k8s--resource-namespace pod))   ; per-pod, not buffer-wide
         (pod-name (k8s--resource-name pod))
         (container (k8s-multilog--first-container pod))
         (prefix (k8s-multilog--padded-prefix pod))
         (face (k8s-multilog--face-for-slot slot))
         (buf (current-buffer))
         (splitter
          (k8s-multilog--make-line-splitter
           (lambda (line)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (k8s-multilog--append-line prefix face line))))))
         (path (format "/api/v1/namespaces/%s/pods/%s/log" ns pod-name))
         (query `(("follow" . "true")
                  ("tailLines" . ,(number-to-string k8s-multilog-tail-lines))
                  ,@(when k8s-multilog-timestamps
                      '(("timestamps" . "true")))
                  ,@(when container
                      `(("container" . ,container)))))
         (proc (docker-http-stream
                cfg "GET" path
                :query query
                :on-chunk (lambda (bytes) (funcall splitter bytes))
                :on-close (lambda ()
                            (funcall splitter 'cleanup)
                            (when (buffer-live-p buf)
                              (with-current-buffer buf
                                (k8s-multilog--append-line
                                 prefix face "[stream closed]")))))))
    (puthash pod-name slot k8s-multilog--pod-slots)
    (push (cons proc splitter) k8s-multilog--processes)))

(defun k8s-multilog--start-all-streams ()
  "Open one stream per pod in `k8s-multilog--pods'.
Computes the shared prefix-width across all pods (so the column
stays aligned even when pods span multiple namespaces)."
  (setq k8s-multilog--pod-slots (make-hash-table :test 'equal))
  (setq k8s-multilog--processes nil)
  (let* ((bares (mapcar (lambda (p)
                          (format "[%s/%s]"
                                  (k8s--resource-namespace p)
                                  (k8s--resource-name p)))
                        k8s-multilog--pods))
         (width (apply #'max 0 (mapcar #'length bares))))
    (setq k8s-multilog--prefix-width width))
  (let ((slot 1))
    (dolist (pod k8s-multilog--pods)
      (k8s-multilog--start-pod-stream pod slot)
      (cl-incf slot))))

;;; ---------------------------------------------------------------------------
;;; Interactive controls

(defun k8s-multilog-restart ()
  "Restart every stream in this buffer (cleans up + re-opens)."
  (interactive)
  (k8s-multilog--cleanup)
  (let ((inhibit-read-only t)) (erase-buffer))
  (k8s-multilog--write-header)
  (k8s-multilog--start-all-streams)
  (k8s-multilog--goto-tail)
  (message "k8s multilog: restarted (%d pod%s)"
           (length k8s-multilog--pods)
           (if (= 1 (length k8s-multilog--pods)) "" "s")))

(defun k8s-multilog-clear ()
  "Clear the buffer without stopping the streams."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "[cleared — streams still running]\n"
                        'font-lock-face 'shadow)))
  (k8s-multilog--goto-tail))

(defun k8s-multilog--goto-tail ()
  "Position point + every showing window at the buffer's tail.
The per-line inserter only auto-scrolls when point is already at
point-max, so a fresh buffer would otherwise stay parked on the
header and the user would have to `M->' to see anything land."
  (let ((buf (current-buffer)))
    (goto-char (point-max))
    (dolist (win (get-buffer-window-list buf nil t))
      (set-window-point win (point-max)))))

(defun k8s-multilog-pause-toggle ()
  "Pause or resume rendering.  Output is queued while paused."
  (interactive)
  (setq k8s-multilog--paused (not k8s-multilog--paused))
  (unless k8s-multilog--paused
    (let ((queue (nreverse k8s-multilog--paused-queue)))
      (setq k8s-multilog--paused-queue nil)
      (dolist (entry queue) (apply #'k8s-multilog--insert-line entry))))
  (message "k8s multilog: %s"
           (if k8s-multilog--paused
               "paused (output queued; `p' to resume)"
             "resumed")))

;;; ---------------------------------------------------------------------------
;;; Header

(defun k8s-multilog--write-header ()
  "Insert the buffer-top header line."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (insert (propertize
               (format "Multi-pod log tail — %s %s/%s — %d pod%s\n"
                       (or k8s-multilog--kind "?")
                       (or k8s-multilog--ns "?")
                       (or k8s-multilog--name "?")
                       (length k8s-multilog--pods)
                       (if (= 1 (length k8s-multilog--pods)) "" "s"))
               'font-lock-face 'k8s-section-heading))
      (insert (propertize
               "    g=restart  p=pause  c=clear  q=quit\n\n"
               'font-lock-face 'k8s-dim)))))

;;; ---------------------------------------------------------------------------
;;; Public entry point

(defun k8s-multilog--cap-pods (pods kind name)
  "Cap PODS at `k8s-multilog-max-pods', prompting if exceeded.
Returns the (possibly truncated) pod list, or nil if the user cancels."
  (let ((n (length pods))
        (cap k8s-multilog-max-pods))
    (cond
     ((<= n cap) pods)
     (t
      (let ((choice (read-char-choice
                     (format "%s %s has %d pods (cap %d).  [y]es all / [f]irst %d / [n]o: "
                             kind name n cap cap)
                     '(?y ?f ?n))))
        (pcase choice
          (?y pods)
          (?f (seq-take pods cap))
          (?n nil)))))))

(defun k8s-multilog--open (conn ns kind name pods)
  "Internal entry point: open the multilog buffer for the given POD list.
Both `k8s-multilog-start' (selector-based) and
`k8s-multilog-start-with-pods' (explicit list) funnel through
here so behaviour stays in sync."
  (let ((pods (k8s-multilog--cap-pods pods kind name)))
    (when pods
      (let ((buf (get-buffer-create
                  (format "*k8s:multilog:%s/%s/%s*" kind ns name))))
        (with-current-buffer buf
          (k8s-multilog-mode)
          (setq k8s-multilog--conn conn
                k8s-multilog--ns ns
                k8s-multilog--kind kind
                k8s-multilog--name name
                k8s-multilog--pods pods
                k8s-multilog--paused nil
                k8s-multilog--paused-queue nil)
          (let ((inhibit-read-only t)) (erase-buffer))
          (k8s-multilog--write-header)
          (k8s-multilog--start-all-streams)
          (goto-char (point-max)))     ; park at tail so auto-scroll engages
        (pop-to-buffer buf)
        (with-current-buffer buf (k8s-multilog--goto-tail))
        (message "k8s multilog: tailing %d pod%s — g restart, p pause, c clear, q quit"
                 (length pods) (if (= 1 (length pods)) "" "s"))))))

;;;###autoload
(defun k8s-multilog-start (conn ns selector kind name)
  "Open a multi-pod log tail buffer.
CONN is the K8s connection; NS the namespace; SELECTOR an alist
of label-matchers (e.g. `((app . \"foo\"))'); KIND a symbol
\(deployment/statefulset/...) used for the buffer name and header;
NAME the workload's resource name."
  (let ((pods (k8s-list-pods-by-selector conn ns selector)))
    (unless (and pods (> (length pods) 0))
      (user-error "No pods match selector for %s %s/%s" kind ns name))
    (k8s-multilog--open conn ns kind name pods)))

;;;###autoload
(defun k8s-multilog-start-with-pods (conn pods kind name)
  "Open a multi-pod log tail buffer for an explicit POD list.
NS for the buffer name is derived from the pods themselves —
all-in-one-namespace uses that ns; mixed namespaces fall back to
the literal string \"mixed\".  Per-pod prefixes always carry each
pod's true namespace either way."
  (unless (and pods (> (length pods) 0))
    (user-error "No pods supplied to k8s-multilog-start-with-pods"))
  (let* ((namespaces (delete-dups
                      (mapcar #'k8s--resource-namespace pods)))
         (ns (if (= 1 (length namespaces)) (car namespaces) "mixed")))
    (k8s-multilog--open conn ns kind name pods)))

(provide 'k8s-multilog)
;;; k8s-multilog.el ends here
