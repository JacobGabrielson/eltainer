;;; eltainer-terminal.el --- Shared terminal backend selector -*- lexical-binding: t -*-
;;
;; Hosts an interactive (PTY-ish) stream in an Emacs buffer using one of
;; three screen-oriented terminal emulators:
;;
;;   eat     pure-Elisp xterm emulator (preferred when present)
;;   vterm   `emacs-libvterm', a compiled module (best fidelity)
;;   term    built-in `term-mode'   (always-available floor)
;;
;; The four backend operations look the same to callers:
;;
;;   eltainer-terminal-open     BUFNAME              → BUFFER
;;   eltainer-terminal-feed     BUFFER BYTES         → renders output
;;   eltainer-terminal-bind     BUFFER NET-PROCESS   → routes keystrokes
;;   eltainer-terminal-resize   BUFFER HEIGHT WIDTH  → SIGWINCH-equivalent
;;
;; `eltainer-terminal-backend' picks one (default `auto' probes
;; eat → vterm → term).  Used by `docker-exec' today; the (future)
;; interactive k8s exec path is the next consumer.

(require 'cl-lib)

(defgroup eltainer-terminal nil
  "Terminal-emulator selection for eltainer's interactive exec paths."
  :group 'eltainer)

(defcustom eltainer-terminal-backend 'auto
  "Which screen-oriented terminal emulator to host TTY streams in.
`auto' probes `eat' → `vterm' → `term' and picks the first that's
available.  The other values force a specific backend."
  :type '(choice (const auto) (const eat) (const vterm) (const term))
  :group 'eltainer-terminal)

