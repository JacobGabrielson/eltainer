;;; eltainer.el --- Unified container porcelain for Emacs -*- lexical-binding: t -*-
;;
;; Adds `docker/' and `k8s/' to the load-path and requires both halves
;; so `M-x docker', `M-x k8s', and `M-x eltainer' are all available
;; after a single `(require 'eltainer)'.
;;
;; `M-x eltainer' opens a magit-section dashboard listing every
;; available view in both backends.  Press the key beside an entry —
;; or `RET' / mouse-1 on the row — to jump in.

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)

(defconst eltainer--source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this `eltainer.el' file.")

(add-to-list 'load-path (expand-file-name "docker" eltainer--source-dir))
(add-to-list 'load-path (expand-file-name "k8s"    eltainer--source-dir))

(require 'eltainer-terminal)
(require 'eltainer-shell-helper)
(require 'docker)
(require 'k8s)

;;; ---------------------------------------------------------------------------
;;; Dashboard

(defvar eltainer-views
  '(("Docker" .
     (("c" "Containers" docker-containers)
      ("I" "Images"     docker-images)
      ("N" "Networks"   docker-networks)
      ("u" "Pull"       docker-pull-image)))
    ("Kubernetes" .
     (("k" "Pods"          k8s-pods)
      ("d" "Deployments"   k8s-deployments)
      ("s" "Services"      k8s-services)
      ("S" "StatefulSets"  k8s-statefulsets)
      ("D" "DaemonSets"    k8s-daemonsets)
      ("j" "Jobs"          k8s-jobs)
      ("J" "CronJobs"      k8s-cronjobs)
      ("i" "Ingresses"     k8s-ingresses)
      ("m" "ConfigMaps"    k8s-configmaps)
      ("x" "Secrets"       k8s-secrets))))
  "Dashboard entries.  Alist of (BACKEND-LABEL . ((KEY LABEL COMMAND) …)).")

(defvar eltainer-mode-map (make-sparse-keymap)
  "Keymap for `eltainer-mode'.
Reset on every file load so `M-x eltainer-reload' picks up changes
to `eltainer-views' (and to the explicit bindings just below)
instead of carrying stale entries forward.  `p' / `n' fall through
to the parent `magit-section-mode-map' for section navigation.")

;;; ---------------------------------------------------------------------------
;;; Kubeconfig switching (magit-branch-style `b')

(defcustom eltainer-kubeconfig-extra-paths nil
  "Additional kubeconfig paths to offer alongside the auto-discovered ones.
Each entry is an absolute file path."
  :type '(repeat file)
  :group 'eltainer)

(defcustom eltainer-kubeconfig-search-dirs
  '("~/.kube" "~/.kube/configs")
  "Directories scanned for kubeconfig files.
Files matching `config' or `config-*' in any of these are offered as
switch targets in the dashboard."
  :type '(repeat directory)
  :group 'eltainer)

(defun eltainer--discover-kubeconfig-files ()
  "Return de-duplicated kubeconfig file paths from all known sources.
Sources, in order: `$KUBECONFIG' (colon-separated), files in
`eltainer-kubeconfig-search-dirs', and `eltainer-kubeconfig-extra-paths'."
  (let* ((env (getenv "KUBECONFIG"))
         (env-paths (and env (split-string env ":" t)))
         (dir-paths
          (cl-loop for dir in eltainer-kubeconfig-search-dirs
                   for expanded = (expand-file-name dir)
                   when (file-directory-p expanded)
                   append (directory-files expanded t
                                           "\\`config\\(?:-.*\\)?\\'" t)))
         (all (append env-paths dir-paths eltainer-kubeconfig-extra-paths))
         seen out)
    (dolist (p all)
      (let ((full (and p (expand-file-name p))))
        (when (and full
                   (file-readable-p full)
                   (not (file-directory-p full))
                   (not (member full seen)))
          (push full seen)
          (push full out))))
    (nreverse out)))

(defun eltainer--discover-kubeconfigs ()
  "Return all (FILE . CONTEXT-NAME) candidates across known files.
Each file may contribute multiple entries (one per context).  The file's
`current-context' is listed first, then any other contexts."
  (cl-loop for file in (eltainer--discover-kubeconfig-files)
           append (condition-case nil
                      (let* ((cfg (k8s-config-load file))
                             (default (k8s-config-current-context cfg))
                             (names (mapcar #'k8s-context-name
                                            (k8s-config-contexts cfg)))
                             (ordered (if (and default (member default names))
                                          (cons default (delete default
                                                                (copy-sequence names)))
                                        names)))
                        (mapcar (lambda (ctx) (cons file ctx)) ordered))
                    (error nil))))

(defun eltainer--current-kubeconfig ()
  "Return the kubeconfig path eltainer is pointed at, or nil."
  (or (bound-and-true-p k8s-kubeconfig-path)
      (let ((env (getenv "KUBECONFIG")))
        (and env (car (split-string env ":" t))))
      (let ((default (expand-file-name "~/.kube/config")))
        (and (file-readable-p default) default))))

(defun eltainer--current-context (&optional path)
  "Return the active context name for PATH (or the current kubeconfig).
Honors `k8s-context-override' over the file's `current-context'."
  (or (bound-and-true-p k8s-context-override)
      (let ((p (or path (eltainer--current-kubeconfig))))
        (when (and p (file-readable-p p))
          (condition-case nil
              (k8s-config-current-context (k8s-config-load p))
            (error nil))))))

(defun eltainer--kill-k8s-buffers ()
  "Kill every live `*k8s:…*' buffer so a kubeconfig switch is clean."
  (let ((kill-buffer-query-functions nil))
    (dolist (buf (buffer-list))
      (when (string-prefix-p "*k8s:" (buffer-name buf))
        (ignore-errors (kill-buffer buf))))))

(defun eltainer--apply-context-switch (file ctx)
  "Commit a switch to (FILE, CTX): set the vars, kill k8s buffers,
refresh the dashboard, log to the echo area."
  (setq k8s-kubeconfig-path file
        k8s-context-override ctx)
  (eltainer--kill-k8s-buffers)
  (when (get-buffer "*eltainer*")
    (with-current-buffer "*eltainer*" (eltainer-refresh)))
  (message "eltainer: switched to %s (%s)"
           ctx (abbreviate-file-name file)))

;;; --- Context picker buffer ------------------------------------------------
;;
;; `b' pops `*eltainer:contexts*' showing every discovered context up
;; front (no tab-to-expand) — RET on a row commits the switch.

(defvar-keymap eltainer-context-picker-mode-map
  :parent special-mode-map
  "RET" #'eltainer-context-pick
  "n"   #'next-line
  "p"   #'previous-line
  "j"   #'next-line
  "k"   #'previous-line
  "q"   #'quit-window)

(define-derived-mode eltainer-context-picker-mode special-mode "Eltainer:Context"
  "Picker buffer listing every kubeconfig context for `b' switching."
  :group 'eltainer
  (setq-local truncate-lines t))

(defun eltainer-context-pick ()
  "Select the context on the current line and apply the switch."
  (interactive)
  (let ((target (get-text-property (line-beginning-position) 'eltainer-context)))
    (unless target (user-error "Not on a context line"))
    (quit-window t)
    (eltainer--apply-context-switch (car target) (cdr target))))

(defun eltainer-switch-kubeconfig ()
  "Open a picker listing every discovered context.
Like magit's branch switch (`b'), but for kubeconfig contexts.  The
list appears immediately; navigate with n/p (or j/k), RET to select,
q to cancel."
  (interactive)
  (let* ((current-path (eltainer--current-kubeconfig))
         (current-ctx (eltainer--current-context current-path))
         (candidates (eltainer--discover-kubeconfigs)))
    (unless candidates
      (user-error "No kubeconfigs found (set k8s-kubeconfig-path or $KUBECONFIG)"))
    (let ((buf (get-buffer-create "*eltainer:contexts*"))
          (current-line 1))
      (with-current-buffer buf
        (eltainer-context-picker-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "Switch context" 'font-lock-face
                              'eltainer-section-heading))
          (insert (propertize "    RET select  n/p move  q cancel\n\n"
                              'font-lock-face 'eltainer-dim))
          (cl-loop for (file . ctx) in candidates
                   for line from 3
                   for is-current = (and (equal file current-path)
                                         (equal ctx current-ctx))
                   do
                   (when is-current (setq current-line line))
                   (let ((start (point)))
                     (insert "  "
                             (propertize ctx 'font-lock-face
                                         'eltainer-resource-name)
                             "  —  "
                             (propertize (abbreviate-file-name file)
                                         'font-lock-face
                                         'eltainer-resource-secondary)
                             (if is-current
                                 (propertize "  *current*" 'font-lock-face
                                             'eltainer-dim)
                               "")
                             "\n")
                     (add-text-properties
                      start (point)
                      `(eltainer-context (,file . ,ctx))))))
        (goto-char (point-min))
        (forward-line (1- current-line)))
      (pop-to-buffer buf '((display-buffer-below-selected)
                           (window-height . fit-window-to-buffer))))))

(define-derived-mode eltainer-mode magit-section-mode "Eltainer"
  "Dashboard for the unified docker + k8s frontend."
  :group 'eltainer
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (eltainer-refresh))))

(defun eltainer--rebuild-keymap ()
  "(Re)populate `eltainer-mode-map' from scratch.
Clears any prior bindings (in case `eltainer-views' just lost a key
on reload), restores the parent, sets the explicit dashboard keys,
then wires each view entry's KEY to its COMMAND."
  (setcdr eltainer-mode-map nil)        ; clear existing bindings
  (set-keymap-parent eltainer-mode-map magit-section-mode-map)
  (dolist (pair '(("q"   . quit-window)
                  ("g"   . eltainer-refresh)
                  ("?"   . describe-mode)
                  ("b"   . eltainer-switch-kubeconfig)
                  ("RET" . eltainer-dwim-ret)))
    (keymap-set eltainer-mode-map (car pair) (cdr pair)))
  (dolist (group eltainer-views)
    (dolist (entry (cdr group))
      (let ((key (nth 0 entry))
            (cmd (nth 2 entry)))
        (keymap-set eltainer-mode-map key cmd)))))

;; Build the keymap on every file load so the data above and the
;; explicit bindings inside `eltainer--rebuild-keymap' both take
;; effect under `M-x eltainer-reload'.
(eltainer--rebuild-keymap)

(defun eltainer--insert-entry (entry)
  "Insert one dashboard row for ENTRY (KEY LABEL COMMAND)."
  (let* ((key   (nth 0 entry))
         (label (nth 1 entry))
         (cmd   (nth 2 entry))
         (start (point))
         (avail (fboundp cmd)))
    (magit-insert-section (eltainer-entry cmd t)
      (insert "  "
              (propertize (format "%-3s" key)
                          'font-lock-face (if avail
                                              'eltainer-resource-name
                                            'eltainer-dim))
              (propertize label
                          'font-lock-face (if avail 'default 'eltainer-dim)))
      (insert "\n")
      (add-text-properties start (point) `(eltainer-cmd ,cmd))
      (unless avail
        (add-text-properties start (point)
                             '(help-echo "command unavailable (module not loaded)"))))))

(defun eltainer--insert-active-kubeconfig ()
  "Render the active k8s context + kubeconfig and a `b' switch hint."
  (let* ((path (eltainer--current-kubeconfig))
         (ctx (eltainer--current-context path)))
    (insert (propertize "  Context:  " 'font-lock-face 'eltainer-dim))
    (if ctx
        (insert (propertize ctx 'font-lock-face 'eltainer-resource-name))
      (insert (propertize "(unset)" 'font-lock-face 'eltainer-dim)))
    (when path
      (insert (propertize (format "  —  %s" (abbreviate-file-name path))
                          'font-lock-face 'eltainer-resource-secondary)))
    (insert (propertize "    [b] switch\n"
                        'font-lock-face 'eltainer-dim))))

(defun eltainer-refresh ()
  "(Re)render the dashboard buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (eltainer-root)
      (insert (propertize "eltainer" 'font-lock-face 'eltainer-section-heading)
              " — unified container porcelain\n\n")
      (dolist (group eltainer-views)
        (magit-insert-section (eltainer-group (car group))
          (magit-insert-heading
            (propertize (car group) 'font-lock-face 'eltainer-section-heading))
          (when (equal (car group) "Kubernetes")
            (eltainer--insert-active-kubeconfig))
          (dolist (entry (cdr group))
            (eltainer--insert-entry entry))
          (insert "\n")))
      (insert "\n"))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

(defun eltainer-dwim-ret ()
  "On a dashboard row, run its command.  On a section heading, toggle it."
  (interactive)
  (let ((cmd (get-text-property (point) 'eltainer-cmd)))
    (cond
     ((and cmd (fboundp cmd)) (call-interactively cmd))
     ((magit-current-section) (call-interactively #'magit-section-toggle))
     (t (user-error "Nothing actionable at point")))))

;;;###autoload
(defun eltainer ()
  "Open the eltainer dashboard listing every available view."
  (interactive)
  (let ((buf (get-buffer-create "*eltainer*")))
    (with-current-buffer buf
      (eltainer-mode)
      (eltainer-refresh))
    (pop-to-buffer buf)))

(provide 'eltainer)
;;; eltainer.el ends here
