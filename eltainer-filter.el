;;; eltainer-filter.el --- Resource-view filter (label + name)  -*- lexical-binding: t -*-
;;
;; A small per-buffer narrowing layer used by every magit-section view.
;; The user binds `F' (filter prefix) and picks a sub-action via the
;; transient:
;;
;;   F l SELECTOR    narrow to entries matching a labelSelector
;;   F n REGEX       narrow to entries whose name matches REGEX
;;   F c             clear every filter
;;   F F             echo the current filter (debug helper)
;;
;; The label half is server-side — we pass SELECTOR verbatim to the
;; K8s `?labelSelector=' query (or the docker engine's `?filters='
;; JSON).  The name half is client-side — applied during render,
;; since the API doesn't have a name-regex query.
;;
;; Filter state is **buffer-local**: each `*k8s:pods*' / `*docker:
;; containers*' window keeps its own narrowing.  `g' (refresh)
;; preserves the filter; `F c' clears it; `q' destroys the buffer.
;;
;; This module is backend-agnostic — it carries no K8s or Docker
;; knowledge.  The view-specific glue lives in `k8s/k8s-pods.el' and
;; friends, where the filter object is consulted during refresh.

(require 'cl-lib)
(require 'transient)

(defgroup eltainer-filter nil
  "Resource-view narrowing (label selectors + name regex)."
  :group 'eltainer
  :prefix "eltainer-filter-")

;;; ---------------------------------------------------------------------------
;;; Struct + state

(cl-defstruct (eltainer-filter
               (:constructor eltainer-filter--new)
               (:copier eltainer-filter-copy))
  "A view's active narrowing.  All fields nil ⇒ no filter applied.
LABEL-SELECTOR is a string in the canonical K8s `labelSelector'
mini-language (`a=b,c!=d,key,!key' — the API server parses it
server-side).  NAME-REGEX is a string, applied client-side."
  label-selector
  name-regex)

(defun eltainer-filter-make ()
  "Return a fresh empty filter."
  (eltainer-filter--new))

(defun eltainer-filter-empty-p (filter)
  "Non-nil iff FILTER has no constraints."
  (or (null filter)
      (and (let ((ls (eltainer-filter-label-selector filter)))
             (or (null ls) (string-empty-p ls)))
           (let ((nr (eltainer-filter-name-regex filter)))
             (or (null nr) (string-empty-p nr))))))

(defun eltainer-filter-format (filter)
  "Return a short human-readable summary of FILTER (empty -> \"\")."
  (if (eltainer-filter-empty-p filter) ""
    (let (parts)
      (let ((ls (eltainer-filter-label-selector filter)))
        (when (and ls (not (string-empty-p ls)))
          (push (format "label:%s" ls) parts)))
      (let ((nr (eltainer-filter-name-regex filter)))
        (when (and nr (not (string-empty-p nr)))
          (push (format "name:%s" nr) parts)))
      (mapconcat #'identity (nreverse parts) " "))))

(defun eltainer-filter-match-name-p (filter name)
  "Non-nil iff NAME passes FILTER's name-regex (or no name-regex set)."
  (or (null filter)
      (let ((nr (eltainer-filter-name-regex filter)))
        (or (null nr)
            (string-empty-p nr)
            (string-match-p nr (or name ""))))))

;;; ---------------------------------------------------------------------------
;;; Buffer-local storage
;;
;; Per CLAUDE.md: views set this slot in their mode body; the refresh
;; engine reads it.  No code in this module knows about specific view
;; modes — the slot is just a defvar-local both halves can use.

(defvar-local eltainer-filter--state nil
  "Active `eltainer-filter' for this buffer, or nil for no filter.
Touched by `eltainer-filter-set-label' / `eltainer-filter-clear';
read by the view's refresh function.")

(defun eltainer-filter-current ()
  "Return the buffer-local filter, creating one lazily on first read.
Returning a non-nil filter even when no constraints are set makes
the rest of the API simpler (mutators can assume a struct exists)."
  (or eltainer-filter--state
      (setq-local eltainer-filter--state (eltainer-filter-make))))

;;; ---------------------------------------------------------------------------
;;; Prompts (with per-session history)

(defvar eltainer-filter--label-history nil
  "History list for label-selector prompts.")

(defvar eltainer-filter--name-history nil
  "History list for name-regex prompts.")

(defun eltainer-filter-read-label-selector (&optional default)
  "Prompt for a label selector string in the K8s syntax."
  (read-string
   (format "Label selector%s: "
           (if default (format " (default %s)" default) ""))
   nil 'eltainer-filter--label-history default))

(defun eltainer-filter-read-name-regex (&optional default)
  "Prompt for a name regex."
  (read-string
   (format "Name regex%s: "
           (if default (format " (default %s)" default) ""))
   nil 'eltainer-filter--name-history default))

;;; ---------------------------------------------------------------------------
;;; User commands

(defvar eltainer-filter-change-hook nil
  "Hook run *before* the buffer is reverted after a filter change.
Backends use this to drop any cache that's now stale (e.g. the k8s
watch's `k8s--resource-table' which was populated under the old
filter).  Functions are called with no arguments, in the buffer
whose filter just changed.")

(defun eltainer-filter--after-change ()
  "Notify backends + re-render the current buffer.
Runs `eltainer-filter-change-hook' first so backends can drop
caches keyed off the old filter, then drives a refresh via
`revert-buffer-function'."
  (run-hooks 'eltainer-filter-change-hook)
  (when (and (derived-mode-p 'magit-section-mode)
             revert-buffer-function)
    (revert-buffer nil t)))

(defun eltainer-filter-set-label (selector)
  "Set the buffer-local filter's label-selector to SELECTOR.
Empty string clears it.  Re-renders the buffer."
  (interactive
   (list (eltainer-filter-read-label-selector
          (and eltainer-filter--state
               (eltainer-filter-label-selector eltainer-filter--state)))))
  (let ((f (eltainer-filter-current)))
    (setf (eltainer-filter-label-selector f)
          (and (not (string-empty-p selector)) selector))
    (eltainer-filter--after-change)
    (message "filter: %s"
             (if (eltainer-filter-empty-p f) "(none)"
               (eltainer-filter-format f)))))

(defun eltainer-filter-set-name (regex)
  "Set the buffer-local filter's name-regex to REGEX.
Empty string clears it.  Re-renders the buffer."
  (interactive
   (list (eltainer-filter-read-name-regex
          (and eltainer-filter--state
               (eltainer-filter-name-regex eltainer-filter--state)))))
  (let ((f (eltainer-filter-current)))
    (setf (eltainer-filter-name-regex f)
          (and (not (string-empty-p regex)) regex))
    (eltainer-filter--after-change)
    (message "filter: %s"
             (if (eltainer-filter-empty-p f) "(none)"
               (eltainer-filter-format f)))))

(defun eltainer-filter-clear ()
  "Drop every constraint in the buffer-local filter.  Re-renders."
  (interactive)
  (setq-local eltainer-filter--state nil)
  (eltainer-filter--after-change)
  (message "filter cleared"))

(defun eltainer-filter-show ()
  "Echo the current filter (debug helper)."
  (interactive)
  (message "filter: %s"
           (or (and eltainer-filter--state
                    (let ((s (eltainer-filter-format eltainer-filter--state)))
                      (and (not (string-empty-p s)) s)))
               "(none)")))

;;; ---------------------------------------------------------------------------
;;; Transient

;;;###autoload (autoload 'eltainer-filter-dispatch "eltainer-filter" nil t)
(transient-define-prefix eltainer-filter-dispatch ()
  "Narrow this view by label / name."
  ["Filter"
   ("l" "Label selector" eltainer-filter-set-label)
   ("n" "Name regex"     eltainer-filter-set-name)
   ("c" "Clear"          eltainer-filter-clear)
   ("F" "Show current"   eltainer-filter-show)])

(provide 'eltainer-filter)
;;; eltainer-filter.el ends here
