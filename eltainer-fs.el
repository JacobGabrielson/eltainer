;;; eltainer-fs.el --- Shared filesystem-listing primitives -*- lexical-binding: t -*-
;;
;; The non-UI backbone for browsing a container's filesystem.  Both
;; halves of eltainer (Pods via `k8s-exec', Docker containers via
;; `docker-exec-run' once it lands) feed the same POSIX shell scripts
;; into their respective exec primitives, and parse the output back
;; into the same `eltainer-fs-entry' struct.  The UI layer
;; (`eltainer-dired-mode' once it lands) renders entries the same way
;; regardless of backend.
;;
;; The container is assumed to have a POSIX-ish userland: `sh',
;; `find', `stat', `readlink', `cat'.  Both busybox and GNU coreutils
;; are supported; the exec scripts use only the common subset of
;; `stat -c' format codes that both implement (no GNU-only options
;; like `--time-style' or `--quoting-style').  Distroless / scratch
;; containers don't have any of these tools — see
;; `eltainer-fs-check-failure' for how that's surfaced.

(require 'cl-lib)

(defgroup eltainer-fs nil
  "Container filesystem-listing primitives."
  :group 'eltainer
  :prefix "eltainer-fs-")

;;; ---------------------------------------------------------------------------
;;; Entry struct

(cl-defstruct (eltainer-fs-entry
               (:constructor eltainer-fs-entry--new)
               (:copier nil))
  name           ; string — basename for `list', full path for `stat'
  type           ; symbol — file directory symlink fifo socket block char unknown
  mode-string    ; string — "rwxr-xr-x", 9 chars (no leading type)
  nlink          ; integer
  owner          ; string
  group          ; string
  size           ; integer (bytes)
  mtime          ; integer (unix epoch seconds)
  link-target)   ; string or nil

;;; ---------------------------------------------------------------------------
;;; Customization

(defcustom eltainer-fs-max-cat-bytes (* 5 1024 1024)
  "Refuse to read files larger than this many bytes via the cat path.
The UI layer should prompt the user if they want to override."
  :type 'integer
  :group 'eltainer-fs)

;;; ---------------------------------------------------------------------------
;;; Parsing helpers

(defconst eltainer-fs--stat-type-alist
  '(("regular file"           . file)
    ("regular empty file"     . file)
    ("directory"              . directory)
    ("symbolic link"          . symlink)
    ("socket"                 . socket)
    ("fifo"                   . fifo)
    ("block special file"     . block)
    ("character special file" . char))
  "Map `stat -c %F' file-type strings to entry type symbols.")

