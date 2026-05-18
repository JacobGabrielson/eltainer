;;; k8s-watch.el --- K8s API watch (streaming events) -*- lexical-binding: t -*-
;;
;; Opens a persistent `?watch=true' connection to the K8s API server
;; and dispatches each event (ADDED/MODIFIED/DELETED) to a callback.
;;
;; Phase B: built on `docker-http-stream' and `docker-stream-make-ndjson'.
;; All HTTP framing, chunked-transfer decoding, and line splitting come
;; from the shared transport — this module is just reconnect logic and
;; resource-version tracking now.

(require 'cl-lib)
(require 'docker-http)
(require 'docker-stream)
(require 'k8s-api)

(cl-defstruct (k8s-watch (:constructor k8s-watch--new) (:copier nil))
  conn               ; k8s-connection
  path               ; API path (e.g., "/api/v1/pods")
  resource-version   ; string — resume point
  process            ; network process returned by docker-http-stream
  callback           ; (lambda (type object) ...) for each event
  active             ; non-nil while watch should be running
  retry-count        ; consecutive reconnection attempts
  retry-timer)       ; pending reconnection timer

;;; ---------------------------------------------------------------------------
;;; Connection setup

(defun k8s-watch--connect (watch)
  "Open the watch stream described by WATCH."
  (let* ((conn (k8s-watch-conn watch))
         (cfg (k8s-connection-docker-cfg conn))
         (path (k8s-watch-path watch))
         (rv (k8s-watch-resource-version watch))
         (query `(("watch" . "true")
                  ,@(when rv `(("resourceVersion" . ,rv)))))
         ;; Build the watch event consumer.
         (ndjson
          (docker-stream-make-ndjson
           (lambda (event)
             (let ((type (alist-get 'type event))
                   (object (alist-get 'object event)))
               (when (and type object)
                 ;; Refresh the resume point so a reconnect picks up
                 ;; where we left off.
                 (let* ((meta (alist-get 'metadata object))
                        (rv (alist-get 'resourceVersion meta)))
                   (when rv
                     (setf (k8s-watch-resource-version watch) rv)))
                 (when (k8s-watch-callback watch)
                   (condition-case err
                       (funcall (k8s-watch-callback watch) type object)
                     (error
                      (message "k8s watch: callback error: %s" err))))))))))
    (setf (k8s-watch-process watch)
          (docker-http-stream
           cfg "GET" path
           :query query
           :on-headers (lambda (status _reason _hs)
                         (unless (and (>= status 200) (< status 300))
                           (message "k8s watch: HTTP %d on %s" status path)))
           :on-chunk (lambda (bytes) (funcall ndjson bytes))
           :on-close (lambda ()
                       (when (k8s-watch-active watch)
                         (k8s-watch--reconnect watch)))))
    (setf (k8s-watch-retry-count watch) 0)
    (message "k8s watch: connected to %s" path)
    watch))

;;; ---------------------------------------------------------------------------
;;; Reconnect with backoff

(defun k8s-watch--reconnect (watch)
  "Reconnect a dropped watch with exponential backoff."
  (let* ((count (k8s-watch-retry-count watch))
         (delay (min 30 (expt 2 (min count 5)))))
    (setf (k8s-watch-retry-count watch) (1+ count))
    (message "k8s watch: reconnecting in %ds (attempt %d)…" delay (1+ count))
    (setf (k8s-watch-retry-timer watch)
          (run-at-time delay nil #'k8s-watch--do-reconnect watch))))

(defun k8s-watch--do-reconnect (watch)
  "Run the actual reconnection for WATCH."
  (when (k8s-watch-active watch)
    (when-let* ((proc (k8s-watch-process watch))
                ((process-live-p proc)))
      (ignore-errors (delete-process proc)))
    (setf (k8s-watch-process watch) nil)
    (condition-case err
        (k8s-watch--connect watch)
      (error
       (message "k8s watch: reconnect failed: %s" err)
       (k8s-watch--reconnect watch)))))

;;; ---------------------------------------------------------------------------
;;; Public API

(defun k8s-watch-start (conn path resource-version callback)
  "Start watching PATH on the K8s API via CONN.
RESOURCE-VERSION is the starting point (from a previous LIST).
CALLBACK is called with (TYPE OBJECT) for each event.
Returns a `k8s-watch' struct."
  (let ((watch (k8s-watch--new
                :conn conn
                :path path
                :resource-version resource-version
                :callback callback
                :active t
                :retry-count 0)))
    (k8s-watch--connect watch)
    watch))

(defun k8s-watch-stop (watch)
  "Stop WATCH and clean up resources."
  (when watch
    (setf (k8s-watch-active watch) nil)
    (when (k8s-watch-retry-timer watch)
      (cancel-timer (k8s-watch-retry-timer watch))
      (setf (k8s-watch-retry-timer watch) nil))
    (when-let* ((proc (k8s-watch-process watch))
                ((process-live-p proc)))
      (ignore-errors (delete-process proc)))
    (setf (k8s-watch-process watch) nil)))

(defun k8s-watch-active-p (watch)
  "Return non-nil if WATCH is active."
  (and watch (k8s-watch-active watch)))

(provide 'k8s-watch)
;;; k8s-watch.el ends here