(defun eltainer-terminal--resolve ()
  "Return the actual backend symbol to use, after auto-probing."
  (pcase eltainer-terminal-backend
    ('auto (cond ((require 'eat nil t) 'eat)
                 ((require 'vterm nil t) 'vterm)
                 (t 'term)))
    ('eat   (require 'eat) 'eat)
    ('vterm (require 'vterm) 'vterm)
    ('term  'term)
    (other  (error "eltainer-terminal: unknown backend %S" other))))

(defvar-local eltainer-terminal--backend nil
  "Resolved backend symbol for the current terminal buffer.")

;;; ---------------------------------------------------------------------------
;;; term backend (built-in)

(defun eltainer-terminal--open-term (bufname)
  (let ((buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (require 'term)
      (unless (derived-mode-p 'term-mode) (term-mode))
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq eltainer-terminal--backend 'term))
    buf))

(defun eltainer-terminal--feed-term (buffer bytes)
  (let ((proc (get-buffer-process buffer)))
    (when (and proc bytes)
      (term-emulate-terminal proc bytes))))

(defun eltainer-terminal--bind-term (buffer proc)
  (with-current-buffer buffer
    (set-process-buffer proc buffer)
    (set-marker (process-mark proc) (point-max))
    (term-char-mode)))

(defun eltainer-terminal--resize-term (buffer h w)
  (with-current-buffer buffer
    (when (fboundp 'term-set-size)
      (ignore-errors (term-set-size h w)))))

;;; ---------------------------------------------------------------------------
;;; eat backend

(defun eltainer-terminal--open-eat (bufname)
  (require 'eat)
  (let ((buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (derived-mode-p 'eat-mode) (eat-mode))
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq-local eat-terminal (eat-term-make buf (point)))
      (eat-term-set-parameter eat-terminal 'input-function
                              #'eltainer-terminal--eat-send-input)
      (setq eltainer-terminal--backend 'eat))
    buf))

(defun eltainer-terminal--eat-send-input (_term str)
  "input-function handler for eat: forward STR to the bound process."
  (when-let* ((proc (eat-term-parameter eat-terminal 'eat--process)))
    (process-send-string proc str)))

(defun eltainer-terminal--feed-eat (buffer bytes)
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
        (funcall eat--synchronize-scroll-function sync-windows)))))

(defun eltainer-terminal--bind-eat (buffer proc)
  (with-current-buffer buffer
    (eat-term-set-parameter eat-terminal 'eat--process proc)
    (set-process-buffer proc buffer)
    (eat-semi-char-mode)))

(defun eltainer-terminal--resize-eat (buffer h w)
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (eat-term-resize eat-terminal (max w 1) (max h 1))
      (eat-term-redisplay eat-terminal))))

;;; ---------------------------------------------------------------------------
;;; vterm backend

(defun eltainer-terminal--open-vterm (bufname)
  (require 'vterm)
  (let ((buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (derived-mode-p 'vterm-mode) (vterm-mode))
      (setq eltainer-terminal--backend 'vterm))
    buf))

(defun eltainer-terminal--feed-vterm (buffer bytes)
  (with-current-buffer buffer
    (when (fboundp 'vterm--write-input)
      (vterm--write-input bytes))))

(defun eltainer-terminal--bind-vterm (buffer proc)
  (with-current-buffer buffer
    (setq-local vterm--process proc)))

(defun eltainer-terminal--resize-vterm (buffer h w)
  (with-current-buffer buffer
    (when (fboundp 'vterm--set-size)
      (ignore-errors (vterm--set-size h w)))))

;;; ---------------------------------------------------------------------------
;;; Public surface

(defun eltainer-terminal-open (bufname)
  "Open BUFNAME in the resolved terminal backend.  Return the buffer."
  (pcase (eltainer-terminal--resolve)
    ('eat   (eltainer-terminal--open-eat   bufname))
    ('vterm (eltainer-terminal--open-vterm bufname))
    (_      (eltainer-terminal--open-term  bufname))))

(defun eltainer-terminal-feed (buffer bytes)
  "Feed BYTES into BUFFER's terminal, rendering output."
  (when (and (buffer-live-p buffer) bytes (> (length bytes) 0))
    (pcase (buffer-local-value 'eltainer-terminal--backend buffer)
      ('eat   (eltainer-terminal--feed-eat   buffer bytes))
      ('vterm (eltainer-terminal--feed-vterm buffer bytes))
      (_      (eltainer-terminal--feed-term  buffer bytes)))))

(defun eltainer-terminal-bind (buffer process)
  "Route BUFFER's keystrokes to PROCESS, and finalize the input mode."
  (pcase (buffer-local-value 'eltainer-terminal--backend buffer)
    ('eat   (eltainer-terminal--bind-eat   buffer process))
    ('vterm (eltainer-terminal--bind-vterm buffer process))
    (_      (eltainer-terminal--bind-term  buffer process))))

(defun eltainer-terminal-resize (buffer height width)
  "Inform BUFFER's terminal of a new (HEIGHT, WIDTH).  Idempotent."
  (when (buffer-live-p buffer)
    (pcase (buffer-local-value 'eltainer-terminal--backend buffer)
      ('eat   (eltainer-terminal--resize-eat   buffer height width))
      ('vterm (eltainer-terminal--resize-vterm buffer height width))
      (_      (eltainer-terminal--resize-term  buffer height width)))))

(defun eltainer-terminal-window-size (buffer)
  "Return (HEIGHT . WIDTH) for the window showing BUFFER, or sane defaults."
  (let ((win (get-buffer-window buffer t)))
    (if win
        (cons (window-body-height win) (window-body-width win))
      (cons 24 80))))

(defun eltainer-terminal-set-input-fn (buffer send-fn)
  "Route keystrokes typed in BUFFER's terminal through SEND-FN.
SEND-FN takes one string argument and is responsible for getting
those bytes to the remote.  Use this when the underlying process
expects framed I/O (e.g. WebSocket-encoded channel-0 frames for
Kubernetes exec) rather than the raw bytes `eltainer-terminal-bind'
defaults to."
  (with-current-buffer buffer
    (pcase (buffer-local-value 'eltainer-terminal--backend buffer)
      ('eat
       (eat-term-set-parameter
        eat-terminal 'input-function
        (lambda (_term str) (funcall send-fn str))))
      ('term
       (setq-local term-input-sender
                   (lambda (_proc str) (funcall send-fn str))))
      ('vterm
       ;; vterm pipes input through `vterm--write-input' on a process.
       ;; Custom-routing input through vterm is fiddly; fall back to
       ;; eat or term for paths that need a custom send-fn.
       (user-error
        "eltainer-terminal-set-input-fn: vterm input redirection NYI; pin `eltainer-terminal-backend' to `eat or `term")))))

;;; ---------------------------------------------------------------------------
;;; Backward-compatible aliases
;;
;; Old name from when the module lived under docker/ and was docker-only.
;; Kept so external callers don't need to update; new code should use
;; the eltainer-terminal-* names.

(defvaralias 'docker-terminal-backend 'eltainer-terminal-backend)
(defalias 'docker-terminal-open        #'eltainer-terminal-open)
(defalias 'docker-terminal-feed        #'eltainer-terminal-feed)
(defalias 'docker-terminal-bind        #'eltainer-terminal-bind)
(defalias 'docker-terminal-resize      #'eltainer-terminal-resize)
(defalias 'docker-terminal-window-size #'eltainer-terminal-window-size)

(provide 'eltainer-terminal)
;; Old feature name kept so `(require 'docker-terminal)' still works.
(provide 'docker-terminal)
;;; eltainer-terminal.el ends here
