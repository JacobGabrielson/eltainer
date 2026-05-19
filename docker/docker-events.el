;;; docker-events.el --- Subscribe to /events for view auto-refresh -*- lexical-binding: t -*-
;;
;; Open a single long-lived `GET /events' stream and run a small
;; publish/subscribe layer on top.  View buffers subscribe with a
;; matcher predicate and a refresh callback; matching events trigger
;; a debounced refresh so a burst of activity (e.g. `docker compose
;; up') doesn't repaint the buffer 30 times in 200ms.

(require 'cl-lib)
(require 'docker-api)
(require 'docker-http)
(require 'docker-stream)

(defcustom docker-events-debounce-seconds 1.0
  "Minimum seconds between subscriber refreshes for the same buffer.
Events arriving inside this window collapse to a single trailing-edge
refresh.  1s feels responsive when you just did a `docker stop' but
soaks up bursts of activity (network reconfig, container churn,
healthcheck noise that slipped past the action filter)."
  :type 'number
  :group 'docker)

;; (BUFFER MATCH-FN REFRESH-FN LAST-FIRED-TIME TIMER)
(defvar docker-events--subscribers nil
  "List of subscribers; entries are mutated in place.")

(defvar docker-events--process nil
  "Active /events stream process, or nil.")

(defvar docker-events--config nil
  "Config used to start the active /events stream.")

(defun docker-events--running-p ()
  (and docker-events--process (process-live-p docker-events--process)))

(defun docker-events--prune-dead-subscribers ()
  (setq docker-events--subscribers
        (cl-remove-if-not
         (lambda (s) (buffer-live-p (car s)))
         docker-events--subscribers)))

(defun docker-events--dispatch (event)
  "Route EVENT (a decoded alist) to every matching subscriber."
  (docker-events--prune-dead-subscribers)
  (dolist (s docker-events--subscribers)
    (let ((buf (nth 0 s))
          (match (nth 1 s))
          (refresh (nth 2 s)))
      (when (and (buffer-live-p buf) (funcall match event))
        (docker-events--schedule s refresh)))))

(defun docker-events--schedule (sub refresh)
  "Debounced fire of REFRESH against SUB's buffer.

The actual REFRESH call is always deferred to `run-at-time' (with a
0s delay on the fast path, or the remaining debounce interval
otherwise) — *never* called synchronously from this function.

Why?  REFRESH does HTTP calls that block on `accept-process-output',
and `docker-events--schedule' is invoked from inside the /events
stream's process filter.  Calling REFRESH inline means
`accept-process-output' inside the refresh dispatches the next
/events chunk, which re-enters this dispatcher, which calls REFRESH
again, blowing `max-lisp-eval-depth' under bursty event traffic
(e.g. when the user kills several containers at once)."
  (let ((buf (nth 0 sub))
        (last (nth 3 sub))
        (timer (nth 4 sub))
        (now (float-time)))
    (when (timerp timer) (cancel-timer timer))
    (let ((delay (cond
                  ((or (null last)
                       (> (- now last) docker-events-debounce-seconds))
                   0)
                  (t (max 0.05
                          (- docker-events-debounce-seconds
                             (- now last)))))))
      (setf (nth 4 sub)
            (run-at-time delay nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (setf (nth 3 sub) (float-time))
                             (setf (nth 4 sub) nil)
                             (with-current-buffer buf
                               (condition-case err
                                   (funcall refresh)
                                 (error
                                  (message
                                   "docker-events: refresh failed in %s: %S"
                                   (buffer-name buf) err)))))))))))

(defun docker-events--ensure-stream (cfg)
  "Make sure a /events stream is running against CFG."
  (when (and docker-events--process
             (not (process-live-p docker-events--process)))
    (setq docker-events--process nil))
  (unless docker-events--process
    (setq docker-events--config cfg)
    (let ((ndjson
           (docker-stream-make-ndjson #'docker-events--dispatch)))
      (setq docker-events--process
            (docker-http-stream
             cfg "GET" "/events"
             :on-chunk (lambda (bytes) (funcall ndjson bytes))
             :on-close (lambda () (setq docker-events--process nil)))))))

(defun docker-events-subscribe (buffer match-fn refresh-fn)
  "Register BUFFER to refresh via REFRESH-FN when MATCH-FN matches an event.
MATCH-FN takes the parsed event alist and returns non-nil to fire."
  (push (list buffer match-fn refresh-fn nil nil) docker-events--subscribers))

(defun docker-events-unsubscribe (buffer)
  "Drop any subscriptions for BUFFER."
  (setq docker-events--subscribers
        (cl-remove-if (lambda (s) (eq (car s) buffer))
                      docker-events--subscribers)))

(defun docker-events-start (cfg)
  "Ensure the /events stream is running against CFG.  Safe to call repeatedly."
  (docker-events--ensure-stream cfg))

(defun docker-events-stop ()
  "Tear down the active /events stream and forget all subscribers."
  (interactive)
  (when (process-live-p docker-events--process)
    (delete-process docker-events--process))
  (setq docker-events--process nil
        docker-events--subscribers nil))

;;; ---------------------------------------------------------------------------
;;; Convenience: common matchers

(defconst docker-events--noisy-action-prefixes
  '("exec_create"        ; healthcheck probe creating an exec
    "exec_start"          ; healthcheck probe starting an exec
    "exec_die"            ; healthcheck probe exec exiting
    "exec_detach"
    "health_status"       ; periodic healthcheck status broadcast
    "top")                ; `docker top' polling, similar shape
  "Container event action prefixes that don't change list-view content.
Healthy containers fire `exec_*' + `health_status' on every probe (often
every 5–30s), each of which would trip the matcher and a refresh.  None
of those actions change what `docker ps' would render, so we filter
them out before dispatching to subscribers.")

(defun docker-events--noisy-p (event)
  "Return non-nil if EVENT is a healthcheck/exec firing that doesn't
change the container list."
  (let ((action (alist-get 'Action event)))
    (and action
         (cl-some (lambda (prefix)
                    (string-prefix-p prefix action))
                  docker-events--noisy-action-prefixes))))

(defun docker-events-match-types (&rest types)
  "Return a matcher that fires when the event's Type is in TYPES.
Filters out `exec_*' / `health_status' / `top' actions on container
events — those fire continuously on healthy containers and don't
change the view content.
Use like (docker-events-subscribe BUF (docker-events-match-types \"container\" \"network\") REFRESH)."
  (lambda (event)
    (and (member (alist-get 'Type event) types)
         (not (docker-events--noisy-p event)))))

(provide 'docker-events)
;;; docker-events.el ends here
