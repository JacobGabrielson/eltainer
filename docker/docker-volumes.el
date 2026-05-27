;;; docker-volumes.el --- Volume browser -*- lexical-binding: t -*-
;;
;; `V' from the dashboard (or `M-x docker-volumes') opens
;; `*docker:volumes*' — a magit-section table of every named volume
;; on the daemon: NAME / DRIVER / MOUNTPOINT / SIZE / IN-USE-BY /
;; CREATED.  Size comes from `/system/df' (which is the only docker
;; endpoint that reports per-volume disk usage).
;;
;; `d' deletes the volume at point (with confirmation); the engine
;; refuses to delete volumes currently in use, which we surface as
;; a clear error.

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'eltainer-gauge)
(require 'docker-config)
(require 'docker-api)
(require 'docker-ps)
(require 'docker)

(defgroup docker-volumes nil
  "Volume browser for the docker side."
  :group 'docker
  :prefix "docker-volumes-")

;;; ---------------------------------------------------------------------------
;;; API + aggregation

(defun docker-volumes-list (cfg)
  "Return a vector of volume alists via `GET /volumes'."
  (or (cdr (assq 'Volumes
                  (condition-case nil
                      (docker-engine-get cfg "/volumes")
                    (error nil))))
      []))

(defun docker-volumes--df-sizes (cfg)
  "Return hash NAME -> SIZE-IN-BYTES from `GET /system/df'."
  (let ((tbl (make-hash-table :test 'equal))
        (df (condition-case nil
                (docker-engine-get cfg "/system/df")
              (error nil))))
    (when df
      (let ((vols (append (or (cdr (assq 'Volumes df)) []) nil)))
        (dolist (v vols)
          (let ((name (cdr (assq 'Name v)))
                (size (or (cdr (assq 'Size (cdr (assq 'UsageData v))))
                          0)))
            (when name (puthash name size tbl))))))
    tbl))

(defun docker-volumes--in-use-by (cfg)
  "Return hash NAME -> list of container names that mount it."
  (let ((tbl (make-hash-table :test 'equal))
        (containers (docker-list-containers cfg :all t)))
    (seq-doseq (c containers)
      (let* ((id (docker-container-id c))
             (cname (docker-container-name c))
             (detail (ignore-errors
                       (docker-engine-get
                        cfg (format "/containers/%s/json" id))))
             (mounts (and detail
                          (append (or (cdr (assq 'Mounts detail)) [])
                                  nil))))
        (dolist (m mounts)
          (when (equal "volume" (cdr (assq 'Type m)))
            (let ((vname (cdr (assq 'Name m))))
              (when vname
                (puthash vname (cons cname (gethash vname tbl nil)) tbl)))))))
    tbl))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun docker-volumes--insert-row (vol sizes users)
  (let* ((name (cdr (assq 'Name vol)))
         (driver (or (cdr (assq 'Driver vol)) "?"))
         (mountpoint (or (cdr (assq 'Mountpoint vol)) ""))
         (scope (cdr (assq 'Scope vol)))
         (created (or (cdr (assq 'CreatedAt vol)) ""))
         (size (gethash name sizes 0))
         (cnames (gethash name users nil))
         (in-use (length cnames))
         (in-use-str (if (zerop in-use)
                         (propertize "(unused)" 'font-lock-face 'eltainer-dim)
                       (propertize (format "%d × %s"
                                           in-use
                                           (mapconcat #'identity cnames ", "))
                                   'font-lock-face 'k8s-dim))))
    (magit-insert-section (volume vol t)
      (magit-insert-heading
        (format "  %-32s %-10s %12s  %-40s  %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize driver 'font-lock-face
                            (if (member driver '("local" "tmpfs"))
                                'eltainer-status-running
                              'eltainer-status-warn))
                (propertize (if (numberp size) (eltainer-human-bytes size) "?")
                            'font-lock-face 'k8s-dim)
                in-use-str
                (propertize created 'font-lock-face 'eltainer-dim)))
      (unless (string-empty-p mountpoint)
        (insert (propertize (format "    mountpoint: %s\n" mountpoint)
                            'font-lock-face 'eltainer-dim)))
      (ignore scope))))

(defun docker-volumes-refresh ()
  "Re-list every volume and render."
  (interactive)
  (let* ((cfg (docker--ensure-config))
         (vols (append (docker-volumes-list cfg) nil))
         (sizes (docker-volumes--df-sizes cfg))
         (users (docker-volumes--in-use-by cfg))
         (vols (sort vols
                     (lambda (a b)
                       (string< (or (cdr (assq 'Name a)) "")
                                (or (cdr (assq 'Name b)) "")))))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (docker-volumes-root)
      (insert (propertize "Volumes\n\n"
                          'font-lock-face 'eltainer-section-heading))
      (insert (propertize
               (format "  %-32s %-10s %12s  %-40s  %s\n"
                       "NAME" "DRIVER" "SIZE" "USED BY" "CREATED")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (if (null vols)
          (insert (propertize "  (no volumes)\n" 'font-lock-face 'eltainer-dim))
        (dolist (v vols)
          (docker-volumes--insert-row v sizes users))))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Delete

(defun docker-volumes-delete-at-point ()
  "Delete the volume at point.  Refuses (with the engine's error)
when the volume is in use."
  (interactive)
  (let* ((sec (magit-current-section))
         (val (and sec (eq (oref sec type) 'volume) (oref sec value)))
         (name (and val (cdr (assq 'Name val)))))
    (unless name (user-error "Not on a volume row"))
    (when (yes-or-no-p (format "Delete volume `%s'? " name))
      (let* ((cfg (docker--ensure-config))
             (full (concat (docker--api-prefix cfg)
                           (format "/volumes/%s" name)))
             (resp (docker-http-request cfg "DELETE" full)))
        (cond
         ((docker-http-ok-p resp)
          (message "docker-volumes: deleted %s" name)
          (revert-buffer nil t))
         (t
          (user-error
           "docker-volumes: delete %s failed (HTTP %d): %s"
           name (docker-http-response-status resp)
           (or (docker-http-response-body resp) ""))))))))

;;; ---------------------------------------------------------------------------
;;; Mode + entry

(defvar docker-common-map)
(defvar docker-volumes-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'docker-volumes-refresh)
    (define-key m (kbd "d") #'docker-volumes-delete-at-point)
    (define-key m (kbd "q") #'quit-window)
    m)
  "Keymap for `docker-volumes-mode'.")
(set-keymap-parent docker-volumes-mode-map
                   (or (bound-and-true-p docker-common-map)
                       (make-sparse-keymap)))

(define-derived-mode docker-volumes-mode magit-section-mode "Docker:Volumes"
  "Volume browser.

\\{docker-volumes-mode-map}"
  :interactive nil
  :group 'docker-volumes
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function (lambda (_a _b) (docker-volumes-refresh))))

;;;###autoload
(defun docker-volumes ()
  "Open the volume-browser view."
  (interactive)
  (let ((buf (get-buffer-create "*docker:volumes*")))
    (with-current-buffer buf
      (docker-volumes-mode)
      (docker-volumes-refresh))
    (pop-to-buffer buf)))

(provide 'docker-volumes)
;;; docker-volumes.el ends here
