;;; docker-build.el --- Build an image from a Dockerfile -*- lexical-binding: t -*-
;;
;; `M-x docker-build DIR' tars up DIR (the build context), POSTs to
;; `/build', and streams the response into `*docker:build*'.  No
;; CLI shell-out — the tar is built in pure Elisp on top of the
;; USTAR primitives we already use for the docker-fs archive-PUT.
;;
;; v1 scope:
;; - Recursive walk of DIR (excludes the standard noise: `.git',
;;   `.elc', backup files, *.tmp).  Full `.dockerignore' support is
;;   queued for v2; for v1 the user wraps their context in a clean
;;   directory if they need ignore semantics.
;; - Classic (non-BuildKit) builder.  BuildKit needs the
;;   `application/x-tar' header + a different stream format and
;;   can come later.
;; - `--no-cache' / `--target' / `--build-arg' / `--platform' as
;;   `docker-build' keyword args; default: cache enabled, default
;;   target, no build args, daemon's native platform.

(require 'cl-lib)
(require 'subr-x)
(require 'docker-config)
(require 'docker-api)
(require 'docker-http)
(require 'docker-fs)                    ; for the USTAR header builder
(require 'docker-stream)                ; ndjson splitter
(require 'docker)

(defgroup docker-build nil
  "Image build from a Dockerfile via the engine API."
  :group 'docker
  :prefix "docker-build-")

(defcustom docker-build-skip-rx
  (rx (or
       ;; SCM / IDE state
       (seq "/.git/")    (seq "/.git" string-end)
       (seq "/.hg/")     (seq "/.svn/")
       (seq "/.idea/")   (seq "/.vscode/")
       ;; Emacs noise
       (seq ".elc" string-end)
       (seq "~" string-end)
       (seq "/#" (* nonl) "#" string-end)
       (seq "/.#" (* nonl) string-end)
       ;; Generic temp
       (seq ".tmp" string-end)
       (seq ".log" string-end)))
  "Regexp matching paths to skip when building the build-context tar.
Coarse `.dockerignore' substitute -- file paths matching this drop
out of the tar.  v2 will read `.dockerignore' from the build dir
directly."
  :type 'regexp
  :group 'docker-build)

;;; ---------------------------------------------------------------------------
;;; Recursive USTAR builder
;;
;; `docker-fs--make-tar-file-header' (from docker-fs.el) writes a
;; single-file USTAR header.  Stack many of those + their padded
;; payloads + a 2-block NUL terminator and you have a streamable
;; build-context tar.

(defun docker-build--walk (root)
  "Return a list of `(REL-PATH . ABS-PATH)' for every file under ROOT.
ROOT is included as the base; REL-PATH is relative to it (no
leading `./').  Skips entries matching `docker-build-skip-rx'."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (skip docker-build-skip-rx)
         out)
    (cl-labels
        ((walk (dir prefix)
           (dolist (entry (directory-files dir nil "\\`[^.]\\|\\`\\.[^.]"))
             (let* ((abs (expand-file-name entry dir))
                    (rel (concat prefix entry)))
               (cond
                ((string-match-p skip abs))           ; drop
                ((file-symlink-p abs))                ; skip symlinks for safety
                ((file-directory-p abs)
                 (walk (file-name-as-directory abs)
                       (concat rel "/")))
                ((file-regular-p abs)
                 (push (cons rel abs) out)))))))
      (walk root "")
      (nreverse out))))

