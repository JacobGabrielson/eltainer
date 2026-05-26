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

(defvar-local eltainer-dired--exec-fn nil
  "Closure (lambda (ARGV)) running ARGV in this buffer's container.
Returns the backend's result struct (docker-exec-result or
k8s-exec-result).  Required for v2 writable ops; nil for read-only
buffers that haven't wired one up.")

(defvar-local eltainer-dired--check-fn nil
  "Closure (lambda (RESULT CONTEXT)) signalling on RESULT failure.
Set by the child mode; differs across backends because the result
structs carry different keyword fields.  See `docker-fs--check' and
`k8s-fs--check' for the canonical implementations.")

(defvar-local eltainer-dired--write-fn nil
  "Closure (lambda (REMOTE-DIR BASENAME BYTES)) writing BYTES into
the container at REMOTE-DIR / BASENAME.  Docker uses the archive
PUT API; k8s rides base64 through argv.  Optional — used only by
host -> container copy.")

(defvar-local eltainer-dired--probed nil
  "Non-nil once we've verified rm / mv / mkdir / cp exist in this
container.  See `eltainer-dired--ensure-write-binaries'.")

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
    (let ((header-start (point-marker)))
      (insert "  " (directory-file-name default-directory) ":\n"
              "  total 0\n")
      ;; Dired keys off `dired-subdir-alist' to answer
      ;; `dired-current-directory' (and thus `dired-get-marked-files');
      ;; we have one subdir per buffer, headed at HEADER-START.
      (setq-local dired-subdir-alist
                  (list (cons default-directory header-start))))
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
      (let* ((parent (file-name-directory (directory-file-name cur)))
             (norm (and parent (directory-file-name parent))))
        (cond ((null norm) "/")
              ((equal norm "") "/")
              (t norm))))
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
  "Guard for dired bindings that touch metadata ops we don't route
through the container backends (chmod / chown / touch / symlink /
hardlink / compress).  See docs/container-dired-plan.md §8."
  (interactive)
  (user-error
   "eltainer-dired: %s is not in scope (chmod / chown / touch etc.)"
   (key-description (this-command-keys))))

;;; ---------------------------------------------------------------------------
;;; Writable v2 ops
;;
;; Each op routes through `eltainer-dired--exec-fn' + `--check-fn'
;; (set by the child mode) which run a shell command inside the
;; container.  Marked-file aware — they take their cue from
;; `dired-get-marked-files', so the standard dired mark UX
;; (m / u / U / t / DEL / etc.) feeds straight through.

(defun eltainer-dired--ensure-ops ()
  "Signal if this buffer has no writable-op backends wired up.
Called at the top of every write entry point so the failure is loud."
  (unless (and eltainer-dired--exec-fn eltainer-dired--check-fn)
    (user-error "eltainer-dired: this buffer is read-only \
\(no exec backend wired up)")))

(defun eltainer-dired--run-checked (argv context)
  "Run ARGV via `eltainer-dired--exec-fn' and signal on failure."
  (let ((r (funcall eltainer-dired--exec-fn argv)))
    (funcall eltainer-dired--check-fn r context)
    r))

(defun eltainer-dired--ensure-write-binaries ()
  "Verify rm / mv / mkdir / cp all exist in this buffer's container,
lazily and cached on the buffer.  Distroless / scratch surfaces a
single friendly error instead of one per missing binary."
  (unless eltainer-dired--probed
    (eltainer-dired--ensure-ops)
    (condition-case err
        (eltainer-dired--run-checked
         (list "sh" "-c" eltainer-fs-write-probe-script)
         "probe rm / mv / mkdir / cp")
      (error
       (user-error
        "eltainer-dired: this container lacks one of `rm', `mv', \
`mkdir', `cp' (distroless or scratch image) — writable ops require \
a POSIX shell + coreutils.  Detail: %s"
        (error-message-string err))))
    (setq eltainer-dired--probed t)))

