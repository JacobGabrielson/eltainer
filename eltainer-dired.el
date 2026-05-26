;;; eltainer-dired.el --- Shared dired-derived container browser -*- lexical-binding: t -*-
;;
;; The parent mode for browsing a container's filesystem with all of
;; emacs's built-in dired-mode keys.  Child modes — `docker-dired-mode'
;; and (later) `k8s-dired-mode' — plug in their backend `list' and
;; `cat' functions via buffer-local slots; everything else
;; (navigation, marking, sort, revert, the v1 read-only guards on
;; rename / delete / copy) is shared here.
;;
;; Design + scope: docs/container-dired-plan.md.

(require 'cl-lib)
(require 'dired)
(require 'eltainer-fs)

(defgroup eltainer-dired nil
  "Dired-style container filesystem browser."
  :group 'eltainer
  :prefix "eltainer-dired-")

;;; ---------------------------------------------------------------------------
;;; Sentinel paths
;;
;; We don't register a TRAMP method (no-CLI thesis).  Sentinels are
;; recognised here and routed through our own backends.

(defconst eltainer-dired--docker-rx
  "\\`/docker:\\([^/:]+\\):\\(/.*\\)\\'"
  "Matches /docker:CONTAINER:/PATH .  Groups: 1=container, 2=remote.")