(defun docker-build--read-bytes (path)
  "Slurp PATH's contents as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (insert-file-contents-literally path))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun docker-build--mode-bits (path)
  (or (file-modes path) #o644))

(defun docker-build--make-tar (root)
  "Tar up every file under ROOT and return the bytes (unibyte string).
USTAR format, terminated with two 512-byte NUL blocks."
  (let ((entries (docker-build--walk root))
        (chunks (list (make-string 0 0))))
    (dolist (entry entries)
      (let* ((rel (car entry))
             (abs (cdr entry))
             (bytes (docker-build--read-bytes abs))
             (size (length bytes))
             (mode (docker-build--mode-bits abs))
             (header (docker-fs--make-tar-file-header rel size mode))
             (pad-len (mod (- 512 (mod size 512)) 512))
             (pad (make-string pad-len 0)))
        (push header chunks)
        (push bytes chunks)
        (push pad chunks)))
    ;; Two NUL blocks = end-of-tar.
    (push (make-string 1024 0) chunks)
    (apply #'concat (nreverse chunks))))

;;; ---------------------------------------------------------------------------
;;; Streaming POST + render

(defun docker-build--render-event (buf event)
  "Render one parsed JSON EVENT into BUF (append-only)."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (stream (alist-get 'stream event))
            (errmsg (alist-get 'error event))
            (status (alist-get 'status event))
            (progress (alist-get 'progress event)))
        (goto-char (point-max))
        (cond
         (errmsg
          (insert (propertize errmsg 'font-lock-face
                              'eltainer-status-error))
          (unless (string-suffix-p "\n" errmsg) (insert "\n")))
         (stream
          (insert stream))
         (status
          (insert (format "%s%s\n" status
                          (if progress (concat " " progress) "")))))))))

(defun docker-build--start (cfg tar-bytes &rest build-args)
  "POST TAR-BYTES to `/build' streaming the response into
`*docker:build*'.  BUILD-ARGS is the query alist."
  (let* ((buf (get-buffer-create "*docker:build*"))
         (full (concat (docker--api-prefix cfg) "/build"))
         (ndjson (docker-stream-make-ndjson
                  (lambda (ev) (docker-build--render-event buf ev)))))
    (with-current-buffer buf
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "docker build — streaming response below\n\n"
                            'font-lock-face 'eltainer-section-heading))))
    (docker-http-stream
     cfg "POST" full
     :query build-args
     :headers '(("Content-Type" . "application/x-tar"))
     :body tar-bytes
     :on-chunk (lambda (bytes) (funcall ndjson bytes))
     :on-close (lambda ()
                 (funcall ndjson 'cleanup)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (let ((inhibit-read-only t))
                       (goto-char (point-max))
                       (insert (propertize "\n[build stream closed]\n"
                                           'font-lock-face 'shadow)))))))
    (pop-to-buffer buf)
    buf))

;;; ---------------------------------------------------------------------------
;;; User entry

;;;###autoload
(cl-defun docker-build (dir &key tag dockerfile no-cache target)
  "Build an image from the Dockerfile context at DIR.
Optional keyword args:
  :TAG          — image tag (passed as `t=NAME:TAG' in the query)
  :DOCKERFILE   — relative path within DIR (default `Dockerfile')
  :NO-CACHE     — pass `nocache=true' to the daemon
  :TARGET       — multi-stage build target stage

The build context is tarred up in-process (no `tar' shell-out)
and POSTed to `/build'.  Progress streams into `*docker:build*';
errors render in the error face."
  (interactive
   (list (read-directory-name "Build context dir: " nil nil t)
         :tag (let ((s (read-string "Tag (NAME[:TAG], blank to skip): ")))
                (and (not (string-empty-p s)) s))
         :dockerfile (let ((s (read-string "Dockerfile relative path (blank = Dockerfile): ")))
                       (and (not (string-empty-p s)) s))))
  (unless (file-directory-p dir)
    (user-error "docker-build: %s isn't a directory" dir))
  (let* ((dockerfile (or dockerfile "Dockerfile"))
         (full-dockerfile (expand-file-name dockerfile dir)))
    (unless (file-readable-p full-dockerfile)
      (user-error "docker-build: %s doesn't exist or isn't readable"
                  full-dockerfile)))
  (let* ((cfg (docker--ensure-config))
         (_ (message "docker-build: tarring %s ..." dir))
         (tar (docker-build--make-tar dir))
         (query (delq nil
                       (list
                        (cons "dockerfile" (or dockerfile "Dockerfile"))
                        (and tag       (cons "t" tag))
                        (and no-cache  (cons "nocache" "true"))
                        (and target    (cons "target" target))))))
    (message "docker-build: %d bytes of context, POSTing /build ..."
             (length tar))
    (apply #'docker-build--start cfg tar query)))

(provide 'docker-build)
;;; docker-build.el ends here