(defun eltainer-dired--marked-remote-paths ()
  "Return the list of container-side remote paths for the marked
files \(or for the file at point if nothing is marked).  Sentinel
paths returned by `dired-get-marked-files' are parsed back into
absolute container paths."
  (let* ((files (dired-get-marked-files nil nil nil nil t)) ; t = current line if no marks
         (out nil))
    (dolist (f files)
      (let ((info (eltainer-dired-parse-path f)))
        (push (or (plist-get info :remote) f) out)))
    (nreverse out)))

(defun eltainer-dired--current-remote-path ()
  "Return the remote path on the current line, or signal."
  (let* ((basename (eltainer-dired--name-at-point))
         (remote (and basename (eltainer-dired--resolve-name basename))))
    (or remote (user-error "No entry on this line"))))

(defun eltainer-dired-do-delete (&optional _arg)
  "Delete the marked files (or file at point) inside the container.
Uses `rm -rf' via the buffer's exec backend, after a yes-or-no
confirmation listing each path."
  (interactive "P")
  (eltainer-dired--ensure-ops)
  (eltainer-dired--ensure-write-binaries)
  (let* ((paths (eltainer-dired--marked-remote-paths))
         (n (length paths)))
    (when (zerop n) (user-error "No files marked or at point"))
    (when (yes-or-no-p
           (format "Delete %d %s? (%s)"
                   n (if (= n 1) "file" "files")
                   (mapconcat #'identity (seq-take paths 4) ", ")))
      (dolist (p paths)
        (eltainer-dired--run-checked
         (list "rm" "-rf" "--" p) (format "delete %s" p)))
      (message "eltainer-dired: deleted %d" n)
      (eltainer-dired-revert))))

(defun eltainer-dired--read-target (prompt &optional default)
  "Prompt for a destination path.  Treat as remote unless it parses
back into a sentinel \(then strip the prefix), and resolve relative
paths against the current remote-dir."
  (let* ((raw (read-string prompt default))
         (info (eltainer-dired-parse-path raw))
         (path (cond
                (info (plist-get info :remote))
                ((file-name-absolute-p raw) raw)
                (t (concat (file-name-as-directory
                            eltainer-dired--remote-dir)
                           raw)))))
    path))

(defun eltainer-dired-do-rename ()
  "Rename / move the marked files (or file at point).
Single file: prompts for a new path.  Multiple: prompts for a
destination directory and moves every marked file into it,
preserving basenames."
  (interactive)
  (eltainer-dired--ensure-ops)
  (eltainer-dired--ensure-write-binaries)
  (let* ((paths (eltainer-dired--marked-remote-paths))
         (n (length paths)))
    (when (zerop n) (user-error "No files marked or at point"))
    (cond
     ((= n 1)
      (let* ((src (car paths))
             (dst (eltainer-dired--read-target
                   (format "Rename %s to: " src) src)))
        (when (equal src dst)
          (user-error "Rename to the same path is a no-op"))
        (eltainer-dired--run-checked
         (list "mv" "--" src dst) (format "rename %s -> %s" src dst))
        (message "eltainer-dired: renamed %s -> %s" src dst)))
     (t
      (let* ((dst-dir (eltainer-dired--read-target
                       (format "Move %d files to dir: " n))))
        (dolist (src paths)
          (let ((target (concat (file-name-as-directory dst-dir)
                                (file-name-nondirectory src))))
            (eltainer-dired--run-checked
             (list "mv" "--" src target)
             (format "rename %s -> %s" src target))))
        (message "eltainer-dired: moved %d files to %s" n dst-dir))))
    (eltainer-dired-revert)))

(defun eltainer-dired-create-directory (path)
  "Create directory PATH inside the container (recursive `mkdir -p').
Relative PATH is resolved against the current remote-dir."
  (interactive
   (list (read-string
          (format "Create directory (rel to %s): "
                  (or eltainer-dired--remote-dir "/")))))
  (eltainer-dired--ensure-ops)
  (eltainer-dired--ensure-write-binaries)
  (when (or (null path) (string-empty-p path))
    (user-error "Empty directory name"))
  (let ((remote (if (file-name-absolute-p path) path
                  (concat (file-name-as-directory
                           (or eltainer-dired--remote-dir "/"))
                          path))))
    (eltainer-dired--run-checked
     (list "mkdir" "-p" "--" remote) (format "mkdir %s" remote))
    (message "eltainer-dired: created %s" remote)
    (eltainer-dired-revert)))

(defun eltainer-dired-do-copy ()
  "Copy the marked files (or file at point).

Destination grammar:
  bare-name / `/abs/path' → in-container `cp -r' (default).
  `host:/abs/path'        → export to host via `cat-fn'.
  sentinel /docker:.../   → in-container only when same container.

The `host:' prefix is explicit on purpose; without it absolute paths
mean inside the container, which matches the buffer's mental model."
  (interactive)
  (eltainer-dired--ensure-ops)
  (let* ((paths (eltainer-dired--marked-remote-paths))
         (n (length paths)))
    (when (zerop n) (user-error "No files marked or at point"))
    (let* ((prompt (if (= n 1)
                       (format "Copy %s to: " (car paths))
                     (format "Copy %d files to dir: " n)))
           (raw (read-string prompt))
           (info (eltainer-dired-parse-path raw)))
      (cond
       ;; Explicit host export
       ((string-prefix-p "host:" raw)
        (eltainer-dired--copy-to-host
         paths (substring raw (length "host:")) n))
       ;; Same-container sentinel (we don't support cross-container)
       (info
        (unless (or (and (eq 'docker (plist-get info :backend))
                         (string-prefix-p
                          (format "/docker:%s:"
                                  (plist-get info :container))
                          eltainer-dired--sentinel-prefix))
                    (and (eq 'k8s (plist-get info :backend))
                         (string-prefix-p
                          (format "/k8s:%s/%s"
                                  (plist-get info :ns)
                                  (plist-get info :pod))
                          eltainer-dired--sentinel-prefix)))
          (user-error
           "eltainer-dired: cross-container copy not supported \
\(prefix `host:' to export to disk first)"))
        (eltainer-dired--copy-in-container
         paths (plist-get info :remote) n))
       ;; Bare relative name       → in-container cp under cwd
       ((not (string-prefix-p "/" raw))
        (let ((dst (concat (file-name-as-directory
                            (or eltainer-dired--remote-dir "/"))
                           raw)))
          (eltainer-dired--copy-in-container paths dst n)))
       ;; Absolute path            → in-container cp
       (t
        (eltainer-dired--copy-in-container paths raw n)))
      (eltainer-dired-revert))))

