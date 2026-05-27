;;; docker-push.el --- Push images via the engine API -*- lexical-binding: t -*-
;;
;; Mirror of `docker-pull-image' for the reverse direction:
;; `POST /images/<name>/push' streams newline-delimited JSON progress
;; events.  Auth is resolved through `docker-auth' (same path that
;; pull uses).
;;
;; `M-x docker-image-push' prompts for the image name and pushes;
;; bound to `P' on the images view (one-key push for the image at
;; point).

(require 'cl-lib)
(require 'docker-api)
(require 'docker-http)
(require 'docker-stream)
(require 'docker-auth)
(require 'docker-pull)                  ; reuses helpers + renderer

(require 'magit-section)

(declare-function docker--ensure-config "docker")

(defun docker-push--image-at-point ()
  "Return the image alist on the current section, or signal."
  (let ((sec (magit-current-section)))
    (unless (and sec (eq (oref sec type) 'image))
      (user-error "Not on an image row"))
    (oref sec value)))

(defun docker-push--split (image)
  "Return (REPO . TAG) — REPO without tag, TAG defaults to `latest'.
Just an alias for `docker-pull--split-image-tag' to keep the
intent local."
  (docker-pull--split-image-tag image))

;;;###autoload
(defun docker-image-push (cfg image)
  "Push IMAGE to its registry (Docker Hub for unqualified names).
Renders the streamed progress in `*docker:push:IMAGE*'.
Authentication uses `docker-auth-header' against the registry
host parsed out of IMAGE -- same code path as the pull side."
  (interactive (list (docker--ensure-config)
                     (read-string "Image to push: ")))
  (let* ((registry (docker-pull--registry-from-image image))
         (parts (docker-push--split image))
         (repo (car parts))
         (tag (cdr parts))
         (auth (docker-auth-header registry))
         (bufname (format "*docker:push:%s*" image))
         (buf (get-buffer-create bufname))
         (ndjson (docker-stream-make-ndjson
                  (lambda (event)
                    (docker-pull--render-progress buf event)))))
    (when (null auth)
      (message "docker-push: no auth found for %s — push will fail \
unless the image is unauthenticated"
               (or registry "Docker Hub")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (format "POST /images/%s/push?tag=%s\n\n" repo tag)
                 'font-lock-face 'shadow)))
      (special-mode))
    (docker-http-stream
     cfg "POST" (format "/images/%s/push"
                         (url-hexify-string repo))
     :query `(("tag" . ,tag))
     :headers (if auth
                  `(("X-Registry-Auth" . ,auth))
                ;; The daemon expects an X-Registry-Auth header even
                ;; for anonymous pushes; an empty base64 of `{}' is the
                ;; conventional value.
                '(("X-Registry-Auth" . "e30=")))
     :on-chunk (lambda (bytes) (funcall ndjson bytes))
     :on-close (lambda ()
                 (funcall ndjson 'cleanup)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (let ((inhibit-read-only t))
                       (goto-char (point-max))
                       (insert (propertize "\n[done]\n"
                                           'font-lock-face 'shadow)))))))
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun docker-image-push-at-point ()
  "`P' on a docker images row: push that image."
  (interactive)
  (let* ((img (docker-push--image-at-point))
         (cfg (docker--ensure-config))
         (tags (and img (alist-get 'RepoTags img)))
         (tag (and tags (> (length tags) 0)
                   (let ((nm (aref tags 0)))
                     (and (not (equal nm "<none>:<none>")) nm)))))
    (unless tag
      (user-error "docker-push: image has no tagged name to push"))
    (docker-image-push cfg tag)))

(provide 'docker-push)
;;; docker-push.el ends here
