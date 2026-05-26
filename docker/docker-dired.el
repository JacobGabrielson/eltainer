;;; docker-dired.el --- Dired-style FS browser for Docker containers -*- lexical-binding: t -*-
;;
;; The docker child of `eltainer-dired-mode': plugs `docker-fs-list'
;; and `docker-fs-cat' into the shared dired-derived parent, exposes
;; `docker-dired-browse' as the user-visible entry, and binds `f' in
;; the docker containers view.
;;
;; All the heavy lifting (rendering, navigation, marking, sort,
;; revert, the v1 read-only guards) lives in `eltainer-dired.el'.
;; This module is just the plug-in glue.

(require 'cl-lib)
(require 'docker-config)
(require 'docker-fs)
(require 'eltainer-dired)

;; Forward declarations -- defined in docker.el / docker-ps.el which
;; we don't require to avoid the cycle (docker.el requires us
;; indirectly through reload's module list).
(declare-function docker--container-at-point "docker")
(declare-function docker--ensure-config       "docker")
(declare-function docker-container-name        "docker-ps")
(declare-function docker-container-id          "docker-ps")

(define-derived-mode docker-dired-mode eltainer-dired-mode "Docker-Dired"
  "Browse a Docker container's filesystem with dired-mode keys.
Backend functions live in `docker-fs.el'; the shared rendering,
navigation, marking and v1 read-only guards live in
`eltainer-dired.el'.

Triggered by `f' on a container row in the docker containers view
\(`docker-dired-browse-at-point').  See
`docs/container-dired-plan.md' for the design.")

;;;###autoload
(defun docker-dired-browse (cfg container &optional initial-dir)
  "Open a `docker-dired-mode' buffer at INITIAL-DIR inside CONTAINER.
CFG is a `docker-config'; CONTAINER is the daemon-side container
name or id.  INITIAL-DIR defaults to `/'."
  (let* ((dir (or initial-dir "/"))
         (label (format "docker:%s" container))
         (prefix (format "/docker:%s:" container))
         (list-fn (lambda (path) (docker-fs-list cfg container path)))
         (cat-fn  (lambda (path) (docker-fs-cat  cfg container path))))
    (eltainer-dired-open label prefix dir list-fn cat-fn
                         :mode #'docker-dired-mode)))

;;;###autoload
(defun docker-dired-browse-at-point ()
  "Browse the filesystem of the container at point.
Bound to `f' in `docker-containers-mode-map'."
  (interactive)
  (let* ((c (docker--container-at-point))
         (cfg (docker--ensure-config))
         (cname (docker-container-name c)))
    (docker-dired-browse cfg cname "/")))

(provide 'docker-dired)
;;; docker-dired.el ends here
