;;; docker-stacks.el --- Compose-stack view -*- lexical-binding: t -*-
;;
;; `M-x docker-stacks' (or `S' from the dashboard) opens
;; `*docker:stacks*' — a magit-section tree of every Compose stack
;; on the daemon.  A "stack" is a set of containers sharing a
;; `com.docker.compose.project' label.  Each stack expands to its
;; services (`com.docker.compose.service'), each service expands
;; to its containers.
;;
;; All read-only in v1.  The mutating ops (up/down/restart) need
;; the `compose' plugin's CLI semantics (volume creation, network
;; setup, dependency ordering), which we'd either have to
;; re-implement or shell out to.  See
;; `docs/docker-feature-ideas.md' §"Compose-stack management".

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'eltainer-filter)
(require 'docker-config)
(require 'docker-ps)
(require 'docker)                       ; for `docker--ensure-config' etc.

(defgroup docker-stacks nil
  "Compose-stack view for the docker side."
  :group 'docker
  :prefix "docker-stacks-")

;;; ---------------------------------------------------------------------------
;;; Aggregation

(defun docker-stacks--label (container key)
  "Return CONTAINER's value for label KEY, or nil."
  (let ((labels (docker-container-labels container)))
    (or (cdr (assq (intern key) labels))
        (cdr (assoc key labels)))))

(defun docker-stacks--project (container)
  (docker-stacks--label container "com.docker.compose.project"))

(defun docker-stacks--service (container)
  (docker-stacks--label container "com.docker.compose.service"))

(defun docker-stacks--config-files (container)
  "Return the configured compose file paths for CONTAINER, if any
\(comma-separated list from the
`com.docker.compose.project.config_files' label)."
  (let ((s (docker-stacks--label container
                                 "com.docker.compose.project.config_files")))
    (and s (split-string s "," t))))

(defun docker-stacks-collect (cfg)
  "Walk every container on the daemon; group by compose project + service.
Returns an alist `((PROJECT . PLIST) ...)' where PLIST has keys
:config-files :services (an alist `((SVC . CONTAINERS) ...)')
:total :running.  Non-compose containers are dropped.

`docker-list-containers' with `:all t' so stopped stack members
are visible too."
  (let* ((all (docker-list-containers cfg :all t))
         (by-project (make-hash-table :test 'equal)))
    (seq-doseq (c all)
      (let ((proj (docker-stacks--project c)))
        (when proj
          (let* ((entry (or (gethash proj by-project)
                            (list :config-files nil
                                  :services (make-hash-table :test 'equal)
                                  :total 0 :running 0)))
                 (svc-tbl (plist-get entry :services))
                 (svc (or (docker-stacks--service c) "(no service)")))
            (push c (gethash svc svc-tbl nil))
            (cl-incf (cl-getf entry :total))
            (when (equal "running" (docker-container-state c))
              (cl-incf (cl-getf entry :running)))
            (unless (plist-get entry :config-files)
              (setf (cl-getf entry :config-files)
                    (docker-stacks--config-files c)))
            (puthash proj entry by-project)))))
    ;; Flatten the inner hash tables to alists, sort by project name.
    (let (out)
      (maphash
       (lambda (proj entry)
         (let* ((svc-tbl (plist-get entry :services))
                services)
           (maphash (lambda (s cs) (push (cons s (nreverse cs)) services))
                    svc-tbl)
           (setq services (sort services
                                (lambda (a b) (string< (car a) (car b)))))
           (push (cons proj
                       (list :config-files (plist-get entry :config-files)
                             :services services
                             :total (plist-get entry :total)
                             :running (plist-get entry :running)))
                 out)))
       by-project)
      (sort out (lambda (a b) (string< (car a) (car b)))))))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun docker-stacks--state-face (state)
  (cond
   ((equal state "running") 'eltainer-status-running)
   ((member state '("paused" "restarting" "created"))
                            'eltainer-status-warn)
   ((member state '("exited" "dead" "removing"))
                            'eltainer-status-error)
   (t                       'eltainer-status-other)))

(defun docker-stacks--insert-container (c)
  "One row per container, intended to live under a service section."
  (let* ((name (docker-container-name c))
         (state (docker-container-state c))
         (status (docker-container-status c))
         (image (docker-container-image c))
         (ports (docker-container-ports c)))
    (magit-insert-section (container c t)
      (magit-insert-heading
        (format "      %-30s %-10s %-40s %s\n"
                (propertize name 'font-lock-face 'eltainer-resource-name)
                (propertize state
                            'font-lock-face (docker-stacks--state-face state))
                (propertize (or image "?") 'font-lock-face 'eltainer-dim)
                (propertize (or status "") 'font-lock-face 'eltainer-dim)))
      (when (and ports (not (string-empty-p ports)))
        (insert (propertize (format "        ports: %s\n" ports)
                            'font-lock-face 'eltainer-dim))))))

(defun docker-stacks--insert-service (svc containers)
  "One service section containing one row per CONTAINERS replica."
  (let ((running (cl-count "running" containers
                            :test #'equal
                            :key #'docker-container-state))
        (total (length containers)))
    (magit-insert-section (compose-service svc t)
      (magit-insert-heading
        (format "    %-30s %3d/%-3d running\n"
                (propertize svc 'font-lock-face 'eltainer-resource-name)
                running total))
      (dolist (c containers)
        (docker-stacks--insert-container c)))))

(defun docker-stacks--insert-stack (project entry)
  (let* ((services (plist-get entry :services))
         (total (plist-get entry :total))
         (running (plist-get entry :running))
         (cfg-files (plist-get entry :config-files))
         (state-face (cond
                      ((= running total)  'eltainer-status-running)
                      ((zerop running)    'eltainer-status-error)
                      (t                  'eltainer-status-warn))))
    (magit-insert-section (compose-stack project t)
      (magit-insert-heading
        (format "  %-30s %3d/%-3d running   %s\n"
                (propertize project
                            'font-lock-face 'k8s-section-heading)
                running total
                (propertize
                 (format "%d service%s" (length services)
                         (if (= 1 (length services)) "" "s"))
                 'font-lock-face state-face)))
      (when cfg-files
        (insert (propertize
                 (format "    compose: %s\n"
                         (mapconcat #'identity cfg-files ", "))
                 'font-lock-face 'eltainer-dim)))
      (dolist (svc-entry services)
        (docker-stacks--insert-service (car svc-entry) (cdr svc-entry)))
      (insert "\n"))))

;;; ---------------------------------------------------------------------------
;;; Major mode + entry

(defvar-local docker-stacks--last-collected nil
  "Result of the most recent `docker-stacks-collect' call.")

(defun docker-stacks--render (stacks)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (docker-stacks-root)
      (insert (propertize "Compose stacks\n\n"
                          'font-lock-face 'eltainer-section-heading))
      (cond
       ((null stacks)
        (insert (propertize "  (no compose-managed containers found)\n"
                            'font-lock-face 'eltainer-dim))
        (insert (propertize "  Containers must carry the \
`com.docker.compose.project' label.\n"
                            'font-lock-face 'eltainer-dim)))
       (t
        (insert (propertize
                 (format "  %-30s %-9s %-9s %s\n"
                         "PROJECT" "STATE" "" "SERVICES")
                 'font-lock-face 'k8s-section-heading))
        (insert "\n")
        (dolist (entry stacks)
          (docker-stacks--insert-stack (car entry) (cdr entry))))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

(defun docker-stacks-refresh ()
  "Re-collect every compose stack and re-render."
  (interactive)
  (let* ((cfg (docker--ensure-config))
         (filter eltainer-filter--state)
         (stacks (docker-stacks-collect cfg))
         (stacks (if (and filter
                          (let ((nr (eltainer-filter-name-regex filter)))
                            (and nr (not (string-empty-p nr)))))
                     (seq-filter
                      (lambda (e) (eltainer-filter-match-name-p
                                   filter (car e)))
                      stacks)
                   stacks)))
    (setq docker-stacks--last-collected stacks)
    (docker-stacks--render stacks)))

(defvar docker-stacks-mode-map (make-sparse-keymap))
(defvar docker-common-map)              ; declared in docker.el
(set-keymap-parent docker-stacks-mode-map
                   (or (bound-and-true-p docker-common-map)
                       (make-sparse-keymap)))
(keymap-set docker-stacks-mode-map "g" #'docker-stacks-refresh)

(define-derived-mode docker-stacks-mode magit-section-mode "Docker:Stacks"
  "Read-only browser for Compose-managed container stacks.

\\{docker-stacks-mode-map}"
  :interactive nil
  :group 'docker-stacks
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function (lambda (_a _b) (docker-stacks-refresh))))

;;;###autoload
(defun docker-stacks ()
  "Open the Compose-stacks view."
  (interactive)
  (let ((buf (get-buffer-create "*docker:stacks*")))
    (with-current-buffer buf
      (docker-stacks-mode)
      (docker-stacks-refresh))
    (pop-to-buffer buf)))

(provide 'docker-stacks)
;;; docker-stacks.el ends here
