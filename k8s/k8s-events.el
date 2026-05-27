;;; k8s-events.el --- Live cluster events stream -*- lexical-binding: t -*-
;;
;; `E' from the dashboard (or `?' → Events) opens `*k8s:events*' —
;; a chronological live view of `/api/v1/events`, newest first.
;; Watches the stream and folds events in incrementally; auto-renders
;; in place on each tick via the existing watch machinery.
;;
;; Columns: AGE / TYPE / REASON / OBJECT / MESSAGE.  Warning events
;; render in the error face; Normal in dim.  `F' filters as usual
;; (label / name regex apply to the involvedObject's name);
;; `t' jumps the cursor to the row whose object's namespace matches
;; the active namespace filter.

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'eltainer-filter)
(require 'k8s-api)
(require 'k8s-marks)
(require 'k8s)

(defgroup k8s-events nil
  "Cluster-events stream view."
  :group 'k8s
  :prefix "k8s-events-")

(defcustom k8s-events-window-minutes 60
  "Only show events from the last N minutes (matches kubelet's TTL
and keeps the view scannable).  `g` re-fetches; set to 0 for
no time cutoff."
  :type 'integer
  :group 'k8s-events)

;;; ---------------------------------------------------------------------------
;;; Helpers

(defun k8s-events--iso (ev)
  "Return EV's most useful timestamp."
  (or (cdr (assq 'lastTimestamp ev))
      (cdr (assq 'eventTime ev))
      (cdr (assq 'creationTimestamp (cdr (assq 'metadata ev))))))

(defun k8s-events--cutoff ()
  "Return the float-time cutoff, or nil to keep everything."
  (and (numberp k8s-events-window-minutes)
       (> k8s-events-window-minutes 0)
       (- (float-time) (* 60 k8s-events-window-minutes))))

(defun k8s-events--sort-key (ev)
  "Return EV's timestamp as float-time, or 0 if unparseable."
  (let ((iso (k8s-events--iso ev)))
    (or (and iso (ignore-errors (float-time (date-to-time iso)))) 0)))

(defun k8s-events--type-face (type)
  (pcase type
    ("Warning" 'eltainer-status-error)
    ("Normal"  'eltainer-status-running)
    (_          'k8s-dim)))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun k8s-events--insert-event (ev)
  "Insert one EV row.  Wraps the message line in a sub-section
that TAB hides — keeps the buffer scannable but lets users dig in."
  (let* ((type (or (cdr (assq 'type ev)) "?"))
         (reason (or (cdr (assq 'reason ev)) "?"))
         (msg (or (cdr (assq 'message ev)) ""))
         (count (or (cdr (assq 'count ev)) 1))
         (obj (cdr (assq 'involvedObject ev)))
         (kind (cdr (assq 'kind obj)))
         (name (cdr (assq 'name obj)))
         (ns (cdr (assq 'namespace obj)))
         (iso (k8s-events--iso ev))
         (age (and iso (k8s--age-string iso))))
    (magit-insert-section (event ev t)
      (magit-insert-heading
        (format "  %-6s %-7s %-22s %4dx  %s%s%s\n"
                age
                (propertize type 'font-lock-face
                            (k8s-events--type-face type))
                (propertize reason
                            'font-lock-face
                            (if (equal type "Warning")
                                'eltainer-status-error
                              'k8s-resource-name))
                count
                (propertize (or kind "") 'font-lock-face 'k8s-dim)
                (if (and kind name) "/" "")
                (propertize (or (and ns (format "%s/%s" ns name))
                                name "")
                            'font-lock-face 'eltainer-resource-name)))
      (when (and msg (not (string-empty-p msg)))
        (insert (propertize (format "      %s\n"
                                    (truncate-string-to-width
                                     msg 120 nil nil "…"))
                            'font-lock-face 'k8s-dim))))))

(defun k8s--events-refresh ()
  "Refresh the events buffer from /api/v1/events.
Honours the active `eltainer-filter''s name-regex (applied against
the involvedObject's name) and the buffer-local `k8s--namespace'
filter (cluster-wide when `all')."
  (let* ((inhibit-read-only t)
         (conn (k8s--ensure-connection))
         (events
          (condition-case err
              (k8s-list-events-all conn nil)
            (error
             (message "k8s-events: fetch failed: %s"
                      (error-message-string err))
             nil)))
         (cutoff (k8s-events--cutoff))
         (events
          (seq-filter
           (lambda (ev)
             (and
              ;; Time window
              (or (null cutoff)
                  (let ((ts (k8s-events--sort-key ev)))
                    (and ts (> ts cutoff))))
              ;; Namespace filter (when not `all')
              (or (null k8s--namespace)
                  (equal k8s--namespace
                         (cdr (assq 'namespace
                                    (cdr (assq 'involvedObject ev))))))))
           (append events nil)))
         ;; Name-regex (eltainer-filter)
         (filter eltainer-filter--state)
         (events
          (if (and filter
                   (let ((nr (eltainer-filter-name-regex filter)))
                     (and nr (not (string-empty-p nr)))))
              (seq-filter
               (lambda (ev)
                 (eltainer-filter-match-name-p
                  filter
                  (cdr (assq 'name (cdr (assq 'involvedObject ev))))))
               events)
            events))
         (sorted
          (sort events
                (lambda (a b)
                  (> (k8s-events--sort-key a) (k8s-events--sort-key b))))))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-root)
      (k8s--insert-header "Events")
      (insert (propertize
               (format "  %-6s %-7s %-22s %5s  %s\n"
                       "AGE" "TYPE" "REASON" "COUNT" "OBJECT")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (if (null sorted)
          (insert (propertize "  (no events in window)\n"
                              'font-lock-face 'k8s-dim))
        (dolist (ev sorted)
          (k8s-events--insert-event ev))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar k8s-events-mode-map (make-sparse-keymap))
(set-keymap-parent k8s-events-mode-map k8s-common-map)

(define-derived-mode k8s-events-mode magit-section-mode "K8s:Events"
  "Live cluster events view.

\\{k8s-events-mode-map}"
  :interactive nil
  :group 'k8s-events
  (setq-local revert-buffer-function (lambda (_a _b) (k8s--events-refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              '(:eval (k8s--filter-mode-line)) "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces)))

;;;###autoload
(defun k8s-events ()
  "Open the cluster-events view."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:events*")))
    (with-current-buffer buf
      (k8s-events-mode)
      (k8s--ensure-connection)
      (k8s--events-refresh))
    (pop-to-buffer buf)))

(provide 'k8s-events)
;;; k8s-events.el ends here
