;;; key-hints.el --- Always-visible contextual key-hint strip -*- lexical-binding: t -*-

;; Author: Jacob Gabrielson <jacobg23@pobox.com>
;; Maintainer: Jacob Gabrielson <jacobg23@pobox.com>
;; URL: https://github.com/JacobGabrielson/eltainer
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, help

;;; Commentary:

;; `key-hints-mode' is a global minor mode that always shows a
;; compact "what can I do here" strip — like having `?'
;; permanently pressed.  Two backends:
;;
;; - `mode-line' (default): inline `:eval' segment in the mode-line.
;;   Zero new pixels.
;; - `side-window': a 1-line side window pinned to the bottom of the
;;   frame.  Roomier, but eats a line.
;;
;; Source of truth, in priority order:
;;
;; 1. A buffer-local `key-hints-context-function' (returns items list).
;;    Lets section-aware UIs (eltainer's pods view, magit) pick the
;;    right cheat for the section under point.
;; 2. A per-major-mode registry populated via `key-hints-register'.
;;    For richer / curated hints.
;; 3. Auto-extraction from the major-mode keymap as a fallback.  Walks
;;    single-key bindings, annotates with the docstring's first line.
;;
;; Items are `(KEY LABEL [PRIORITY])'; priority 5 is the default, higher
;; floats to the left.  When the strip would overflow
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

(defcustom key-hints-position 'mode-line
  "Where to render the key-hints strip.
- `mode-line' (default): inline as an `:eval' segment.
- `side-window': a 1-line side window at the bottom of the frame."
  :type '(choice (const :tag "Mode-line :eval segment" mode-line)
                 (const :tag "1-line side window" side-window))
  :group 'key-hints
  :set (lambda (sym val)
         (set-default sym val)
         (when (bound-and-true-p key-hints-mode)
           (key-hints--reinstall))))

(defcustom key-hints-max-items 6
  "Maximum number of items rendered before showing `+N'."
  :type 'integer
  :group 'key-hints)

(defcustom key-hints-truncate-label-width 8
  "Per-label maximum character width.  Labels longer than this are
truncated."
  :type 'integer
  :group 'key-hints)

(defcustom key-hints-separator "  "
  "String between items in the strip."
  :type 'string
  :group 'key-hints)

(defcustom key-hints-side-window-height 1
  "Height of the side window (lines) when `key-hints-position' is
`side-window'."
  :type 'integer
  :group 'key-hints)

(defcustom key-hints-hide-modes
  '(minibuffer-mode
    minibuffer-inactive-mode
    completion-list-mode
    Buffer-menu-mode
    image-mode
    fundamental-mode)
  "Major modes in which the strip is suppressed.
Either no useful keys (`fundamental-mode'), or the mode-line /
buffer is already special-cased and shouldn't carry extras."
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
                        (memq event '(?+ ?- ?? ?! ?/)))
                    (symbolp def)
                    (not (memq def key-hints--boring-commands))
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
  "Resolve the item list for the current buffer."
  (or (and key-hints-context-function
           (ignore-errors (funcall key-hints-context-function)))
      (let ((registered (gethash major-mode key-hints--registry)))
        (and registered
             (sort (copy-sequence registered)
                   (lambda (a b)
                     (> (or (nth 2 a) key-hints-default-priority)
                        (or (nth 2 b) key-hints-default-priority))))))
      (key-hints--auto-extract major-mode)))

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
  "Build (or fetch from cache) the hint string for the current buffer."
  (when (key-hints--applicable-p)
    (let ((cache-key (list major-mode
                           key-hints--registry-generation
                           key-hints-max-items
                           key-hints-truncate-label-width
                           key-hints-context-function)))
      (or (gethash cache-key key-hints--cache)
          (let ((rendered (key-hints--render (key-hints--items))))
            ;; Only cache when there's no context-function — otherwise
            ;; different sections in the same mode would all share one
            ;; cached string.
            (unless key-hints-context-function
              (puthash cache-key rendered key-hints--cache))
            rendered)))))

;;; ---------------------------------------------------------------------------
;;; Mode-line backend

(defvar key-hints--mode-line-segment
  '(:eval (or (key-hints--current-string) ""))
  "The `:eval' element added to `mode-line-misc-info'.")

(defun key-hints--install-mode-line ()
  (add-to-list 'mode-line-misc-info key-hints--mode-line-segment t))

(defun key-hints--uninstall-mode-line ()
  (setq mode-line-misc-info
        (delete key-hints--mode-line-segment mode-line-misc-info)))

;;; ---------------------------------------------------------------------------
;;; Side-window backend

(defconst key-hints--buffer-name " *key-hints*"
  "Side-window buffer name.  Leading space hides it from `M-x list-buffers'.")

(defvar key-hints--last-side-window-string nil
  "Last rendered string — skip repaint when unchanged.")

(defun key-hints--side-window-buffer ()
  (or (get-buffer key-hints--buffer-name)
      (with-current-buffer (get-buffer-create key-hints--buffer-name)
        (setq mode-line-format nil
              header-line-format nil
              cursor-type nil
              truncate-lines t)
        (setq-local mode-line-format nil)
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

(defun key-hints--update-side-window ()
  (when (and (bound-and-true-p key-hints-mode)
             (eq key-hints-position 'side-window))
    (let* ((str (or (key-hints--current-string) ""))
           (buf (key-hints--side-window-buffer)))
      (unless (string= str key-hints--last-side-window-string)
        (setq key-hints--last-side-window-string str)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert str))))
      (unless (get-buffer-window buf t)
        (key-hints--display-side-window buf)))))

(defun key-hints--remove-side-window ()
  (let ((buf (get-buffer key-hints--buffer-name)))
    (when buf
      (dolist (win (get-buffer-window-list buf nil t))
        (delete-window win))
      (kill-buffer buf))
    (setq key-hints--last-side-window-string nil)))

(defun key-hints--post-command ()
  (when (eq key-hints-position 'side-window)
    (key-hints--update-side-window)))

;;; ---------------------------------------------------------------------------
;;; Global minor mode

(defun key-hints--reinstall ()
  "Install / re-install the active backend (called on enable + on position toggle)."
  (key-hints--uninstall-mode-line)
  (key-hints--remove-side-window)
  (remove-hook 'post-command-hook #'key-hints--post-command)
  (when (bound-and-true-p key-hints-mode)
    (pcase key-hints-position
      ('mode-line   (key-hints--install-mode-line))
      ('side-window
       (add-hook 'post-command-hook #'key-hints--post-command)
       (key-hints--update-side-window))))
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode key-hints-mode
  "Show a compact, contextual key-hint strip.
Renders into the mode-line by default; flip `key-hints-position'
to `side-window' for a roomier 1-line strip at the bottom of the
frame.

Items come from (in order): a buffer-local
`key-hints-context-function', a per-major-mode registry populated
via `key-hints-register', and an auto-extracted fallback that
walks the major-mode keymap."
  :global t
  :init-value nil
  :group 'key-hints
  (key-hints--reinstall))

(provide 'key-hints)
;;; key-hints.el ends here