(defun eltainer-fs--type-from-stat (s)
  "Return the entry type symbol for `stat -c %F' string S."
  (or (cdr (assoc s eltainer-fs--stat-type-alist)) 'unknown))

(defun eltainer-fs--octal-to-rwx (mode)
  "Convert numeric MODE (low 9 bits) to a 9-char rwx string.
Setuid/setgid/sticky bits are not represented; rare for browsing."
  (let ((chars "rwxrwxrwx")
        (out (make-string 9 ?-)))
    (dotimes (i 9)
      (when (/= 0 (logand mode (ash 1 (- 8 i))))
        (aset out i (aref chars i))))
    out))

(defun eltainer-fs--parse-line (line full-name)
  "Parse one stat-output LINE into an `eltainer-fs-entry'.
LINE has tab-separated fields: TYPE PERMS SIZE MTIME OWNER GROUP NLINK NAME LINK.
If FULL-NAME is non-nil keep the path as-is; otherwise reduce to basename."
  (let ((parts (split-string line "\t")))
    (unless (>= (length parts) 9)
      (error "eltainer-fs: malformed entry line: %S" line))
    (let* ((type (eltainer-fs--type-from-stat (nth 0 parts)))
           (mode (eltainer-fs--octal-to-rwx
                  (string-to-number (nth 1 parts) 8)))
           (size (string-to-number (nth 2 parts)))
           (mtime (string-to-number (nth 3 parts)))
           (owner (nth 4 parts))
           (group (nth 5 parts))
           (nlink (string-to-number (nth 6 parts)))
           (path (nth 7 parts))
           (link (nth 8 parts))
           (name (if full-name path (file-name-nondirectory path))))
      (eltainer-fs-entry--new
       :name name
       :type type
       :mode-string mode
       :nlink nlink
       :owner owner
       :group group
       :size size
       :mtime mtime
       :link-target (and (eq type 'symlink) (> (length link) 0) link)))))

(defun eltainer-fs-parse-list-output (raw-bytes)
  "Parse the stdout of `eltainer-fs-list-script' (a unibyte string).
Returns a list of `eltainer-fs-entry'.  Iterates the buffer directly
rather than `split-string' so big directories don't allocate N temp
line strings before parsing."
  (let* ((decoded (decode-coding-string (or raw-bytes "") 'utf-8))
         (len (length decoded))
         (start 0)
         out)
    (while (< start len)
      (let ((nl (or (string-search "\n" decoded start) len)))
        (when (> nl start)
          (push (eltainer-fs--parse-line (substring decoded start nl) nil)
                out))
        (setq start (1+ nl))))
    (nreverse out)))

(defun eltainer-fs-parse-stat-output (raw-bytes)
  "Parse the stdout of `eltainer-fs-stat-script' into one
`eltainer-fs-entry' with the full path preserved as :name."
  (let* ((decoded (decode-coding-string (or raw-bytes "") 'utf-8))
         ;; Strip only trailing newlines — `string-trim' would also eat
         ;; the trailing tab + empty link-target field.
         (line (replace-regexp-in-string "\n+\\'" "" decoded)))
    (eltainer-fs--parse-line line t)))

;;; ---------------------------------------------------------------------------
;;; Shell scripts (POSIX, run via `sh -c')

(defconst eltainer-fs--stat-format
  "%F\t%a\t%s\t%Y\t%U\t%G\t%h\t%n"
  "`stat -c' format: TYPE PERMS SIZE MTIME OWNER GROUP NLINK NAME.
Real tab characters (busybox `stat' does not interpret \\t escapes
in single-quoted format strings, only GNU stat does).")

(defconst eltainer-fs-list-script
  (concat "[ -d \"$1\" ] || { echo \"eltainer-fs: not a directory: $1\" >&2; exit 1; }; "
          "find \"$1\" -mindepth 1 -maxdepth 1 | while IFS= read -r f; do "
          "out=$(stat -c '" eltainer-fs--stat-format "' -- \"$f\") || continue; "
          "link=$(if [ -L \"$f\" ]; then readlink -- \"$f\"; fi); "
          "printf '%s\\t%s\\n' \"$out\" \"$link\"; "
          "done")
  "Sh script to list one directory's entries with metadata.
Output: one line per entry, tab-separated:
  TYPE PERMS SIZE MTIME OWNER GROUP NLINK NAME LINK-TARGET
LINK-TARGET is empty for non-symlinks.  Filenames with embedded
newlines or tabs are not supported (extremely rare in practice).
The leading `-d' guard makes a missing or non-directory path
exit non-zero so the failure isn't silently swallowed.")

(defconst eltainer-fs-stat-script
  (concat "out=$(stat -c '" eltainer-fs--stat-format "' -- \"$1\") || exit; "
          "link=$(if [ -L \"$1\" ]; then readlink -- \"$1\"; fi); "
          "printf '%s\\t%s\\n' \"$out\" \"$link\"")
  "Sh script for the single-entry stat path; same line format as
`eltainer-fs-list-script'.  Propagates stat failure via `|| exit'.")

;;; ---------------------------------------------------------------------------
;;; Failure detection (distroless + general)

(defconst eltainer-fs--no-shell-rx
  (rx (or "exec: \"sh\""
          "executable file not found"
          "no such file or directory"
          "starting container process caused"))
  "Pattern in an exec failure that means `sh' (or its peers) isn't there.
Distroless and scratch images ship without `/bin/sh', `find',
`stat' etc., so the listing script can't run at all in them — the
underlying error is several lines of OCI runtime noise; this rx
catches the diagnostic substrings.")

(cl-defun eltainer-fs-check-failure (context &key exit-code status stderr message)
  "Signal an error iff the exec result is a failure.
CONTEXT is a short string used to prefix the diagnostic; the
keyword args mirror the fields each backend's result struct
exposes:
  :exit-code  integer or nil  (k8s success may have nil exit-code
                                with :status \"Success\")
  :status     string or nil
  :stderr     string or nil
  :message    string or nil

The distroless / scratch-image case (`sh' / `find' / `stat'
missing) is recognised via `eltainer-fs--no-shell-rx' and gets
its own one-line message in place of the wall of OCI text."
  (let ((combined (mapconcat #'identity
                             (delq nil (list stderr message status))
                             " ")))
    (unless (or (eql exit-code 0)
                (and (null exit-code) (equal status "Success")))
      (cond
       ((and (null exit-code)
             (stringp combined)
             (string-match-p eltainer-fs--no-shell-rx combined))
        (error "eltainer-fs: container has no `sh' / `find' / `stat' \
\(distroless or scratch image) — filesystem browse needs a POSIX \
shell + GNU/BusyBox coreutils inside the container"))
       (t
        (error "eltainer-fs: %s failed (exit=%S): %s"
               context exit-code
               (or (and stderr (> (length stderr) 0)
                        (string-trim stderr))
                   message
                   status
                   "unknown error")))))))

(provide 'eltainer-fs)
;;; eltainer-fs.el ends here
