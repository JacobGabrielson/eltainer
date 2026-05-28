;;; docker-df.el --- Disk-usage breakdown + prune actions -*- lexical-binding: t -*-
;;
;; `f' from the dashboard (or `M-x docker-df') opens `*docker:df*' —
;; the eltainer-flavoured equivalent of `docker system df'.  Shows
;; the per-category disk breakdown (images / containers / volumes /
;; build cache / networks) with a one-key prune per section.
;;
;; Data comes from `GET /system/df' (everything except networks) +
;; `GET /networks' for the network count.  Prunes go through the
;; respective `POST */prune' endpoints.

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)
(require 'eltainer-gauge)
(require 'docker-config)
(require 'docker-api)
(require 'docker-http)
(require 'docker)

(defgroup docker-df nil
  "Disk-usage breakdown + prune actions."
  :group 'docker
  :prefix "docker-df-")

;;; ---------------------------------------------------------------------------
;;; Aggregation

(defun docker-df--collect (cfg)
  "Return a plist summarising `/system/df' + the network count.
Keys: :images :containers :volumes :bcache :networks.  Each is a
plist with :count :size :prunable (when applicable) :objects."
  (let* ((df (condition-case nil (docker-engine-get cfg "/system/df")
               (error nil)))
         (images (append (or (cdr (assq 'Images df)) []) nil))
         (containers (append (or (cdr (assq 'Containers df)) []) nil))
         (volumes (append (or (cdr (assq 'Volumes df)) []) nil))
         (bcache (append (or (cdr (assq 'BuildCache df)) []) nil))
         (layers-size (cdr (assq 'LayersSize df)))
         (networks (condition-case nil
                       (length (docker-engine-get cfg "/networks"))
                     (error 0))))
    (list
     :images
     (list :count (length images)
           :size (or layers-size
                     (apply #'+ (mapcar (lambda (i) (or (cdr (assq 'Size i)) 0))
                                        images)))
           :dangling
           (cl-count-if (lambda (i)
                          ;; RepoTags can come back as a list OR a
                          ;; vector depending on the JSON decoder path.
                          (let* ((tags (cdr (assq 'RepoTags i)))
                                 (first (cond ((vectorp tags)
                                                (and (> (length tags) 0)
                                                     (aref tags 0)))
                                               ((listp tags) (car tags)))))
                            (or (null tags)
                                (and (= 1 (length tags))
                                     (equal "<none>:<none>" first)))))
                        images)
           :prunable
           (cl-loop for i in images
                    when (zerop (or (cdr (assq 'Containers i)) 0))
                    sum (or (cdr (assq 'Size i)) 0))
           :objects images)
     :containers
     (list :count (length containers)
           :size (apply #'+ (mapcar (lambda (c) (or (cdr (assq 'SizeRw c)) 0))
                                    containers))
           :stopped
           (cl-count-if (lambda (c)
                          (let ((state (cdr (assq 'State c))))
                            (and state (not (equal state "running")))))
                        containers)
           :prunable
           (cl-loop for c in containers
                    when (let ((state (cdr (assq 'State c))))
                           (and state (not (equal state "running"))))
                    sum (or (cdr (assq 'SizeRw c)) 0))
           :objects containers)
     :volumes
     (list :count (length volumes)
           :size (apply #'+
                        (mapcar (lambda (v)
                                  (or (cdr (assq 'Size
                                                  (cdr (assq 'UsageData v))))
                                      0))
                                volumes))
           :unused
           (cl-count-if (lambda (v)
                          (zerop (or (cdr (assq 'RefCount
                                                 (cdr (assq 'UsageData v))))
                                     0)))
                        volumes)
           :prunable
           (cl-loop for v in volumes
                    when (zerop (or (cdr (assq 'RefCount
                                                 (cdr (assq 'UsageData v))))
                                    0))
                    sum (or (cdr (assq 'Size
                                        (cdr (assq 'UsageData v))))
                            0))
           :objects volumes)
     :bcache
     (list :count (length bcache)
           :size (apply #'+ (mapcar (lambda (b) (or (cdr (assq 'Size b)) 0))
                                    bcache))
           :unused
           (cl-count-if (lambda (b) (not (eq (cdr (assq 'InUse b)) t)))
                        bcache)
           :prunable
           (cl-loop for b in bcache
                    unless (eq (cdr (assq 'InUse b)) t)
                    sum (or (cdr (assq 'Size b)) 0))
           :objects bcache)
     :networks
     (list :count networks))))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun docker-df--bytes (n)
  (eltainer-human-bytes (or n 0)))

(defun docker-df--section (cfg key label collected detail-lines &optional prune-help)
  "Render one section + its detail lines.  KEY is the section type
\(used by the `*-prune-at-point' commands)."
  (let* ((info (plist-get collected key))
         (count (or (plist-get info :count) 0))
         (size (or (plist-get info :size) 0))
         (prunable (plist-get info :prunable)))
    (magit-insert-section (docker-df-section key t)
      (magit-insert-heading
        (format "  %-14s %5d objects   %10s total%s\n"
                (propertize label 'font-lock-face 'eltainer-resource-name)
                count
                (propertize (docker-df--bytes size)
                            'font-lock-face 'k8s-dim)
                (cond
                 ((and prunable (> prunable 0))
                  (propertize (format "   %s reclaimable"
                                      (docker-df--bytes prunable))
                              'font-lock-face 'eltainer-status-warn))
                 (t ""))))
      (dolist (line detail-lines)
        (insert line))
      (when prune-help
        (insert (propertize (format "    %s\n" prune-help)
                            'font-lock-face 'eltainer-dim)))
      (ignore cfg))))

(defun docker-df--render (cfg collected)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (docker-df-root)
      (insert (propertize "Docker disk usage\n"
                          'font-lock-face 'eltainer-section-heading))
      (insert (propertize "  `p' on a section prunes (with confirm).  Build cache: `P' for `prune --all'.\n\n"
                          'font-lock-face 'eltainer-dim))
      ;; Images
      (let* ((info (plist-get collected :images))
             (dangling (plist-get info :dangling)))
        (docker-df--section
         cfg :images "Images" collected
         (list (propertize
                (format "    dangling: %d\n" dangling)
                'font-lock-face 'eltainer-dim))
         "p = prune dangling   P = prune all unused"))
      ;; Containers
      (let* ((info (plist-get collected :containers))
             (stopped (plist-get info :stopped)))
        (docker-df--section
         cfg :containers "Containers" collected
         (list (propertize
                (format "    stopped: %d\n" stopped)
                'font-lock-face 'eltainer-dim))
         "p = prune stopped"))
      ;; Volumes
      (let* ((info (plist-get collected :volumes))
             (unused (plist-get info :unused)))
        (docker-df--section
         cfg :volumes "Volumes" collected
         (list (propertize
                (format "    unused: %d\n" unused)
                'font-lock-face 'eltainer-dim))
         "p = prune unused"))
      ;; Build cache
      (let* ((info (plist-get collected :bcache))
             (unused (plist-get info :unused)))
        (docker-df--section
         cfg :bcache "Build cache" collected
         (list (propertize
                (format "    unused layers: %d\n" unused)
                'font-lock-face 'eltainer-dim))
         "p = prune old layers   P = prune ALL build cache"))
      ;; Networks (no size from /system/df)
      (docker-df--section
       cfg :networks "Networks" collected
       nil
       "p = prune unused custom networks"))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Prune

(defun docker-df--section-at-point ()
  "Return the section-type symbol on the current row, or signal."
  (let* ((sec (magit-current-section))
         (type (and sec (oref sec type)))
         (val (and sec (oref sec value))))
    (unless (and (eq type 'docker-df-section)
                 (memq val '(:images :containers :volumes :bcache :networks)))
      (user-error "Not on a section row"))
    val))

(defun docker-df--post-prune (cfg path &optional query)
  "POST PATH on the engine.  Returns the parsed JSON body."
  (let ((resp (docker-http-request
               cfg "POST"
               (concat (docker--api-prefix cfg) path)
               :query query)))
    (unless (docker-http-ok-p resp)
      (user-error "docker-df: %s failed (HTTP %d): %s"
                  path
                  (docker-http-response-status resp)
                  (or (docker-http-response-body resp) "")))
    (and (docker-http-response-body resp)
         (> (length (docker-http-response-body resp)) 0)
         (ignore-errors (docker-http-json resp)))))

(defun docker-df--report-prune (kind result)
  "Format a `prune' RESULT alist into a one-line message."
  (let ((reclaimed (cdr (assq 'SpaceReclaimed result)))
        (deleted (or (cdr (assq 'ContainersDeleted result))
                     (cdr (assq 'ImagesDeleted result))
                     (cdr (assq 'VolumesDeleted result))
                     (cdr (assq 'CachesDeleted result))
                     (cdr (assq 'NetworksDeleted result)))))
    (message
     "docker-df: pruned %d %s%s%s"
     (length (or deleted []))
     kind
     (if (= 1 (length (or deleted []))) "" "s")
     (if reclaimed
         (format "; reclaimed %s" (docker-df--bytes reclaimed))
       ""))))

(defun docker-df-prune-at-point (&optional all)
  "Prune the section at point.  With prefix arg ALL, do a more
aggressive prune where applicable (`P' on Images = include
non-dangling; `P' on Build cache = `prune --all')."
  (interactive "P")
  (let* ((cfg (docker--ensure-config))
         (which (docker-df--section-at-point)))
    (pcase which
      (:images
       (let* ((label (if all "ALL unused images" "dangling images"))
              (filters (if all
                            (json-serialize '((dangling . ["false"])))
                          (json-serialize '((dangling . ["true"]))))))
         (when (yes-or-no-p (format "Prune %s? " label))
           (docker-df--report-prune
            label
            (docker-df--post-prune
             cfg "/images/prune"
             `(("filters" . ,filters)))))))
      (:containers
       (when (yes-or-no-p "Prune stopped containers? ")
         (docker-df--report-prune
          "container"
          (docker-df--post-prune cfg "/containers/prune"))))
      (:volumes
       (when (yes-or-no-p
              "Prune unused volumes (data loss possible!)? ")
         (docker-df--report-prune
          "volume"
          (docker-df--post-prune cfg "/volumes/prune"))))
      (:bcache
       (when (yes-or-no-p
              (format "Prune build cache (%s)? "
                      (if all "ALL" "old / unused")))
         (docker-df--report-prune
          "cache layer"
          (docker-df--post-prune
           cfg "/build/prune"
           (when all '(("all" . "1")))))))
      (:networks
       (when (yes-or-no-p "Prune unused custom networks? ")
         (docker-df--report-prune
          "network"
          (docker-df--post-prune cfg "/networks/prune")))))
    (docker-df-refresh)))

;;; ---------------------------------------------------------------------------
;;; Mode + entry

(defun docker-df-refresh ()
  "Re-collect `/system/df' and re-render."
  (interactive)
  (let* ((cfg (docker--ensure-config))
         (collected (docker-df--collect cfg)))
    (docker-df--render cfg collected)))

(defvar docker-common-map)
(defvar docker-df-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'docker-df-refresh)
    (define-key m (kbd "p") #'docker-df-prune-at-point)
    (define-key m (kbd "P") (lambda ()
                              (interactive)
                              (let ((current-prefix-arg '(4)))
                                (call-interactively
                                 #'docker-df-prune-at-point))))
    (define-key m (kbd "q") #'quit-window)
    m)
  "Keymap for `docker-df-mode'.")
(set-keymap-parent docker-df-mode-map
                   (or (bound-and-true-p docker-common-map)
                       (make-sparse-keymap)))

(define-derived-mode docker-df-mode magit-section-mode "Docker:DF"
  "Docker disk-usage breakdown + prune actions.

\\{docker-df-mode-map}"
  :interactive nil
  :group 'docker-df
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function (lambda (_a _b) (docker-df-refresh))))

;;;###autoload
(defun docker-df ()
  "Open the docker disk-usage view."
  (interactive)
  (let ((buf (get-buffer-create "*docker:df*")))
    (with-current-buffer buf
      (docker-df-mode)
      (docker-df-refresh))
    (pop-to-buffer buf)))

(provide 'docker-df)
;;; docker-df.el ends here
