;;; docker-create.el --- Create a new container from a form -*- lexical-binding: t -*-
;;
;; `+' on the docker containers view (or `M-x docker-create') pops
;; `*docker:create*' — a JSON template the user edits, then
;; `C-c C-c' POSTs `/containers/create' + `/containers/<id>/start'.
;; `C-c C-k' cancels.
;;
;; The "buffer-as-form" variant of what other Docker UIs do with a
;; multi-row widget.  Faster to ship, plays naturally with Emacs
;; muscle memory (yank, multiple-cursors, ediff), and the JSON shape
;; matches the engine API 1:1 — anything the API takes, the user can
;; set without us having to grow new form fields.

(require 'cl-lib)
(require 'json)
(require 'docker-config)
(require 'docker-api)
(require 'docker-http)

(declare-function docker--ensure-config "docker")

;; Optional: js-mode for syntax highlighting (built-in in Emacs).
(declare-function js-mode "js")

(defgroup docker-create nil
  "Container create-from-template form."
  :group 'docker
  :prefix "docker-create-")

(defcustom docker-create-template
  "{
  \"Image\": \"nginx:latest\",
  \"Cmd\": [],
  \"Env\": [],
  \"Labels\": {
    \"eltainer.created\": \"yes\"
  },
  \"ExposedPorts\": {},
  \"HostConfig\": {
    \"PortBindings\": {},
    \"Binds\": [],
    \"NetworkMode\": \"bridge\",
    \"RestartPolicy\": { \"Name\": \"unless-stopped\" }
  }
}
"
  "Initial JSON body shown in the create buffer.
Tweak this to your own defaults — the buffer is a free-form
edit, no validation beyond \"must parse as JSON\"."
  :type 'string
  :group 'docker-create)

(defcustom docker-create-default-name-prefix "eltainer-"
  "Prefix for the auto-suggested container name when the user
hasn't entered one.  The suggestion is `PREFIX<image-stem>-<random>'."
  :type 'string
  :group 'docker-create)

;;; ---------------------------------------------------------------------------
;;; Buffer state

(defvar-local docker-create--cfg nil
  "The `docker-config' the create buffer should POST to.")

;;; ---------------------------------------------------------------------------
;;; Banner + body parsing

(defconst docker-create--separator "---"
  "Marker line between the `#'-prefixed banner and the JSON body.")

(defun docker-create--insert-banner ()
  "Insert the `#'-prefixed banner explaining the field layout."
  (insert
   "# Create a new docker container.
# Edit the JSON below, then `C-c C-c' to POST + start it.
# `C-c C-k' cancels.
#
# Field reference (engine API 1.54):
#   Image                          required image name (e.g. \"nginx:1.27\")
#   Cmd                            array; overrides the image's CMD
#   Env                            array of \"KEY=value\" strings
#   Labels                         { \"label.key\": \"value\", ... }
#   ExposedPorts                   { \"80/tcp\": {}, ... } (informational only)
#   HostConfig.PortBindings        { \"80/tcp\": [{ \"HostPort\": \"8080\" }] }
#   HostConfig.Binds               [ \"/host/path:/container/path:ro\", ... ]
#   HostConfig.NetworkMode         \"bridge\" / \"host\" / a custom network name
#   HostConfig.RestartPolicy.Name  \"no\" / \"on-failure\" / \"always\" / \"unless-stopped\"
#
# After POST + start, the containers view will refresh and the new
# container will appear there.
")
  (insert docker-create--separator "\n"))

(defun docker-create--body ()
  "Return the JSON body text (everything after the separator)."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward (format "^%s[ \t]*\n"
                                    (regexp-quote docker-create--separator))
                            nil t)
        (buffer-substring-no-properties (point) (point-max))
      ;; No separator -- treat the whole buffer as the body.
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun docker-create--image-stem (image)
  "Return a short identifier built from IMAGE for the auto-name suggestion."
  (when image
    (let* ((no-reg (replace-regexp-in-string "\\`.+/" "" image))
           (no-tag (replace-regexp-in-string ":.+\\'" "" no-reg)))
      (replace-regexp-in-string "[^A-Za-z0-9_.-]" "-" no-tag))))

(defun docker-create--suggest-name (parsed-alist)
  "Return a default container name suggestion based on PARSED-ALIST."
  (let* ((image (cdr (assq 'Image parsed-alist)))
         (stem (or (docker-create--image-stem image) "container"))
         (rand (format "%04x" (random #x10000))))
    (format "%s%s-%s" docker-create-default-name-prefix stem rand)))

;;; ---------------------------------------------------------------------------
;;; The POST + start

(defun docker-create--post-create (cfg name body)
  "POST `/containers/create?name=NAME' with BODY (raw JSON string).
Returns the response struct.  Caller status-checks."
  (let* ((full (concat (docker--api-prefix cfg) "/containers/create")))
    (docker-http-request
     cfg "POST" full
     :query `(("name" . ,name))
     :headers '(("Content-Type" . "application/json"))
     :body body)))

(defun docker-create--post-start (cfg id-or-name)
  (docker-http-request
   cfg "POST"
   (concat (docker--api-prefix cfg)
           (format "/containers/%s/start" id-or-name))))

;;;###autoload
(defun docker-create-apply ()
  "Parse the buffer's JSON, POST `/containers/create' + `start'."
  (interactive)
  (unless docker-create--cfg
    (user-error "Not a docker-create buffer"))
  (let* ((body (docker-create--body))
         (parsed
          (condition-case err
              (let ((json-object-type 'alist)
                    (json-array-type 'vector)
                    (json-key-type 'symbol))
                (json-read-from-string body))
            (error
             (user-error "docker-create: JSON parse failed: %s"
                         (error-message-string err)))))
         (suggested (docker-create--suggest-name parsed))
         (name (read-string (format "Container name (default %s): " suggested)
                            nil nil suggested)))
    (unless (yes-or-no-p (format "POST + start as `%s'? " name))
      (user-error "Aborted"))
    (let* ((cfg docker-create--cfg)
           (resp (docker-create--post-create cfg name body)))
      (cond
       ((not (docker-http-ok-p resp))
        (let ((body (docker-http-response-body resp)))
          (with-current-buffer (get-buffer-create "*docker:create:error*")
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (format "POST /containers/create?name=%s failed [%d]\n\n%s\n"
                              name
                              (docker-http-response-status resp)
                              body))
              (special-mode)))
          (pop-to-buffer "*docker:create:error*")
          (user-error "docker-create: create failed (HTTP %d)"
                      (docker-http-response-status resp))))
       (t
        (let* ((parsed-resp
                (let ((json-object-type 'alist)
                      (json-array-type 'vector)
                      (json-key-type 'symbol))
                  (ignore-errors
                    (json-read-from-string
                     (docker-http-response-body resp)))))
               (id (and parsed-resp (cdr (assq 'Id parsed-resp))))
               (start-resp (docker-create--post-start cfg (or id name))))
          (cond
           ((docker-http-ok-p start-resp)
            (message "docker-create: %s created + started" name)
            ;; Refresh the containers view if it's open.
            (when-let ((b (get-buffer "*docker:containers*")))
              (with-current-buffer b (revert-buffer nil t)))
            (quit-window t))
           (t
            (message
             "docker-create: %s created but start failed (HTTP %d)"
             name (docker-http-response-status start-resp))))))))))

(defun docker-create-cancel ()
  "Kill the create buffer."
  (interactive)
  (kill-current-buffer))

;;; ---------------------------------------------------------------------------
;;; Mode + entry

(defvar docker-create-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'docker-create-apply)
    (define-key m (kbd "C-c C-k") #'docker-create-cancel)
    m)
  "Keymap for `docker-create-mode'.")

(define-derived-mode docker-create-mode prog-mode "Docker:Create"
  "Edit a JSON template, then `C-c C-c' POSTs + starts a container.

\\{docker-create-mode-map}"
  :interactive nil
  :group 'docker-create
  ;; Use js-mode's syntax for JSON-shaped buffers (built-in).
  (when (fboundp 'js-mode)
    (set-syntax-table (let ((tbl (make-syntax-table)))
                        (modify-syntax-entry ?# "<" tbl) ; `#' starts comments
                        (modify-syntax-entry ?\n ">" tbl)
                        tbl)))
  (setq-local indent-tabs-mode nil))

;;;###autoload
(defun docker-create ()
  "Open `*docker:create*' for editing + posting a new container."
  (interactive)
  (let ((buf (get-buffer-create "*docker:create*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (docker-create-mode)
        (docker-create--insert-banner)
        (let ((body-start (point)))
          (insert docker-create-template)
          (goto-char body-start))
        (setq docker-create--cfg (docker--ensure-config))
        (set-buffer-modified-p nil)))
    (pop-to-buffer buf)
    (message
     "docker-create: edit the JSON below the `---', then `C-c C-c'")))

(provide 'docker-create)
;;; docker-create.el ends here
