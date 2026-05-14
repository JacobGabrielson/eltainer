;;; docker-images.el --- Docker image management -*- lexical-binding: t -*-
;;
;; List, pull, remove Docker images.  Uses the Docker CLI via
;; docker-api.el.
;;
;; Usage:
;;   (docker-list-images cfg)
;;   (docker-pull-image cfg "ubuntu:latest")
;;   (docker-remove-image cfg "ubuntu:latest")

(require 'cl-lib)
(require 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Data model

(cl-defstruct (docker-image (:constructor docker-image--new) (:copier nil))
  "A Docker image summary."
  id                ; string, short image ID
  repository        ; string, repository (tag)
  tag               ; string, image tag
  created           ; string, creation timestamp
  size)             ; string, human-readable size

;;; ---------------------------------------------------------------------------
;;; Image listing

(defun docker-list-images (cfg)
  "List Docker images via docker CLI.
Returns a vector of `docker-image' structs (empty vector when none)."
  (let ((objs (docker-ndjson-command cfg "images"
                                     "--format" "{{json .}}")))
    (vconcat
     (mapcar (lambda (j)
               (docker-image--new
                :id (cdr (assq 'ID j))
                :repository (cdr (assq 'Repository j))
                :tag (cdr (assq 'Tag j))
                :created (cdr (assq 'CreatedAt j))
                :size (cdr (assq 'Size j))))
             objs))))

;;; ---------------------------------------------------------------------------
;;; Image lifecycle

(defun docker-pull-image (cfg image &optional tag)
  "Pull IMAGE (with optional TAG) from a registry.
Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg)
                       '("pull")
                       (if tag (list (format "%s:%s" image tag))
                         (list image))))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

(defun docker-remove-image (cfg name &optional force)
  "Remove image NAME.  If FORCE, use --force.
Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg)
                       '("rmi")
                       (when force '("--force"))
                       (list name)))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

(defun docker-tag-image (cfg image new-tag)
  "Tag IMAGE with NEW-TAG (format `repo:tag').  Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg)
                       '("tag")
                       (list image new-tag)))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

;;; ---------------------------------------------------------------------------
;;; Inspect

(defun docker-inspect-image (cfg name)
  "Inspect image NAME.  Returns parsed JSON alist or nil."
  (docker-json-command cfg "inspect" name))

(provide 'docker-images)
;;; docker-images.el ends here
