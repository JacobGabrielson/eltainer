;;; keymap-audit.el --- Cross-mode keybinding consistency checker -*- lexical-binding: t -*-
;;
;; `M-x keymap-audit' / `make audit-keys' loads every eltainer
;; module, walks the *-mode-maps it finds, and reports:
;;
;; (a) Construction patterns in use (how each map was built).
;; (b) Single-key bindings per map (the user-surface keys).
;; (c) **Cross-mode inconsistencies** — same KEY bound to different
;;     COMMANDS in different modes.  Most are intentional (e.g. `d'
;;     means "delete" in resource views vs. "Deployments" in the
;;     dashboard); some may be drift.  The report names every group.
;;
;; The tool is a diagnostic, not a linter: it lists, the developer
;; decides which "inconsistencies" are deliberate.  See
;; `docs/keymap-audit-report.md' for the curated read of its output.

(require 'cl-lib)
(require 'help-mode)

;;; ---------------------------------------------------------------------------
;;; Mode-map enumeration

(defun keymap-audit--maps ()
  "Return a list of `(MODE-MAP-SYMBOL . KEYMAP)' for every
*-mode-map and *-map in obarray that's actually a keymap and
whose name begins with one of our prefixes."
  (let (out)
    (mapatoms
     (lambda (sym)
       (when (and (boundp sym)
                  (keymapp (symbol-value sym))
                  (let ((n (symbol-name sym)))
                    (or (string-prefix-p "k8s-" n)
                        (string-prefix-p "docker-" n)
                        (string-prefix-p "eltainer-" n)))
                  (or (string-suffix-p "-mode-map" (symbol-name sym))
                      (string-suffix-p "-map" (symbol-name sym))))
         (push (cons sym (symbol-value sym)) out))))
    (sort out (lambda (a b)
                (string< (symbol-name (car a)) (symbol-name (car b)))))))

(defun keymap-audit--single-key-bindings (km)
  "Return alist `((KEY-DESC . EFFECTIVE-COMMAND) ...)' for every
single-key (non-prefix) binding visible in KM, walking through
parent keymaps but resolving each KEY to the *effective*
binding (local-overrides-parent), so a child rebinding doesn't
show up alongside the shadowed parent entry."
  (let ((seen (make-hash-table :test 'equal))
        out)
    (cl-labels
        ((walk (kmap)
           (map-keymap-internal
            (lambda (event _def)
              (let ((key (key-description (vector event))))
                (unless (gethash key seen)
                  (puthash key t seen)
                  (let ((eff (lookup-key km (vector event))))
                    (when (and eff (symbolp eff)
                               (not (eq eff 'undefined)))
                      (push (cons key eff) out))))))
            kmap)
           (when (keymap-parent kmap)
             (walk (keymap-parent kmap)))))
      (walk km))
    (sort out (lambda (a b) (string< (car a) (car b))))))

;;; ---------------------------------------------------------------------------
;;; Cross-mode inconsistency detector

(defun keymap-audit--key-index (maps)
  "Return hash KEY -> list of (MAP . COMMAND) for every single-key
binding across MAPS."
  (let ((idx (make-hash-table :test 'equal)))
    (dolist (entry maps)
      (let* ((map-sym (car entry))
             (km (cdr entry)))
        (dolist (b (keymap-audit--single-key-bindings km))
          (push (cons map-sym (cdr b))
                (gethash (car b) idx nil)))))
    idx))

(defun keymap-audit--inconsistencies (idx)
  "Return alist `(KEY . ((MAP . CMD) ...))' for every KEY bound to
two-or-more *different* commands across the indexed maps."
  (let (out)
    (maphash
     (lambda (key entries)
       (let ((cmds (cl-delete-duplicates
                    (mapcar #'cdr entries) :test #'eq)))
         (when (> (length cmds) 1)
           (push (cons key (nreverse entries)) out))))
     idx)
    (sort out (lambda (a b) (string< (car a) (car b))))))

;;; ---------------------------------------------------------------------------
;;; Construction-pattern survey

(defconst keymap-audit--source-dirs
  '("." "docker" "k8s")
  "Source dirs relative to repo root.")

(defun keymap-audit--source-files (root)
  (cl-loop for d in keymap-audit--source-dirs
           append (directory-files (expand-file-name d root) t "\\.el\\'")))

(defun keymap-audit--scan-source (file)
  "Return alist of patterns used in FILE.
Each entry is `(PATTERN-NAME . COUNT)' for grep-able patterns."
  (let ((tbl '(("defvar-keymap"        . "^(defvar-keymap ")
               ("defvar+let-keymap"    . "(defvar [a-z][a-z-]*-\\(mode-\\)?map.*\n.*let ")
               ("define-key call"      . "(define-key ")
               ("keymap-set call"      . "(keymap-set ")
               ("set-keymap-parent"    . "(set-keymap-parent "))))
    (with-temp-buffer
      (insert-file-contents file)
      (mapcar (lambda (kv)
                (let ((count 0))
                  (goto-char (point-min))
                  (while (re-search-forward (cdr kv) nil t)
                    (cl-incf count))
                  (cons (car kv) count)))
              tbl))))

;;; ---------------------------------------------------------------------------
;;; Report

(defun keymap-audit--render-construction-survey (root buf)
  (insert (propertize "## Construction patterns by file\n\n"
                      'font-lock-face 'shadow))
  (insert "(per-file counts of the binding idioms in use)\n\n")
  (insert (format "  %-40s  %s\n" "FILE" "defvar-keymap / def+let / define-key / keymap-set / set-keymap-parent"))
  (insert (make-string 110 ?-) "\n")
  (dolist (f (keymap-audit--source-files root))
    (let* ((rel (file-relative-name f root))
           (counts (keymap-audit--scan-source f))
           (non-zero (cl-remove-if #'zerop counts :key #'cdr)))
      (when non-zero
        (insert (format "  %-40s  %s\n"
                        rel
                        (mapconcat (lambda (kv)
                                     (format "%s=%d" (car kv) (cdr kv)))
                                   non-zero "  "))))))
  (insert "\n"))

(defun keymap-audit--render-map-listing (maps buf)
  (insert (propertize "## Mode-map listings (single-key bindings only)\n\n"
                      'font-lock-face 'shadow))
  (dolist (entry maps)
    (let* ((map-sym (car entry))
           (bindings (keymap-audit--single-key-bindings (cdr entry))))
      (when bindings
        (insert (format "### %s (%d single-key bindings)\n\n"
                        map-sym (length bindings)))
        (dolist (b bindings)
          (insert (format "  %-12s %s\n" (car b) (cdr b))))
        (insert "\n")))))

(defun keymap-audit--render-inconsistencies (idx buf)
  (insert (propertize "## Cross-mode inconsistencies\n\n"
                      'font-lock-face 'shadow))
  (insert "(same KEY bound to different commands in different modes)\n\n")
  (let ((inc (keymap-audit--inconsistencies idx)))
    (cond
     ((null inc)
      (insert "  (none — every key has at most one meaning across the surveyed maps)\n\n"))
     (t
      (insert (format "  Total: %d keys with cross-mode drift\n\n"
                      (length inc)))
      (dolist (entry inc)
        (insert (format "### Key `%s'\n" (car entry)))
        (dolist (binding (cdr entry))
          (insert (format "  %-40s -> %s\n"
                          (car binding) (cdr binding))))
        (insert "\n"))))))

;;;###autoload
(defun keymap-audit (&optional root)
  "Run the keymap-construction + cross-mode-drift audit.
ROOT defaults to this file's repo root."
  (interactive)
  (let* ((root (or root
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name))))))
         (buf (get-buffer-create "*keymap-audit*"))
         (maps (keymap-audit--maps))
         (idx (keymap-audit--key-index maps)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "# Keymap audit (root: %s)\n\n" root))
        (insert (format "Surveyed %d *-mode-map / *-map symbols.\n\n"
                        (length maps)))
        (keymap-audit--render-construction-survey root buf)
        (keymap-audit--render-map-listing maps buf)
        (keymap-audit--render-inconsistencies idx buf)
        (markdown-mode))
      (goto-char (point-min)))
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun keymap-audit-print (&optional root)
  "Like `keymap-audit', but for batch mode: prints to stdout."
  (let* ((root (or root
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name))))))
         (maps (keymap-audit--maps))
         (idx (keymap-audit--key-index maps)))
    (with-temp-buffer
      (keymap-audit--render-construction-survey root (current-buffer))
      (keymap-audit--render-map-listing maps (current-buffer))
      (keymap-audit--render-inconsistencies idx (current-buffer))
      (princ (buffer-string)))))

(provide 'keymap-audit)
;;; keymap-audit.el ends here
