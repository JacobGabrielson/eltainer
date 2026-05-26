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

(defconst eltainer-views
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
      ("x" "Secrets"       k8s-secrets)
      ("o" "Nodes"         k8s-nodes)
      ("A" "Sandboxes"     k8s-sandboxes)
      ("H" "Helm releases" k8s-helm))))
  "Dashboard entries.  Alist of (BACKEND-LABEL . ((KEY LABEL COMMAND) …)).
`defconst' not `defvar' so editing this list and running
`eltainer-reload' actually picks up the change — `defvar' is a
no-op on an already-bound symbol, which silently makes new
launchers invisible until Emacs is restarted.")

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

(defvar eltainer--discover-files-cache nil
  "Memoized result of `eltainer--discover-kubeconfig-files'.
Plist (:key KEY :files LIST).  KEY captures the scan inputs that
can change file membership — KUBECONFIG env, the extra-paths list,
and an alist of (DIR . MTIME) for every readable search dir — so
adding or removing a kubeconfig invalidates the cache automatically.")

(defun eltainer--discover-scan-key ()
  "Return the cache key for `eltainer--discover-kubeconfig-files'."
  (list (getenv "KUBECONFIG")
        eltainer-kubeconfig-extra-paths
        (cl-loop for dir in eltainer-kubeconfig-search-dirs
                 for expanded = (expand-file-name dir)
                 when (file-directory-p expanded)
                 collect (cons expanded
                               (file-attribute-modification-time
                                (file-attributes expanded))))))

(defun eltainer--discover-kubeconfig-files ()
  "Return de-duplicated kubeconfig file paths from all known sources.
Sources, in order: `$KUBECONFIG' (colon-separated), files in
`eltainer-kubeconfig-search-dirs', and `eltainer-kubeconfig-extra-paths'.

Memoized: dashboard refreshes don't re-glob the scan dirs unless
something in `eltainer--discover-scan-key' actually changed
\(env, extra-paths, or a search dir's mtime — which moves whenever
a file in it is added or removed)."
  (let ((key (eltainer--discover-scan-key)))
    (if (equal key (plist-get eltainer--discover-files-cache :key))
        (plist-get eltainer--discover-files-cache :files)
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
        (let ((result (nreverse out)))
          (setq eltainer--discover-files-cache
                (list :key key :files result))
          result)))))

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

;;; ---------------------------------------------------------------------------
;;; Stop-all: a panic button for runaway watching
;;
;; Eltainer's per-buffer kill-hooks already cancel each view's timers
;; and tear down its streams.  This command leans on that — it kills
;; the buffers en masse — and adds a final pass for the few things
;; that live outside any buffer: the global Docker /events stream and
;; any orphan eltainer-owned timer the kill-hooks didn't catch.

(defconst eltainer-stop--buffer-rx
  "\\`\\*\\(docker\\|k8s\\|eltainer\\):"
  "Buffer-name regexp matching eltainer-owned buffers.")

(defconst eltainer-stop--exec-rx
  "\\`\\*\\(docker\\|k8s\\):exec:"
  "Buffer-name regexp for live exec TTY buffers — spared by default.
Killing them drops a live shell.")

(defconst eltainer-stop--timer-functions
  '(docker--metrics-tick
    k8s--metrics-tick
    k8s--nodes-tick
    k8s-watch--do-reconnect)
  "Timer-callback symbols swept by `eltainer-stop-all'.
Anonymous-lambda timers stay out of this list — they are either
buffer-local (cancelled by the buffer's kill-hook) or reachable
from `docker-events--subscribers' (cancelled by `docker-events-stop').")

(defun eltainer-stop--buffers (include-exec)
  "Return live eltainer buffers; with INCLUDE-EXEC nil, skip exec TTYs."
  (seq-filter
   (lambda (b)
     (let ((n (buffer-name b)))
       (and n
            (string-match-p eltainer-stop--buffer-rx n)
            (or include-exec
                (not (string-match-p eltainer-stop--exec-rx n))))))
   (buffer-list)))

(defun eltainer-stop--sweep-timers ()
  "Cancel any timer whose function is in `eltainer-stop--timer-functions'.
Returns the count cancelled."
  (let ((n 0))
    (dolist (timer (append timer-list timer-idle-list))
      (when (memq (timer--function timer) eltainer-stop--timer-functions)
        (cancel-timer timer)
        (cl-incf n)))
    n))

(declare-function docker-events-stop      "docker-events")
(declare-function docker-events--running-p "docker-events")

(defun eltainer--quiet-buffer (buf)
  "Run BUF's `kill-buffer-hook' functions without killing BUF.
Cancels buffer-local timers and closes streams (everything the
hooks were registered for) while leaving the buffer alive.  Used
by reload to clear old-code timers before redefining them, so the
user keeps their view buffers across an `eltainer-reload'."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (run-hooks 'kill-buffer-hook))))

;;;###autoload
(defun eltainer-stop-all (&optional include-exec keep-buffers no-confirm)
  "Shut down every eltainer watcher.
By default, kills the `*docker:*' / `*k8s:*' / `*eltainer:*'
buffers — their kill-hooks already cancel buffer-local timers and
close streams — then stops the global Docker /events stream and
sweeps for any remaining eltainer-owned timer.

INCLUDE-EXEC (the interactive prefix arg) opts the
`*docker:exec:*' / `*k8s:exec:*' TTY buffers in too; by default
they are spared, since killing them drops a live shell.

KEEP-BUFFERS (non-interactive) runs each buffer's kill-hooks
*without* killing the buffer.  Use this when you want to quiet
the activity but preserve the view content — `eltainer-reload'
does this so a reload doesn't take the user's open views down
with it.

NO-CONFIRM skips the y-or-n prompt; safe for programmatic
callers."
  (interactive "P")
  (let* ((bufs (eltainer-stop--buffers include-exec))
         (events-live (and (fboundp 'docker-events--running-p)
                           (docker-events--running-p)))
         (verb (if keep-buffers "Quiet" "Stop"))
         (verb-past (if keep-buffers "quieted" "stopped")))
    (cond
     ((not (or bufs events-live))
      (message "eltainer: nothing to %s"
               (if keep-buffers "quiet" "stop")))
     ((not (or no-confirm
               (yes-or-no-p
                (format "%s all eltainer activity (%d buffer%s%s)? "
                        verb
                        (length bufs)
                        (if (= 1 (length bufs)) "" "s")
                        (if events-live ", + Docker /events stream" "")))))
      (message "eltainer: %s cancelled"
               (if keep-buffers "quiet" "stop")))
     (t
      (dolist (b bufs)
        (if keep-buffers
            (eltainer--quiet-buffer b)
          (ignore-errors (kill-buffer b))))
      (when (fboundp 'docker-events-stop)
        (docker-events-stop))
      (let ((swept (eltainer-stop--sweep-timers)))
        (message "eltainer: %s %d buffer%s%s%s"
                 verb-past
                 (length bufs)
                 (if (= 1 (length bufs)) "" "s")
                 (if events-live ", killed /events stream" "")
                 (if (> swept 0)
                     (format ", swept %d orphan timer%s"
                             swept (if (= 1 swept) "" "s"))
                   "")))))))

(provide 'eltainer)
;;; eltainer.el ends here