(defun eltainer-dired--copy-in-container (paths dst n)
  "In-container `cp -r' from each PATHS into DST.  Uses the exec backend."
  (eltainer-dired--ensure-write-binaries)
  (if (= n 1)
      (let ((src (car paths)))
        (eltainer-dired--run-checked
         (list "cp" "-r" "--" src dst) (format "cp %s -> %s" src dst))
        (message "eltainer-dired: copied %s -> %s" src dst))
    (dolist (src paths)
      (eltainer-dired--run-checked
       (list "cp" "-r" "--" src dst)
       (format "cp %s -> %s/" src dst)))
    (message "eltainer-dired: copied %d files into %s" n dst)))

(defun eltainer-dired-import-from-host ()
  "Import a host-side file into the container at the current dir.
Prompts for the host filename and writes it via `--write-fn'.
On docker that PUTs through the archive API; on k8s that base64-
encodes through argv (with a size cap)."
  (interactive)
  (eltainer-dired--ensure-ops)
  (unless eltainer-dired--write-fn
    (user-error "eltainer-dired: this buffer has no write backend"))
  (let* ((host (read-file-name
                "Import host file into this directory: " nil nil t))
         (basename (file-name-nondirectory host))
         (bytes (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (let ((coding-system-for-read 'binary))
                    (insert-file-contents-literally host))
                  (buffer-substring-no-properties (point-min) (point-max))))
         (dst-dir (or eltainer-dired--remote-dir "/")))
    (funcall eltainer-dired--write-fn dst-dir basename bytes)
    (message "eltainer-dired: imported %s -> %s%s"
             host (file-name-as-directory dst-dir) basename)
    (eltainer-dired-revert)))

(defun eltainer-dired--copy-to-host (paths host-dst n)
  "Read each remote PATHS via `--cat-fn' and write to HOST-DST.
If N > 1, HOST-DST is treated as a directory."
  (unless eltainer-dired--cat-fn
    (user-error "eltainer-dired: no cat backend wired up"))
  (let ((dir-mode (or (> n 1) (file-directory-p host-dst))))
    (dolist (src paths)
      (let* ((bytes (funcall eltainer-dired--cat-fn src))
             (target (if dir-mode
                         (expand-file-name (file-name-nondirectory src)
                                           host-dst)
                       host-dst))
             (coding-system-for-write 'binary))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert (or bytes ""))
          (write-region (point-min) (point-max) target nil 'quiet))))
    (message "eltainer-dired: copied %d to host %s" n host-dst)))

;;; ---------------------------------------------------------------------------
;;; wdired support — buffer-edit-to-rename
;;
;; Standard wdired calls `wdired-do-renames' with a list of (FROM . TO)
;; pairs and then `rename-file' for each.  `rename-file' goes through
;; `file-name-handler-alist'; sentinel paths aren't registered, so the
;; renames would hit the underlying POSIX syscall and fail.  We
;; intercept `wdired-do-renames' for our buffers and route every pair
;; through the exec backend instead.

(defun eltainer-dired--wdired-do-renames (orig-fn renames)
  "Around-advice for `wdired-do-renames': in `eltainer-dired-mode'
buffers, emit one `mv' exec per renamed line; otherwise defer to
the original."
  (if (derived-mode-p 'eltainer-dired-mode)
      (progn
        (eltainer-dired--ensure-ops)
        (eltainer-dired--ensure-write-binaries)
        (let ((count 0))
          (dolist (pair renames)
            (let* ((from-raw (car pair))
                   (to-raw   (cdr pair))
                   (from (or (plist-get (eltainer-dired-parse-path from-raw)
                                        :remote)
                             from-raw))
                   (to   (or (plist-get (eltainer-dired-parse-path to-raw)
                                        :remote)
                             to-raw)))
              (unless (equal from to)
                (eltainer-dired--run-checked
                 (list "mv" "--" from to)
                 (format "wdired rename %s -> %s" from to))
                (cl-incf count))))
          (message "eltainer-dired: wdired applied %d rename%s"
                   count (if (= count 1) "" "s"))
          nil))                            ; suppress orig
    (funcall orig-fn renames)))

(with-eval-after-load 'wdired
  (advice-add 'wdired-do-renames :around
              #'eltainer-dired--wdired-do-renames))


;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar eltainer-dired-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map dired-mode-map)
    (define-key map (kbd "RET") #'eltainer-dired-find-file)
    (define-key map (kbd "f")   #'eltainer-dired-find-file)
    (define-key map (kbd "e")   #'eltainer-dired-find-file)
    (define-key map (kbd "^")   #'eltainer-dired-up-directory)
    ;; v2 writable ops (all route through the buffer's exec backend).
    (define-key map (kbd "D") #'eltainer-dired-do-delete)
    (define-key map (kbd "R") #'eltainer-dired-do-rename)
    (define-key map (kbd "C") #'eltainer-dired-do-copy)
    (define-key map (kbd "+") #'eltainer-dired-create-directory)
    (define-key map (kbd "I") #'eltainer-dired-import-from-host)
    ;; Out of scope: metadata ops we haven't wired.  Keep them loud
    ;; rather than silently no-op so users know what's missing.
    (dolist (key '("M" "O" "T" "S" "H" "Z"))
      (define-key map (kbd key) #'eltainer-dired-not-implemented))
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
  (setq-local require-final-newline nil)
  ;; Pin the listing-switches dired *thinks* this buffer was produced
  ;; with.  Critically this must NOT contain `-F' / `--classify': our
  ;; emitter writes no type-indicator suffixes, but if dired sees `-F'
  ;; in the switches it back-steps one char off `dired-move-to-end-of-
  ;; filename' to strip an adornment that isn't there — and eats the
  ;; last real char of every name (`bin' -> `bi').
  (setq-local dired-actual-switches "-al"))

;;; ---------------------------------------------------------------------------
;;; Entry point for child modes

(defun eltainer-dired--buffer-name ()
  "Return the conventional buffer name for the current sentinel."
  (format "*%s:%s*" eltainer-dired--label eltainer-dired--remote-dir))

(cl-defun eltainer-dired-open (label sentinel-prefix initial-remote-dir
                                     list-fn cat-fn
                                     &key (mode #'eltainer-dired-mode))
  "Open a container-dired buffer.

LABEL — short identity for the mode-line / buffer name
        \(e.g. \"docker:eltainer-ticker\").
SENTINEL-PREFIX — the host-side prefix for sentinel paths, ending
        in the colon before the remote path
        \(e.g. \"/docker:eltainer-ticker:\").
INITIAL-REMOTE-DIR — absolute path inside the container to land on.
LIST-FN / CAT-FN — backend closures the parent calls without
        knowing about docker vs. k8s.
MODE (keyword) — major mode to enter; defaults to
        `eltainer-dired-mode'.  Child modes (e.g.
        `docker-dired-mode') pass themselves here so we don't
        re-enter the mode after binding the backends.

Pops the buffer."
  (let ((buf (get-buffer-create
              (format "*%s:%s*" label initial-remote-dir))))
    (with-current-buffer buf
      ;; Enter the (possibly child) mode *first* — `define-derived-mode'
      ;; runs `kill-all-local-variables', which would otherwise wipe
      ;; the backend closures we're about to bind.
      (funcall mode)
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
    (pop-to-buffer buf)
    buf))

(provide 'eltainer-dired)
;;; eltainer-dired.el ends here
