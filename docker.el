;;; docker.el --- Docker porcelain for Emacs -*- lexical-binding: t -*-
;;
;; Main entry point for eldocker.  Provides shared infrastructure
;; (connection, faces, helpers) and magit-section-based views for
;; containers and images.
;;
;; Usage:
;;   M-x docker

(require 'cl-lib)
(require 'magit-section)
(require 'transient)
(require 'docker-config)
(require 'docker-api)
(require 'docker-ps)
(require 'docker-images)
(require 'docker-logs)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup docker nil
  "Docker porcelain for Emacs."
  :prefix "docker-"
  :group 'tools)

(defcustom docker-config-override nil
  "Override the auto-detected Docker config.
Set this to a `docker-config' struct to bypass environment detection."
  :type '(choice (const nil) (const docker-config))
  :group 'docker)

;;; ---------------------------------------------------------------------------
;;; Internal state

(defvar-local docker--config nil
  "The `docker-config' for the current buffer.")

(defvar-local docker--header-end nil
  "Buffer position where the scrollable content begins (after header).")

;;; ---------------------------------------------------------------------------
;;; Faces

(defface docker-section-heading
  '((t :inherit magit-section-heading))
  "Face for section headings."
  :group 'docker)

(defface docker-container-name
  '((t :inherit magit-branch-local))
  "Face for container names."
  :group 'docker)

(defface docker-image-name
  '((t :inherit magit-tag))
  "Face for image names."
  :group 'docker)

(defface docker-status-running
  '((t :inherit success))
  "Face for Running status."
  :group 'docker)

(defface docker-status-exited
  '((t :inherit error))
  "Face for Exited status."
  :group 'docker)

(defface docker-status-other
  '((t :inherit warning))
  "Face for other statuses."
  :group 'docker)

(defface docker-dim
  '((t :inherit shadow))
  "Face for secondary information."
  :group 'docker)

;;; ---------------------------------------------------------------------------
;;; Connection helpers

(defun docker--detect-config ()
  "Return the Docker config to use."
  (or docker-config-override
      (docker-config-detect)))

(defun docker--ensure-config ()
  "Return the current buffer's config, detecting one if needed."
  (or docker--config
      (setq docker--config (docker--detect-config))))

;;; ---------------------------------------------------------------------------
;;; Shared helpers

(defun docker--age-string (timestamp)
  "Convert ISO TIMESTAMP to a human-readable age string."
  (if (null timestamp)
      "?"
    (let* ((then (float-time (date-to-time timestamp)))
           (now (float-time))
           (secs (- now then)))
      (cond
       ((< secs 60)       (format "%ds" (truncate secs)))
       ((< secs 3600)     (format "%dm" (truncate (/ secs 60))))
       ((< secs 86400)    (format "%dh" (truncate (/ secs 3600))))
       (t                 (format "%dd" (truncate (/ secs 86400))))))))

(defun docker--status-face (state)
  "Return the face for STATE string."
  (pcase state
    ("running"  'docker-status-running)
    ("up"       'docker-status-running)
    ("exited"   'docker-status-exited)
    ("dead"     'docker-status-exited)
    (_          'docker-status-other)))

(defun docker--truncate (str width)
  "Truncate STR to WIDTH characters, appending ellipsis if needed."
  (if (> (length str) width)
      (concat (substring str 0 (- width 3)) "...")
    str))

;;; ---------------------------------------------------------------------------
;;; Keymaps

(defvar-keymap docker-common-map
  "g" #'revert-buffer
  "q" #'quit-window
  "d" #'docker-delete-at-point
  "i" #'docker-inspect-at-point
  "l" #'docker-logs-at-point
  "?" #'docker-dispatch
  "RET" #'docker-dwim-ret)

;;; ---------------------------------------------------------------------------
;;; Header insertion

(defun docker--insert-header (view-name)
  "Insert the header with config info and current VIEW-NAME."
  (let* ((cfg (docker--ensure-config))
         (socket (docker-config-socket-path cfg))
         (host (docker-config-host cfg))
         (port (docker-config-port cfg)))
    (insert (propertize "Docker:    " 'font-lock-face 'docker-dim)
            view-name
            "\n")
    (insert (propertize "Endpoint:  " 'font-lock-face 'docker-dim)
            (cond
             (host (format "tcp://%s:%d" host (or port 2375)))
             (socket (format "unix://%s" socket))
             (t "unknown"))
            "\n\n")))

;;; ---------------------------------------------------------------------------
;;; Generic refresh engine

(defun docker--generic-refresh (view-name items column-header line-fn)
  "Refresh buffer showing VIEW-NAME.
ITEMS is a vector of structs.  COLUMN-HEADER is a string rendered
above the rows (nil to omit).  LINE-FN inserts one item as a
section."
  (let* ((inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (docker-root)
      (docker--insert-header view-name)
      (when column-header
        (insert (propertize column-header 'font-lock-face 'docker-section-heading)))
      (dolist (item (append items nil))
        (funcall line-fn item))
      (insert "\n"))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Container view

(defun docker--container-insert-line (container)
  "Insert a single container summary line as a section."
  (let* ((name (docker-container-name container))
         (image (docker-container-image container))
         (state (or (docker-container-state container) "?"))
         (status (or (docker-container-status container) ""))
         (ports (or (docker-container-ports container) ""))
         (created (docker-container-created container))
         (age (docker--age-string created)))
    (magit-insert-section (container container t)
      (magit-insert-heading
        (format "  %-30s %-10s %-10s %-12s %-6s\n"
                (propertize name 'font-lock-face 'docker-container-name)
                (propertize state 'font-lock-face (docker--status-face state))
                (docker--truncate image 25)
                (propertize ports 'font-lock-face 'docker-dim)
                (propertize age 'font-lock-face 'docker-dim)))
      ;; Collapsible detail body
      (insert (propertize (format "    Status:  %s\n" status)
                          'font-lock-face 'docker-dim))
      (insert (propertize (format "    Image:   %s\n" image)
                          'font-lock-face 'docker-dim))
      (insert (propertize (format "    Command: %s\n"
                                  (or (docker-container-command container) ""))
                          'font-lock-face 'docker-dim))
      (insert "\n"))))

(defmacro docker--define-container-view (name docstring api-fn column-header line-fn)
  "Define a container view named NAME.
Generates: docker--NAME-refresh, docker-NAME-mode, docker-NAME command.
API-FN fetches items, COLUMN-HEADER is the header string,
LINE-FN inserts one item."
  (let* ((namestr (symbol-name name))
         (display (capitalize namestr))
         (refresh-fn (intern (format "docker--%s-refresh" namestr)))
         (mode-fn (intern (format "docker-%s-mode" namestr)))
         (mode-map (intern (format "docker-%s-mode-map" namestr)))
         (cmd-fn (intern (format "docker-%s" namestr)))
         (buf-name (format "*docker:%s*" namestr)))
    `(progn
       (defun ,refresh-fn ()
         ,(format "Refresh the %s buffer." namestr)
         (let* ((cfg (docker--ensure-config))
                (items (funcall ,api-fn cfg)))
           (docker--generic-refresh ,display items ,column-header ,line-fn)))

       (defvar-keymap ,mode-map
         :parent magit-section-mode-map)
       (map-keymap (lambda (key def)
                     (keymap-set ,mode-map (key-description (vector key)) def))
                   docker-common-map)

       (define-derived-mode ,mode-fn magit-section-mode
         ,(format "Docker:%s" (capitalize namestr))
         ,docstring
         :interactive nil
         :group 'docker
         (setq-local revert-buffer-function
                     (lambda (_ignore-auto _noconfirm) (,refresh-fn)))
         (add-hook 'kill-buffer-hook #'docker--cleanup nil t))

       (defun ,cmd-fn ()
         ,(format "Display %s in the current Docker daemon." namestr)
         (interactive)
         (let ((buf (get-buffer-create ,buf-name)))
           (with-current-buffer buf
             (,mode-fn)
             (docker--ensure-config)
             (,refresh-fn))
           (pop-to-buffer buf))))))

;;; ---------------------------------------------------------------------------
;;; Image view

(defun docker--image-insert-line (image)
  "Insert a single image summary line as a section."
  (let* ((repo (or (docker-image-repository image) "<none>"))
         (tag (or (docker-image-tag image) "<none>"))
         (id (docker-image-id image))
         (created (docker-image-created image))
         (age (docker--age-string created))
         (size (or (docker-image-size image) "?")))
    (magit-insert-section (image image t)
      (magit-insert-heading
        (format "  %-35s %-20s %-12s %-6s\n"
                (propertize repo 'font-lock-face 'docker-image-name)
                (propertize tag 'font-lock-face 'docker-dim)
                (propertize size 'font-lock-face 'docker-dim)
                (propertize age 'font-lock-face 'docker-dim)))
      ;; Collapsible detail body
      (insert (propertize (format "    ID:   %s\n" id)
                          'font-lock-face 'docker-dim))
      (insert "\n"))))

;;; ---------------------------------------------------------------------------
;;; View definitions

(docker--define-container-view containers
  "Major mode for viewing Docker containers."
  #'docker-list-containers
  (format "  %-30s %-10s %-10s %-12s %-6s\n" "NAME" "STATE" "IMAGE" "PORTS" "AGE")
  #'docker--container-insert-line)

(docker--define-container-view containers-all
  "Major mode for viewing all Docker containers (including stopped)."
  (lambda (cfg) (docker-list-containers cfg :all t))
  (format "  %-30s %-10s %-10s %-12s %-6s\n" "NAME" "STATE" "IMAGE" "PORTS" "AGE")
  #'docker--container-insert-line)

;; Container lifecycle keys (live on both container views).
(dolist (map (list docker-containers-mode-map docker-containers-all-mode-map))
  (keymap-set map "s" #'docker-start-at-point)
  (keymap-set map "S" #'docker-stop-at-point)
  (keymap-set map "r" #'docker-restart-at-point)
  (keymap-set map "K" #'docker-kill-at-point))

(defun docker--images-refresh ()
  "Refresh the images buffer."
  (let* ((cfg (docker--ensure-config))
         (images (docker-list-images cfg))
         (hdr (format "  %-35s %-20s %-12s %-6s\n"
                      "REPOSITORY" "TAG" "SIZE" "AGE")))
    (docker--generic-refresh "Images" images hdr #'docker--image-insert-line)))

(defvar-keymap docker-images-mode-map
  :parent magit-section-mode-map)
(map-keymap (lambda (key def)
              (keymap-set docker-images-mode-map
                          (key-description (vector key)) def))
            docker-common-map)

(define-derived-mode docker-images-mode magit-section-mode "Docker:Images"
  "Major mode for viewing Docker images.

\\{docker-images-mode-map}"
  :interactive nil
  :group 'docker
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (docker--images-refresh)))
  (add-hook 'kill-buffer-hook #'docker--cleanup nil t))

;;;###autoload
(defun docker-images ()
  "Display all Docker images."
  (interactive)
  (let ((buf (get-buffer-create "*docker:images*")))
    (with-current-buffer buf
      (docker-images-mode)
      (docker--ensure-config)
      (docker--images-refresh))
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Transient dispatch

(transient-define-prefix docker-dispatch ()
  "Main eldocker command menu."
  ["Views"
   ("c" "Containers (running)" docker-containers)
   ("C" "Containers (all)"     docker-containers-all)
   ("I" "Images"               docker-images)]
  ["Container at point"
   ("s" "Start"   docker-start-at-point)
   ("S" "Stop"    docker-stop-at-point)
   ("r" "Restart" docker-restart-at-point)
   ("K" "Kill"    docker-kill-at-point)
   ("l" "Logs"    docker-logs-at-point)
   ("i" "Inspect" docker-inspect-at-point)
   ("d" "Remove"  docker-delete-at-point)]
  ["Buffer"
   ("g" "Refresh" revert-buffer)
   ("q" "Quit"    quit-window)])

;;;###autoload
(defun docker ()
  "Main entry point for eldocker.  Shows running containers by default."
  (interactive)
  (docker-containers))

;;; ---------------------------------------------------------------------------
;;; Inspect resource

(defun docker-inspect-at-point ()
  "Inspect the Docker object at point."
  (interactive)
  (let ((section (magit-current-section)))
    (unless section
      (user-error "Not on a resource"))
    (let* ((value (oref section value))
           (cfg (docker--ensure-config))
           (name (cond
                  ((docker-container-p value)
                   (docker-container-name value))
                  ((docker-image-p value)
                   (docker-image-repository value))
                  (t (user-error "Unknown resource type"))))
           (buf (get-buffer-create (format "*docker:inspect:%s*" name)))
           (json (docker-inspect cfg name)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize (format "Inspect: %s\n" name)
                              'font-lock-face 'docker-container-name)
                  "\n")
          (if json
              (docker--describe-value json 0)
            (insert "Inspect returned nil\n")))
        (goto-char (point-min))
        (special-mode)
        (local-set-key "q" #'quit-window)
        (local-set-key "g" #'docker-inspect-at-point))
      (pop-to-buffer buf))))

(defun docker--describe-value (value indent)
  "Recursively format VALUE as readable text at INDENT level."
  (cond
   ((null value) (insert "nil\n"))
   ((stringp value) (insert value "\n"))
   ((numberp value) (insert (format "%s\n" value)))
   ((eq value t) (insert "true\n"))
   ((vectorp value)
    (insert "\n")
    (seq-doseq (item (append value nil))
      (insert (make-string indent ?\s) "- ")
      (docker--describe-value item (+ indent 2))))
   ((and (listp value) (consp (car value)))
    ;; alist
    (insert "\n")
    (dolist (pair value)
      (let ((key (format "%s" (car pair))))
        (insert (make-string indent ?\s)
                (propertize (concat key ": ") 'font-lock-face 'docker-section-heading))
        (docker--describe-value (cdr pair) (+ indent 2)))))
   (t (insert (format "%S\n" value)))))

;;; ---------------------------------------------------------------------------
;;; Delete resource

(defun docker-delete-at-point ()
  "Delete the Docker object at point after confirmation."
  (interactive)
  (let ((section (magit-current-section)))
    (unless section
      (user-error "Not on a resource"))
    (let* ((value (oref section value))
           (type (oref section type))
           (cfg (docker--ensure-config))
           (name (cond
                  ((docker-container-p value)
                   (docker-container-name value))
                  ((docker-image-p value)
                   (docker-image-repository value))
                  (t (user-error "Unknown resource type")))))
      (when (yes-or-no-p (format "Delete %s %s? " type name))
        (cond
         ((docker-container-p value)
          (docker-remove-container cfg name)
          (message "eldocker: removed container %s" name))
         ((docker-image-p value)
          (docker-remove-image cfg name)
          (message "eldocker: removed image %s" name)))
        (revert-buffer)))))

;;; ---------------------------------------------------------------------------
;;; Container action helpers

(defun docker--container-at-point ()
  "Return the `docker-container' struct at point, or signal `user-error'."
  (let ((section (magit-current-section)))
    (unless section (user-error "Not on a resource"))
    (let ((value (oref section value)))
      (unless (docker-container-p value)
        (user-error "Not on a container"))
      value)))

(defmacro docker--define-container-action (verb api-fn ok-message)
  "Define an interactive lifecycle command for the container at point.
VERB is the lowercase action word; the generated function is named
`docker-VERB-at-point'.  API-FN is the docker-ps function
`(cfg name) → success-p'.  OK-MESSAGE is the format string with one
%s slot for the container name."
  (let ((fn-name (intern (format "docker-%s-at-point" verb))))
    `(defun ,fn-name ()
       ,(format "%s the container at point." (capitalize verb))
       (interactive)
       (let* ((c (docker--container-at-point))
              (name (docker-container-name c))
              (cfg (docker--ensure-config)))
         (if (,api-fn cfg name)
             (progn (message ,ok-message name) (revert-buffer))
           (message "eldocker: %s failed for %s" ,verb name))))))

(docker--define-container-action "stop"    docker-stop-container    "eldocker: stopped %s")
(docker--define-container-action "start"   docker-start-container   "eldocker: started %s")
(docker--define-container-action "restart" docker-restart-container "eldocker: restarted %s")
(docker--define-container-action "kill"    docker-kill-container    "eldocker: killed %s")

;;; ---------------------------------------------------------------------------
;;; Logs

(defun docker-logs-at-point ()
  "Open the log buffer for the container at point."
  (interactive)
  (docker-logs (docker--ensure-config)
               (docker-container-name (docker--container-at-point))))

;;; ---------------------------------------------------------------------------
;;; Smart RET

(defun docker-dwim-ret ()
  "Smart RET: toggle section collapse/expand."
  (interactive)
  (call-interactively #'magit-section-toggle))

;;; ---------------------------------------------------------------------------
;;; Cleanup

(defun docker--cleanup ()
  "Cleanup hook: release resources when a docker buffer is killed."
  ;; Currently no async resources to clean; reserved for future
  ;; (processes, timers, etc.)
  )

(provide 'docker)
;;; docker.el ends here
