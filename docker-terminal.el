;;; docker-terminal.el --- Screen-oriented terminal backend selector -*- lexical-binding: t -*-
;;
;; Three real choices for hosting a PTY-ish stream in an Emacs buffer
;; (see docs/direct-daemon-rewrite.md for the survey):
;;
;;   eat     pure-Elisp xterm emulator (preferred when present)
;;   vterm   `emacs-libvterm', a compiled module (best fidelity)
;;   term    built-in `term-mode'   (floor; always available)
;;
;; `docker-terminal-backend' picks one; the default `auto' probes
;; eat -> vterm -> term and uses the first that's available.  Each
;; backend has a tiny adapter (open-buffer, attach-process,
;; signal-resize) so callers — exec, attach, the SSH-CLI fallback —
;; don't care which one is in use.

(require 'cl-lib)

(defgroup docker-terminal nil
  "Terminal emulator selection for eldocker."
  :group 'docker)

(defcustom docker-terminal-backend 'auto
  "Which screen-oriented terminal emulator to host TTY streams in.
`auto' probes `eat' -> `vterm' -> `term' and picks the first available.
The other values force a specific backend (and error if missing)."
  :type '(choice (const auto) (const eat) (const vterm) (const term))
  :group 'docker-terminal)

(defun docker-terminal--resolve ()
  "Return the actual backend symbol to use, after auto-probing."
  (pcase docker-terminal-backend
    ('auto (cond ((require 'eat nil t) 'eat)
                 ((require 'vterm nil t) 'vterm)
                 (t 'term)))
    ('eat (or (require 'eat nil t)
              (error "docker-terminal: backend=eat but `eat' package not found")))
    ('vterm (or (require 'vterm nil t)
                (error "docker-terminal: backend=vterm but `vterm' module not found")))
    ('term 'term)
    (other (error "docker-terminal: unknown backend %S" other))))

;;; ---------------------------------------------------------------------------
;;; Built-in `term' adapter

(defun docker-terminal--open-term (buffer-name)
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (require 'term)
      (unless (derived-mode-p 'term-mode)
        (term-mode))
      (let ((inhibit-read-only t)) (erase-buffer)))
    buf))

(defun docker-terminal--attach-term (buffer proc)
  (with-current-buffer buffer
    (set-process-buffer proc buffer)
    (set-marker (process-mark proc) (point-max))
    (set-process-filter proc #'term-emulate-terminal)
    (set-process-sentinel
     proc (lambda (p _ev)
            (unless (process-live-p p)
              (with-current-buffer buffer
                (let ((inhibit-read-only t))
                  (goto-char (point-max))
                  (insert "\n[stream closed]\n"))))))
    ;; Char-at-a-time input mode requires the process to already be
    ;; attached, so this runs *after* set-process-buffer above.
    (term-char-mode)))

;;; ---------------------------------------------------------------------------
;;; `eat' adapter

(defun docker-terminal--open-eat (buffer-name)
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (unless (bound-and-true-p eat-mode)
        (require 'eat)
        (eat-mode)))
    buf))

(defun docker-terminal--attach-eat (buffer proc)
  (with-current-buffer buffer
    (require 'eat)
    ;; `eat' exposes `eat--terminal' and `eat-process-output' for raw
    ;; byte feeding; we wire the network process filter to push bytes
    ;; through eat's emulator and the process input goes back over the
    ;; socket.
    (when (fboundp 'eat--init) (eat--init))
    (set-process-buffer proc buffer)
    (set-process-filter
     proc (lambda (_p data)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (fboundp 'eat--process-output-queue)
                  (eat--process-output-queue proc data))))))
    (setq-local eat--process proc)
    (set-process-sentinel
     proc (lambda (p _ev)
            (unless (process-live-p p)
              (with-current-buffer buffer
                (let ((inhibit-read-only t))
                  (goto-char (point-max))
                  (insert "\n[stream closed]\n"))))))))

;;; ---------------------------------------------------------------------------
;;; `vterm' adapter

(defun docker-terminal--open-vterm (buffer-name)
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'vterm-mode)
        (require 'vterm)
        (vterm-mode)))
    buf))

(defun docker-terminal--attach-vterm (buffer proc)
  (with-current-buffer buffer
    (require 'vterm)
    (setq-local vterm--process proc)
    (set-process-filter
     proc (lambda (_p data)
            (when (and (buffer-live-p buffer)
                       (fboundp 'vterm--filter))
              (vterm--filter proc data))))
    (set-process-sentinel
     proc (lambda (p _ev)
            (unless (process-live-p p)
              (with-current-buffer buffer
                (let ((inhibit-read-only t))
                  (goto-char (point-max))
                  (insert "\n[stream closed]\n"))))))))

;;; ---------------------------------------------------------------------------
;;; Public surface

(defun docker-terminal-open (buffer-name)
  "Open BUFFER-NAME in the resolved terminal backend.  Return the buffer."
  (pcase (docker-terminal--resolve)
    ('eat   (docker-terminal--open-eat   buffer-name))
    ('vterm (docker-terminal--open-vterm buffer-name))
    (_      (docker-terminal--open-term  buffer-name))))

(defun docker-terminal-attach (buffer process)
  "Bind PROCESS as the I/O for the terminal in BUFFER."
  (pcase (docker-terminal--resolve)
    ('eat   (docker-terminal--attach-eat   buffer process))
    ('vterm (docker-terminal--attach-vterm buffer process))
    (_      (docker-terminal--attach-term  buffer process))))

(defun docker-terminal-window-size (buffer)
  "Return (HEIGHT . WIDTH) for the window currently showing BUFFER, or sensible defaults."
  (let ((win (get-buffer-window buffer t)))
    (if win
        (cons (window-body-height win) (window-body-width win))
      (cons 24 80))))

(provide 'docker-terminal)
;;; docker-terminal.el ends here
