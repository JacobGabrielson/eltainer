;;; eltainer-terminal.el --- Shared terminal backend (eat) -*- lexical-binding: t -*-
;;
;; Hosts an interactive (PTY-ish) stream in an Emacs buffer using
;; `eat' (pure-Elisp xterm emulator).  eat is a hard dependency:
;; this file refuses to load without it, and `docker-exec' /
;; `k8s-exec-interactive' both route their output here.
;;
;; The four backend operations look the same to callers:
;;
;;   eltainer-terminal-open     BUFNAME              → BUFFER
;;   eltainer-terminal-feed     BUFFER BYTES         → renders output
;;   eltainer-terminal-bind     BUFFER NET-PROCESS   → routes keystrokes
;;   eltainer-terminal-resize   BUFFER HEIGHT WIDTH  → SIGWINCH-equivalent
;;
;; Why eat and not built-in `term'?  `term-emulate-terminal' assumes
;; an Emacs subprocess whose stdout we control; for hijacked HTTP
;; (docker exec) and WebSocket-framed (k8s exec) byte streams the
;; bytes are routed via a custom process filter, so the term
;; backend silently no-ops.  eat exposes
;; `eat-term-process-output' which accepts bytes directly and is
;; the natural fit.  Cross-platform pure-Elisp; install with
;; `M-x package-install RET eat RET'.

(require 'cl-lib)
(require 'package)
(unless (or (require 'eat nil t)
            ;; eat may be installed in ELPA but not yet activated in this
            ;; session (Emacs only auto-activates packages at startup).
            ;; Activate it on the fly so reloading after `package-install'
            ;; doesn't need a full Emacs restart.
            (and (package-installed-p 'eat)
                 (progn (package-activate 'eat) (require 'eat nil t))))
  (error
   "eltainer-terminal: the `eat' package is required for TTY exec.\n\
Install with `M-x package-install RET eat RET' (MELPA), or see the\n\
Requirements section in eltainer's README"))

(defgroup eltainer-terminal nil
  "Terminal-emulator host for eltainer's interactive exec paths."
  :group 'eltainer)

(defconst eltainer-terminal-backend 'eat
  "Terminal backend used by eltainer.  Always `eat'.
Provided as a constant so callers / customize stay forward-compatible
if the project ever grows an alternative again.  See the file
commentary for why eat is the sole supported backend.")

;;; ---------------------------------------------------------------------------
;;; eat-backed implementation

(defun eltainer-terminal-open (bufname)
  "Open BUFNAME as an eat terminal buffer and return it."
  (let ((buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (derived-mode-p 'eat-mode) (eat-mode))
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq-local eat-terminal (eat-term-make buf (point)))
      (eat-term-set-parameter eat-terminal 'input-function
                              #'eltainer-terminal--eat-send-input))
    buf))

(defun eltainer-terminal--eat-send-input (_term str)
  "Default input-function for eat: forward STR to the bound process."
  (when-let* ((proc (eat-term-parameter eat-terminal 'eat--process)))
    (process-send-string proc str)))

(defun eltainer-terminal-feed (buffer bytes)
  "Render BYTES into BUFFER's eat terminal."
  (when (and (buffer-live-p buffer) bytes (> (length bytes) 0))
    (with-current-buffer buffer
      ;; Mirror what `eat--process-output-queue' does for its own child
      ;; process: process bytes, redisplay, then run the scroll-sync
      ;; function so `point' and `window-start' track the terminal
      ;; cursor.  Without this `point' lags the cursor as output arrives.
      (let ((sync-windows (eat--synchronize-scroll-windows)))
        (save-restriction
          (widen)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (buffer-undo-list t))
            (eat-term-process-output eat-terminal bytes)
            (eat-term-redisplay eat-terminal)))
        (when (functionp eat--synchronize-scroll-function)
          (funcall eat--synchronize-scroll-function sync-windows))))))

(defun eltainer-terminal-bind (buffer process)
  "Route BUFFER's keystrokes to PROCESS via eat's default input path."
  (with-current-buffer buffer
    (eat-term-set-parameter eat-terminal 'eat--process process)
    (set-process-buffer process buffer)
    (eat-semi-char-mode)))

(defun eltainer-terminal-resize (buffer height width)
  "Inform BUFFER's eat terminal of a new (HEIGHT, WIDTH).  Idempotent."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (eat-term-resize eat-terminal (max width 1) (max height 1))
        (eat-term-redisplay eat-terminal)))))

(defun eltainer-terminal-window-size (buffer)
  "Return (HEIGHT . WIDTH) for the window showing BUFFER, or sane defaults."
  (let ((win (get-buffer-window buffer t)))
    (if win
        (cons (window-body-height win) (window-body-width win))
      (cons 24 80))))

(defun eltainer-terminal-set-input-fn (buffer send-fn)
  "Route keystrokes typed in BUFFER through SEND-FN instead of a process.
SEND-FN takes one string argument and is responsible for delivering
the bytes to the remote — used by callers that need framed I/O
(e.g. WebSocket channel-0 frames for k8s exec) rather than the raw
bytes `eltainer-terminal-bind' defaults to.

Also switches the buffer into `eat-semi-char-mode' so keystrokes are
actually captured and forwarded — without this the buffer stays in
eat's read-only navigation mode and the user can't type."
  (with-current-buffer buffer
    (eat-term-set-parameter
     eat-terminal 'input-function
     (lambda (_term str) (funcall send-fn str)))
    (eat-semi-char-mode)))

(provide 'eltainer-terminal)
;;; eltainer-terminal.el ends here
