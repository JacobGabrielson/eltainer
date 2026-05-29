;;; key-hints.el --- Always-visible contextual key-hint strip -*- lexical-binding: t -*-

;; Author: Jacob Gabrielson <jacobg23@pobox.com>
;; Maintainer: Jacob Gabrielson <jacobg23@pobox.com>
;; URL: https://github.com/JacobGabrielson/eltainer
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, help

;;; Commentary:

;; `key-hints-mode' is a global minor mode that shows a compact
;; "what can I do here" strip in a 1-line side window pinned to
;; the bottom of the frame — like having `?' permanently pressed.
;; The window auto-hides in buffers with nothing to render, so it
;; only takes a line where it's useful.
;;
;; Source of truth, in priority order:
;;
;; 1. A buffer-local `key-hints-context-function' (returns items list).
;;    Lets section-aware UIs (eltainer's pods view, magit) pick the
;;    right cheat for the section under point.
;; 2. A per-major-mode registry populated via `key-hints-register'.
;;    For curated hints.
;; 3. Auto-extraction from the major-mode keymap as an opt-in
;;    fallback (`key-hints-restrict-to-registered' = nil).  Walks
;;    single-key bindings, annotates with the docstring's first line.
;;
;; Items are `(KEY LABEL [PRIORITY])'; priority 5 is the default,
;; higher floats to the left.  When the strip would overflow
;; `key-hints-max-items', the rightmost items drop first and a `+N'
;; indicator shows how many were hidden.

;;; Code:

(require 'cl-lib)

(defgroup key-hints nil
  "Always-visible contextual key-hint strip."
  :group 'help
  :prefix "key-hints-")

;;; ---------------------------------------------------------------------------
;;; Customize surface

(defcustom key-hints-max-items 8
  "Maximum number of items rendered before showing `+N'."
  :type 'integer
  :group 'key-hints)

(defcustom key-hints-truncate-label-width 10
  "Per-label maximum character width.  Labels longer than this are
truncated."
  :type 'integer
  :group 'key-hints)

(defcustom key-hints-separator "  "
  "String between items in the strip."
  :type 'string
  :group 'key-hints)

(defcustom key-hints-side-window-height 1
  "Height of the side window (lines)."
  :type 'integer
  :group 'key-hints)

(defcustom key-hints-hide-modes
  '(minibuffer-mode
    minibuffer-inactive-mode
    completion-list-mode
    Buffer-menu-mode
    image-mode
    fundamental-mode)
  "Major modes in which the strip is suppressed."
  :type '(repeat symbol)
  :group 'key-hints)

(defcustom key-hints-show-modes nil
  "If non-nil, restrict the strip to only these major modes.
Empty list (default) means \"all modes except `key-hints-hide-modes'\"."
  :type '(repeat symbol)
  :group 'key-hints)

(defcustom key-hints-default-priority 5
  "Priority assigned to items that don't specify one."
  :type 'integer
  :group 'key-hints)

(defcustom key-hints-restrict-to-registered t
  "If non-nil, only render hints in modes that explicitly registered.
That's the default: with eltainer loaded, the strip only shows in
the dashboard / pods / containers / etc.  Buffers in modes with no
`key-hints-register' entry stay quiet (and the side window
auto-hides).

Set to nil to fall back to auto-extracted hints — single-key
bindings from the major-mode keymap with docstring-derived
labels — in modes that didn't register.  Universal but noisier."
  :type 'boolean
  :group 'key-hints)

;;; ---------------------------------------------------------------------------
;;; Registry + per-buffer override

(defvar key-hints--registry (make-hash-table :test 'eq)
  "Hash MAJOR-MODE -> list of (KEY LABEL [PRIORITY]) tuples.")

(defvar-local key-hints-context-function nil
  "Buffer-local function returning a hint-item list for the current
section / cursor position.  Takes precedence over the registry +
auto-extracted fallback when set.")

(defvar key-hints--registry-generation 0
  "Bumped whenever the registry changes — invalidates cached strings.")

(defvar key-hints--cache (make-hash-table :test 'equal)
  "Cache key -> rendered string.")

;;;###autoload
(defun key-hints-register (mode items)
  "Register ITEMS as the curated hint set for MODE.
ITEMS is a list of `(KEY LABEL [PRIORITY])'.  KEY is a key-description
string (`l', `C-c C-c', etc.); LABEL is the short verb; PRIORITY is
an integer where higher floats left (default
`key-hints-default-priority')."
  (puthash mode items key-hints--registry)
  (cl-incf key-hints--registry-generation)
  (clrhash key-hints--cache))

;;;###autoload
(defun key-hints-unregister (mode)
  "Drop MODE's curated hint entry."
  (remhash mode key-hints--registry)
  (cl-incf key-hints--registry-generation)
  (clrhash key-hints--cache))

;;; ---------------------------------------------------------------------------
;;; Auto-extracted fallback

(defconst key-hints--boring-commands
  '(self-insert-command
    digit-argument negative-argument
    next-line previous-line forward-char backward-char
    beginning-of-line end-of-line
    beginning-of-buffer end-of-buffer
    scroll-up-command scroll-down-command
    keyboard-quit ignore undefined
    mwheel-scroll mouse-drag-region
    universal-argument)
  "Commands too generic to show as hints.")

(defun key-hints--cmd-label (cmd)
  "Short label for CMD: first words of docstring, fallback to the symbol name."
  (let* ((doc (and (symbolp cmd) (ignore-errors (documentation cmd)))))
    (cond
     ((and doc (string-match "\\`\\([^.\n]+\\)" doc))
      (downcase (match-string 1 doc)))
     ((symbolp cmd)
      (replace-regexp-in-string
       "-" " "
       (replace-regexp-in-string "\\`docker-\\|\\`k8s-\\|\\`eltainer-" ""
                                 (symbol-name cmd))))
     (t ""))))

(defconst key-hints--auto-extract-boring-keys
  '(?? ?/)
  "Keys filtered from auto-extract: by convention always
\"show me help\" — that IS the strip; including them is
both noisy and circular.")

(defun key-hints--auto-extract (mode)
  "Walk MODE's `*-map' for single-key bindings and synthesise hints."
  (let* ((map-sym (intern-soft (format "%s-map" mode)))
         (km (and map-sym (boundp map-sym)
                  (keymapp (symbol-value map-sym))
                  (symbol-value map-sym)))
         items)
    (when km
      (map-keymap
       (lambda (event def)
         (when (and (characterp event)
                    (or (and (>= event ?a) (<= event ?z))
                        (and (>= event ?A) (<= event ?Z))
                        (memq event '(?+ ?- ?!)))
                    (not (memq event key-hints--auto-extract-boring-keys))
                    (symbolp def)
                    (not (memq def key-hints--boring-commands))
                    (not (memq def '(describe-mode
                                     docker-dispatch
                                     k8s-dispatch
                                     eltainer-filter-dispatch)))
                    (not (eq def 'undefined)))
           (push (list (key-description (vector event))
                       (key-hints--cmd-label def)
                       key-hints-default-priority)
                 items)))
       km))
    (sort items (lambda (a b) (string< (car a) (car b))))))

;;; ---------------------------------------------------------------------------
;;; String compute

(defun key-hints--applicable-p ()
  "Non-nil if the strip should render in the current buffer."
  (and (not (window-minibuffer-p))
       (not (memq major-mode key-hints-hide-modes))
       (or (null key-hints-show-modes)
           (memq major-mode key-hints-show-modes))))

(defun key-hints--truncate (s)
  (let ((w key-hints-truncate-label-width))
    (if (<= (length s) w) s (substring s 0 w))))

(defun key-hints--items ()
  "Resolve the item list for the current buffer.
Returns nil (= suppress strip) when nothing applies."
  (or (and key-hints-context-function
           (ignore-errors (funcall key-hints-context-function)))
      (let ((registered (gethash major-mode key-hints--registry)))
        (and registered
             (sort (copy-sequence registered)
                   (lambda (a b)
                     (> (or (nth 2 a) key-hints-default-priority)
                        (or (nth 2 b) key-hints-default-priority))))))
      ;; Auto-extract only when the user opted in.
      (and (not key-hints-restrict-to-registered)
           (key-hints--auto-extract major-mode))))

(defun key-hints--render (items)
  "Render ITEMS to a propertised string with the `+N' overflow marker."
  (let* ((n (length items))
         (max key-hints-max-items)
         (shown (cl-subseq items 0 (min n max)))
         (extra (max 0 (- n max))))
    (concat
     (mapconcat
      (lambda (it)
        (concat (propertize (nth 0 it) 'face 'help-key-binding)
                " "
                (key-hints--truncate (nth 1 it))))
      shown
      key-hints-separator)
     (when (> extra 0)
       (propertize (format " +%d" extra) 'face 'shadow)))))

(defun key-hints--current-string ()
  "Build (or fetch from cache) the hint string for the current buffer.
Returns nil when there's nothing to render — caller treats that
as \"hide the side window\"."
  (when (key-hints--applicable-p)
    (let ((cache-key (list major-mode
                           key-hints--registry-generation
                           key-hints-restrict-to-registered
                           key-hints-max-items
                           key-hints-truncate-label-width
                           key-hints-context-function)))
      (or (gethash cache-key key-hints--cache)
          (let* ((items (key-hints--items))
                 (rendered (and items (key-hints--render items))))
            (unless key-hints-context-function
              (puthash cache-key rendered key-hints--cache))
            rendered)))))

;;; ---------------------------------------------------------------------------
;;; Side-window backend

(defconst key-hints--buffer-name " *key-hints*"
  "Side-window buffer name.  Leading space hides it from `M-x list-buffers'.")

(defvar key-hints--last-string nil
  "Last rendered string — skip repaint when unchanged.")

(defvar key-hints--last-window-buffer nil
  "Buffer the strip was last rendered for — re-render on focus change.")

(defun key-hints--side-window-buffer ()
  (or (get-buffer key-hints--buffer-name)
      (with-current-buffer (get-buffer-create key-hints--buffer-name)
        (setq-local mode-line-format nil
                    header-line-format nil
                    cursor-type nil
                    truncate-lines t
                    show-trailing-whitespace nil)
        (current-buffer))))

(defun key-hints--display-side-window (buf)
  (display-buffer
   buf
   `((display-buffer-in-side-window)
     (side . bottom)
     (slot . 0)
     (window-height . ,key-hints-side-window-height)
     (preserve-size . (nil . t))
     (window-parameters
      . ((no-other-window . t)
         (no-delete-other-windows . t)
         (mode-line-format . none))))))

(defun key-hints--hide-side-window ()
  (let ((buf (get-buffer key-hints--buffer-name)))
    (when buf
      (dolist (win (get-buffer-window-list buf nil t))
        (delete-window win)))))

(defun key-hints--refresh ()
  "Render the current buffer's hints into the side window — or hide it."
  (when (bound-and-true-p key-hints-mode)
    ;; Don't react inside the strip's own buffer or the minibuffer.
    (unless (or (eq (current-buffer) (get-buffer key-hints--buffer-name))
                (window-minibuffer-p))
      (let ((str (key-hints--current-string))
            (cur (current-buffer)))
        (cond
         ((or (null str) (string-empty-p str))
          (when (or (not (eq cur key-hints--last-window-buffer))
                    key-hints--last-string)
            (setq key-hints--last-string nil
                  key-hints--last-window-buffer cur)
            (key-hints--hide-side-window)))
         (t
          (let ((buf (key-hints--side-window-buffer)))
            (unless (and (string= str key-hints--last-string)
                         (eq cur key-hints--last-window-buffer))
              (setq key-hints--last-string str
                    key-hints--last-window-buffer cur)
              (with-current-buffer buf
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (insert str))))
            (unless (get-buffer-window buf t)
              (key-hints--display-side-window buf)))))))))

(defun key-hints--remove-side-window ()
  "Tear down the strip completely (hide window + kill buffer)."
  (key-hints--hide-side-window)
  (when-let ((buf (get-buffer key-hints--buffer-name)))
    (kill-buffer buf))
  (setq key-hints--last-string nil
        key-hints--last-window-buffer nil))

;;; ---------------------------------------------------------------------------
;;; Global minor mode

(defun key-hints--clean-legacy ()
  "Remove any stale entries from a previous (mode-line backend)
version of this file from `mode-line-misc-info'.  Idempotent and
cheap; safe to call on every mode toggle."
  (setq mode-line-misc-info
        (cl-remove-if
         (lambda (item)
           (and (consp item)
                (eq (car-safe item) :eval)
                (string-match-p "key-hints--current-string"
                                (format "%S" item))))
         mode-line-misc-info))
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode key-hints-mode
  "Show a compact contextual key-hint strip in a 1-line side
window at the bottom of the frame.  The window auto-hides in
buffers with nothing to render.

Items come from (in order): a buffer-local
`key-hints-context-function', a per-major-mode registry populated
via `key-hints-register', and — when
`key-hints-restrict-to-registered' is nil — an auto-extracted
fallback walking the major-mode keymap."
  :global t
  :init-value nil
  :group 'key-hints
  (key-hints--clean-legacy)
  (cond
   (key-hints-mode
    (add-hook 'post-command-hook #'key-hints--refresh)
    (add-hook 'window-buffer-change-functions #'key-hints--on-buffer-change)
    (key-hints--refresh))
   (t
    (remove-hook 'post-command-hook #'key-hints--refresh)
    (remove-hook 'window-buffer-change-functions #'key-hints--on-buffer-change)
    (key-hints--remove-side-window))))

(defun key-hints--on-buffer-change (_frame)
  (key-hints--refresh))

(provide 'key-hints)
;;; key-hints.el ends here
