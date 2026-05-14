;;; docker-ps.el --- Container listing and lifecycle -*- lexical-binding: t -*-
;;
;; List, start, stop, restart, and remove Docker containers.
;; Uses the Docker CLI via docker-api.el.
;;
;; Usage:
;;   (docker-list-containers cfg)
;;   (docker-list-containers cfg :all t)
;;   (docker-start-container cfg "my-container")

(require 'cl-lib)
(require 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Data model

(cl-defstruct (docker-container (:constructor docker-container--new) (:copier nil))
  "A Docker container summary."
  id                ; string, short container ID
  image             ; string, image name
  command           ; string, entrypoint command
  created           ; string, creation timestamp
  ports             ; string, port mapping summary
  status            ; string, status line (e.g. "Up 2 hours")
  state             ; string, state (running, exited, etc.)
  name              ; string, container name
  size)             ; string, size or nil

(cl-defstruct (docker-container-detail (:constructor docker-container-detail--new) (:copier nil))
  "Detailed Docker container info (from docker inspect)."
  id                ; string, full ID
  name              ; string, container name
  image             ; string, image ID
  state             ; alist, container state details
  config            ; alist, container config
  network-settings  ; alist, network settings
  mount-settings)   ; vector, mount settings

;;; ---------------------------------------------------------------------------
;;; Container listing

(cl-defun docker-list-containers (cfg &key all)
  "List containers via docker CLI.
Returns a vector of `docker-container' structs (empty vector when none).
When ALL is non-nil, include stopped containers."
  (let* ((args (append '("ps")
                       (when all '("--all"))
                       '("--format" "{{json .}}")))
         (objs (apply #'docker-ndjson-command cfg args)))
    (vconcat
     (mapcar (lambda (j)
               (docker-container--new
                :id (cdr (assq 'ID j))
                :image (cdr (assq 'Image j))
                :command (cdr (assq 'Command j))
                :created (cdr (assq 'CreatedAt j))
                :ports (cdr (assq 'Ports j))
                :status (cdr (assq 'Status j))
                :state (cdr (assq 'State j))
                :name (cdr (assq 'Names j))
                :size (cdr (assq 'Size j))))
             objs))))

;;; ---------------------------------------------------------------------------
;;; Container lifecycle

(defun docker-start-container (cfg name)
  "Start container NAME.  Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg) (list "start" name)))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

(defun docker-stop-container (cfg name)
  "Stop container NAME.  Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg) (list "stop" name)))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

(defun docker-restart-container (cfg name)
  "Restart container NAME.  Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg) (list "restart" name)))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

(defun docker-kill-container (cfg name)
  "Kill (SIGKILL) container NAME.  Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg) (list "kill" name)))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

(defun docker-remove-container (cfg name &optional force)
  "Remove container NAME.  If FORCE, use --force.
Returns non-nil on success."
  (let* ((args (append (docker--tls-flags cfg)
                       '("rm")
                       (when force '("--force"))
                       (list name)))
         (result (apply #'docker-command args)))
    (eq (car result) 0)))

;;; ---------------------------------------------------------------------------
;;; Container states

(defun docker-container-running-p (container)
  "Return t if CONTAINER is running."
  (string= (docker-container-state container) "running"))

;;; ---------------------------------------------------------------------------
;;; Inspect helpers

(defun docker-inspect-container (cfg name)
  "Inspect container NAME.  Returns `docker-container-detail' or nil."
  (let ((json (docker-json-command cfg "inspect" name)))
    (when (and json (vectorp json) (> (length json) 0))
      (let ((data (aref json 0)))
        (docker-container-detail--new
         :id (cdr (assq 'Id data))
         :name (cdr (assq 'Name data))
         :image (cdr (assq 'Image data))
         :state (cdr (assq 'State data))
         :config (cdr (assq 'Config data))
         :network-settings (cdr (assq 'NetworkSettings data))
         :mount-settings (cdr (assq 'Mounts data)))))))

(provide 'docker-ps)
;;; docker-ps.el ends here