(defconst eltainer-dired--k8s-rx
  "\\`/k8s:\\([^/:]+\\)/\\([^/:[]+\\)\\(?:\\[\\([^]]+\\)\\]\\)?:\\(/.*\\)\\'"
  "Matches /k8s:NS/POD[CONTAINER]:/PATH .
Groups: 1=ns, 2=pod, 3=container (or nil), 4=remote.")

(defun eltainer-dired-parse-path (path)
  "Parse PATH; return a plist or nil.
Plist keys: :backend (`docker' / `k8s') :container :ns :pod
:pod-container :remote."
  (when (stringp path)
    (cond
     ((string-match eltainer-dired--docker-rx path)
      (list :backend 'docker
            :container (match-string 1 path)
            :remote    (match-string 2 path)))
     ((string-match eltainer-dired--k8s-rx path)
      (list :backend 'k8s
            :ns            (match-string 1 path)
            :pod           (match-string 2 path)
            :pod-container (match-string 3 path)
            :remote        (match-string 4 path))))))

(defun eltainer-dired-sentinel-p (path)
  "Return non-nil iff PATH looks like one of our sentinel paths."
  (and (stringp path)
       (or (string-match-p eltainer-dired--docker-rx path)
           (string-match-p eltainer-dired--k8s-rx path))))

(defun eltainer-dired-make-docker-path (container remote)
  "Build `/docker:CONTAINER:REMOTE'."
  (format "/docker:%s:%s" container remote))

(defun eltainer-dired-make-k8s-path (ns pod container remote)
  "Build `/k8s:NS/POD[CONTAINER]:REMOTE'.  CONTAINER may be nil."
  (if (and container (> (length container) 0))
      (format "/k8s:%s/%s[%s]:%s" ns pod container remote)
    (format "/k8s:%s/%s:%s" ns pod remote)))

;;; ---------------------------------------------------------------------------
;;; Buffer-local backend function slots
;;
;; Child modes set these in their entry-point function and the parent
;; never knows whether it's talking to docker or k8s.

(defvar-local eltainer-dired--list-fn nil
  "Closure (lambda (REMOTE-PATH)) -> list of `eltainer-fs-entry'.
Set by the child mode's open command; called by the renderer.")

(defvar-local eltainer-dired--cat-fn nil
  "Closure (lambda (REMOTE-PATH)) -> file's raw bytes (unibyte string).
Set by the child mode; called when the user RETurns on a file.")

(defvar-local eltainer-dired--sentinel-prefix nil
  "Sentinel prefix for the current buffer, e.g. `/docker:NAME:'.
Builders cons the remote path on the end to form a full sentinel.")

(defvar-local eltainer-dired--remote-dir nil
  "Current remote directory path inside the container, e.g. `/etc'.")

(defvar-local eltainer-dired--label nil
  "Short identity used in the mode-line and buffer name, e.g.
`docker:eltainer-ticker'.")

;;; ---------------------------------------------------------------------------
;;; ls -al text synthesis

(defconst eltainer-dired--type-char
  '((file       . ?-)
    (directory  . ?d)
    (symlink    . ?l)
    (fifo       . ?p)
    (socket     . ?s)
    (block      . ?b)
    (char       . ?c)
    (unknown    . ??))
  "Map an `eltainer-fs-entry-type' symbol to the leading char `ls -l' uses.")

(defun eltainer-dired--format-mtime (mtime)
  "Format unix-epoch MTIME the way `ls -l' does."
  (let* ((age (- (float-time) (or mtime 0)))
         (fmt (if (> age (* 180 24 3600))
                  "%b %e  %Y"
                "%b %e %H:%M")))
    (format-time-string fmt (or mtime 0))))

(defun eltainer-dired--emit-line (entry)
  "Return one dired-readable line for ENTRY (`eltainer-fs-entry')."
  (let* ((type (eltainer-fs-entry-type entry))
         (tc (or (alist-get type eltainer-dired--type-char) ??))
         (perms (or (eltainer-fs-entry-mode-string entry) "---------"))
         (nlink (or (eltainer-fs-entry-nlink entry) 1))
         (owner (or (eltainer-fs-entry-owner entry) "?"))
         (group (or (eltainer-fs-entry-group entry) "?"))
         (size (or (eltainer-fs-entry-size entry) 0))
         (mtime (or (eltainer-fs-entry-mtime entry) 0))
         (name (or (eltainer-fs-entry-name entry) "?"))
         (link (eltainer-fs-entry-link-target entry)))
    (format "  %c%s %3d %-8s %-8s %10d %s %s%s\n"
            tc perms nlink owner group size
            (eltainer-dired--format-mtime mtime)
            name
            (if link (format " -> %s" link) ""))))

(defun eltainer-dired--render (entries)
  "Erase buffer and emit ENTRIES in the dired-readable shape.
Header is the current `default-directory' followed by a `total 0' line
\(we don't track block count); both shapes dired's parser expects."
  (let ((inhibit-read-only t)
        (sorted (sort (copy-sequence entries)
                      (lambda (a b)
                        (let ((da (eq (eltainer-fs-entry-type a) 'directory))
                              (db (eq (eltainer-fs-entry-type b) 'directory)))
                          (cond ((and da (not db)) t)
                                ((and db (not da)) nil)
                                (t (string<
                                    (eltainer-fs-entry-name a)
                                    (eltainer-fs-entry-name b)))))))))
    (erase-buffer)
    (insert "  " (directory-file-name default-directory) ":\n"
            "  total 0\n")
    (dolist (e sorted)
      (insert (eltainer-dired--emit-line e)))))

;;; ---------------------------------------------------------------------------
;;; Navigation + visit

(defun eltainer-dired--resolve-name (basename)
  "Resolve BASENAME relative to `eltainer-dired--remote-dir'.
Handles `.', `..', and absolute paths; uses string surgery rather
than `expand-file-name' so sentinel-shaped paths don't get mangled."
  (let ((cur (or eltainer-dired--remote-dir "/")))
    (cond
     ((or (null basename) (equal basename "")) cur)
     ((equal basename ".") cur)
     ((equal basename "..")
      (let ((parent (file-name-directory (directory-file-name cur))))
        (or parent "/")))
     ((string-prefix-p "/" basename) basename)
     (t
      (concat (file-name-as-directory cur) basename)))))

(defun eltainer-dired--name-at-point ()
  "Return the basename on the current line, or nil.
Uses verbatim mode so dired's expand-file-name doesn't touch the
sentinel-shaped `default-directory'."
  (let ((name (ignore-errors (dired-get-filename 'verbatim t))))
    (and name (file-name-nondirectory (directory-file-name name)))))

(defun eltainer-dired--enter-directory (remote-path)
  "Switch this buffer's listing to REMOTE-PATH and re-render.
Normalises trailing-slash so `/etc/' and `/etc' produce the same
buffer name + remote-dir state."
  (let* ((remote-path
          (cond
           ((or (null remote-path) (equal remote-path "")) "/")
           ((and (> (length remote-path) 1)
                 (string-suffix-p "/" remote-path))
            (substring remote-path 0 -1))
           (t remote-path)))
         (entries (funcall eltainer-dired--list-fn remote-path)))
    (setq eltainer-dired--remote-dir remote-path
          default-directory (concat eltainer-dired--sentinel-prefix
                                    (file-name-as-directory remote-path)))
    (rename-buffer (eltainer-dired--buffer-name) t)
    (eltainer-dired--render entries)
    (goto-char (point-min))
    (forward-line 2)))

(defun eltainer-dired--visit-file (remote-path)
  "Pop a read-only buffer showing REMOTE-PATH's contents via `-cat-fn'."
  (let* ((bytes (funcall eltainer-dired--cat-fn remote-path))
         (label eltainer-dired--label)
         (buf (get-buffer-create
               (format "*%s:%s*" label remote-path))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (decode-coding-string (or bytes "") 'utf-8)))
      (goto-char (point-min))
      (setq buffer-read-only t)
      (when (fboundp 'view-mode) (view-mode 1)))
    (pop-to-buffer buf)))

(defun eltainer-dired-find-file ()
  "RET / f binding: visit the entry at point.
Directories switch this buffer to the new listing; regular files
pop a read-only buffer; symlinks follow to the target (one hop).
Other types error rather than misbehave."
  (interactive)
  (unless (and eltainer-dired--list-fn eltainer-dired--cat-fn)
    (user-error "eltainer-dired: this buffer has no backend"))
  (let* ((basename (eltainer-dired--name-at-point))
         (remote (eltainer-dired--resolve-name basename)))
    (unless remote (user-error "No entry at point"))
    ;; Re-stat by listing the parent and finding the entry — saves a
    ;; second backend call for the common case where the type is
    ;; already known.  For now we just trust the line's display char.
    (let* ((line-start (line-beginning-position))
           (tc (and (>= (- (point-max) line-start) 3)
                    (char-after (+ line-start 2)))))
      (pcase tc
        (?d (eltainer-dired--enter-directory remote))
        (?-  (eltainer-dired--visit-file remote))
        (?l
         ;; Symlink: try to follow.  If the target is relative, resolve
         ;; against the current dir; if absolute, take as-is.  Then
         ;; behave as if the user clicked that target.
         (eltainer-dired--follow-symlink remote))
        (_ (user-error "eltainer-dired: don't know how to visit type %S"
                       (and tc (char-to-string tc))))))))

(defun eltainer-dired--follow-symlink (remote)
  "Resolve the symlink at REMOTE one hop and visit the target."
  (let* ((parent (file-name-directory remote))
         (parent-entries (funcall eltainer-dired--list-fn
                                  (directory-file-name parent)))
         (basename (file-name-nondirectory remote))
         (entry (cl-find basename parent-entries
                         :key #'eltainer-fs-entry-name :test #'string=))
         (target (and entry (eltainer-fs-entry-link-target entry))))
    (cond
     ((null entry)
      (user-error "eltainer-dired: %s not found in %s" basename parent))
     ((null target)
      (user-error "eltainer-dired: %s is not a symlink in the listing"
                  basename))
     (t
      (let* ((resolved (if (string-prefix-p "/" target)
                           target
                         (concat (file-name-as-directory parent) target))))
        ;; We don't know the target's type without another stat; let
        ;; the user RET on it again if they want to dive in.  Switch
        ;; to the target's *parent* and put point on it.
        (eltainer-dired--enter-directory
         (or (file-name-directory (directory-file-name resolved)) "/"))
        (goto-char (point-min))
        (when (re-search-forward
               (format " %s\\($\\| -> \\)"
                       (regexp-quote
                        (file-name-nondirectory
                         (directory-file-name resolved))))
               nil t)
          (beginning-of-line)))))))

(defun eltainer-dired-up-directory ()
  "^ binding: go to the parent directory inside the container."
  (interactive)
  (eltainer-dired--enter-directory
   (eltainer-dired--resolve-name "..")))

(defun eltainer-dired-revert (&optional _ignore-auto _noconfirm)
  "g binding: re-list the current remote directory."
  (interactive)
  (let ((point (point)))
    (eltainer-dired--enter-directory eltainer-dired--remote-dir)
    (goto-char (min point (point-max)))))

(defun eltainer-dired-not-implemented ()
  "v1 read-only guard for dired bindings we don't yet route through
the container backends.  See docs/container-dired-plan.md §7."
  (interactive)
  (user-error
   "eltainer-dired v1 is read-only — see docs/container-dired-plan.md §8 (writable v2)"))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar eltainer-dired-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map dired-mode-map)
    (define-key map (kbd "RET") #'eltainer-dired-find-file)
    (define-key map (kbd "f")   #'eltainer-dired-find-file)
    (define-key map (kbd "e")   #'eltainer-dired-find-file)
    (define-key map (kbd "^")   #'eltainer-dired-up-directory)
    ;; v1 read-only guards: rebind dired's write operations to a
    ;; user-error pointing at the plan doc.
    (dolist (key '("D" "R" "C" "+" "M" "O" "T" "S" "H" "Z"))
      (define-key map (kbd key) #'eltainer-dired-not-implemented))
    (define-key map (kbd "C-x C-q") #'eltainer-dired-not-implemented)
    map)
  "Keymap for `eltainer-dired-mode'.  Inherits dired-mode-map for
the navigation + marking surface; overrides the write ops.")

(define-derived-mode eltainer-dired-mode dired-mode "Container-Dired"
  "Major mode for browsing a container's filesystem with dired keys.

Derives from `dired-mode' so every navigation / marking / sort
keystroke from muscle memory works identically.  Filesystem I/O
is routed through buffer-local backend functions
\(`eltainer-dired--list-fn' and `-cat-fn') set by the child mode's
entry point.  v1 is read-only — write operations (rename, delete,
copy, mkdir, wdired) error out with a pointer to the plan doc."
  :group 'eltainer-dired
  (setq-local revert-buffer-function #'eltainer-dired-revert)
  (setq-local require-final-newline nil))

;;; ---------------------------------------------------------------------------
;;; Entry point for child modes

(defun eltainer-dired--buffer-name ()
  "Return the conventional buffer name for the current sentinel."
  (format "*%s:%s*" eltainer-dired--label eltainer-dired--remote-dir))

(defun eltainer-dired-open (label sentinel-prefix initial-remote-dir list-fn cat-fn)
  "Open a container-dired buffer.

LABEL — short identity for the mode-line / buffer name
        \(e.g. \"docker:eltainer-ticker\").
SENTINEL-PREFIX — the host-side prefix for sentinel paths, ending
        in the colon before the remote path
        \(e.g. \"/docker:eltainer-ticker:\").
INITIAL-REMOTE-DIR — absolute path inside the container to land on.
LIST-FN / CAT-FN — backend closures the parent calls without
        knowing about docker vs. k8s.

Pops the buffer."
  (let ((buf (get-buffer-create
              (format "*%s:%s*" label initial-remote-dir))))
    (with-current-buffer buf
      ;; Enter the mode *first* — `define-derived-mode' runs
      ;; `kill-all-local-variables', which would otherwise wipe the
      ;; backend closures we're about to bind.
      (eltainer-dired-mode)
      (setq-local default-directory
                  (concat sentinel-prefix
                          (file-name-as-directory initial-remote-dir)))
      (setq-local eltainer-dired--label label
                  eltainer-dired--sentinel-prefix sentinel-prefix
                  eltainer-dired--remote-dir initial-remote-dir
                  eltainer-dired--list-fn list-fn
                  eltainer-dired--cat-fn cat-fn)
      (let ((entries (funcall list-fn initial-remote-dir)))
        (eltainer-dired--render entries))
      (goto-char (point-min))
      (forward-line 2))                ; past header + `total 0'
    (pop-to-buffer buf)))

(provide 'eltainer-dired)
;;; eltainer-dired.el ends here
