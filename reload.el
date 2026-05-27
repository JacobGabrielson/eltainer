;;; reload.el --- Dev helper: byte-compile + reload all modules -*- lexical-binding: t -*-
;;
;; Eval-buffer this file (or `M-x eltainer-reload') to rebuild and
;; re-`load' every module in dependency order across both halves of
;; the merged repo (docker/ and k8s/).  Also re-enters the major mode
;; in any live buffer whose mode starts with `docker-' or `k8s-' so
;; freshly-bound keys land in already-open windows.

(require 'cl-lib)
(require 'bytecomp)

(defconst eltainer--source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this `reload.el' file (captured at load time).")

(defconst eltainer-docker-modules
  '("docker-config"
    "docker-http"
    "docker-stream"
    "docker-api"
    "docker-ps"
    "docker-images"
    "docker-networks"
    "docker-events"
    "docker-logs"
    "docker-exec"
    "docker-auth"
    "docker-pull"
    "docker-fs"
    "docker-dired"
    "docker-metrics"
    "docker")
  "Docker-side modules in load order (dependencies first).")

(defconst eltainer-k8s-modules
  '("k8s-config"
    "k8s-api"
    "k8s-prom"
    "k8s-marks"
    "k8s-metrics"
    "k8s-multilog"
    "k8s-watch"
    "k8s-fs"
    "k8s-dired"
    "k8s-pods"
    "k8s-exec"
    "k8s-traffic"
    "k8s"
    "k8s-helm"
    "k8s-crds"
    "k8s-pulse"
    "k8s-xray"
    "k8s-edit"
    "k8s-actions"
    "k8s-portforward"
    "k8s-events"
    "k8s-bookmarks"
    "k8s-scan")
  "K8s-side modules in load order (dependencies first).")

(defvar eltainer-reload-force nil
  "When non-nil, `eltainer-reload' recompiles every module unconditionally.
The default (nil) only recompiles + reloads modules whose `.el' is
newer than its `.elc' (or has no `.elc' yet, or hasn't been loaded
into the running session).  Bind to `t' for one-off full rebuilds.")

(defun eltainer--maybe-recompile-and-load (src module)
  "Conditionally recompile + reload SRC (a `.el' path) for MODULE.
Three states drive the decision; returns the state symbol:

  `recompiled' — `.el' is newer than `.elc' (or `.elc' is
                  missing), or `eltainer-reload-force' is non-nil.
                  Byte-compile, drop the feature, `load' fresh.
  `loaded'     — `.elc' is up-to-date but the feature isn't yet
                  bound in this session (cold start path).  `load'
                  without recompiling.
  `skipped'    — `.elc' is up-to-date AND the feature is already
                  loaded.  Nothing to do.
  `error'      — byte-compile reported failure (push to errors at
                  the call site)."
  (when (file-exists-p src)
    (let* ((elc (byte-compile-dest-file src))
           (needs-compile (or eltainer-reload-force
                              (not (and elc (file-exists-p elc)))
                              (file-newer-than-file-p src elc)))
           (sym (intern module))
           (loaded (featurep sym)))
      (cond
       (needs-compile
        (if (byte-compile-file src)
            (progn
              (setq features (delq sym features))
              (load (file-name-sans-extension src) nil 'nomessage)
              'recompiled)
          'error))
       ((not loaded)
        (load (file-name-sans-extension src) nil 'nomessage)
        'loaded)
       (t 'skipped)))))

(defun eltainer-reload (&optional force)
  "Recompile + reload every eltainer module whose `.el' is newer
than its `.elc' (or that hasn't been loaded yet), then re-enter
the major mode in any live `docker-*' / `k8s-*' buffer.

Quiets running activity from the *old* code first (so timers and
streams from the previous definitions don't keep firing after the
new code redefines them).  View buffers themselves are preserved
— only their timers/streams die.

With a prefix argument (`C-u M-x eltainer-reload', or non-nil
FORCE), recompile *every* module regardless of timestamps —
useful right after editing reload.el itself / a macro / a struct
definition where the byte-compiled callers may have inlined
something now stale."
  (interactive "P")
  ;; Quiet old-code activity before redefinition.  Tolerate
  ;; `eltainer-stop-all' not being loaded yet (cold start) and don't
  ;; let an error in any kill-hook (e.g. an exec-plugin failure when
  ;; a buffer's connection auth expired) abort the reload — just warn
  ;; and continue.  Worst case: a couple of old-code timers stay
  ;; armed; the user can run `eltainer-stop-all' explicitly.
  (when (fboundp 'eltainer-stop-all)
    (condition-case err
        (eltainer-stop-all nil 'keep-buffers 'no-confirm)
      (error (message "eltainer-reload: stop-all failed (%s); continuing"
                      (error-message-string err)))))
  (let* ((eltainer-reload-force (or force eltainer-reload-force))
         (docker-dir (expand-file-name "docker" eltainer--source-dir))
         (k8s-dir (expand-file-name "k8s" eltainer--source-dir))
         (load-path (append (list docker-dir k8s-dir
                                  eltainer--source-dir)
                            load-path))
         (errors nil)
         (recompiled 0) (loaded 0) (skipped 0))
    (cl-flet ((step (src mod)
                (pcase (eltainer--maybe-recompile-and-load src mod)
                  ('recompiled (cl-incf recompiled))
                  ('loaded     (cl-incf loaded))
                  ('skipped    (cl-incf skipped))
                  ('error      (push mod errors)))))
      ;; Top-level shared modules first.
      (dolist (mod '("eltainer-ui" "eltainer-gauge" "eltainer-fs"
                     "eltainer-dired" "eltainer-net" "eltainer-filter"
                     "eltainer-terminal" "eltainer-shell-helper"))
        (step (expand-file-name (concat mod ".el") eltainer--source-dir)
              mod))
      (cl-loop for (subdir . mods) in `((,docker-dir . ,eltainer-docker-modules)
                                        (,k8s-dir   . ,eltainer-k8s-modules))
               do
               (dolist (mod mods)
                 (step (expand-file-name (concat mod ".el") subdir) mod)))
      ;; Top-level loader.
      (step (expand-file-name "eltainer.el" eltainer--source-dir) "eltainer"))
    ;; Refresh live buffers.
    (let ((rebound 0))
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and (symbolp major-mode)
                     (or (string-prefix-p "docker-" (symbol-name major-mode))
                         (string-prefix-p "k8s-" (symbol-name major-mode)))
                     (string-suffix-p "-mode" (symbol-name major-mode))
                     (fboundp major-mode))
            (funcall major-mode)
            (cl-incf rebound))))
      (message
       "eltainer-reload: %d recompiled, %d loaded, %d skipped; %d buffer%s refreshed%s"
       recompiled loaded skipped
       rebound (if (= rebound 1) "" "s")
       (if errors
           (format "; %d compile failure(s): %s"
                   (length errors) (mapconcat #'identity errors ", "))
         "")))))

(provide 'reload)
;;; reload.el ends here
