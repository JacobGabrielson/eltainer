;;; k8s-pods.el --- Interactive pod listing for eltainer -*- lexical-binding: t -*-
;;
;; Provides an interactive buffer showing all pods in the current
;; Kubernetes cluster, inspired by magit's section-based UI.
;;
;; Usage:
;;   M-x k8s-pods

(require 'cl-lib)
(require 'magit-section)
(require 'docker-http)
(require 'k8s)
(require 'k8s-api)
(require 'k8s-fs-ui)

;;; ---------------------------------------------------------------------------
;;; Pod-specific helpers

(defun k8s--pod-phase (pod)
  "Return the phase (Running, Pending, Terminating, etc.) of POD.
Shows Terminating when deletionTimestamp is set (like kubectl does)."
  (if (cdr (assq 'deletionTimestamp (cdr (assq 'metadata pod))))
      "Terminating"
    (cdr (assq 'phase (cdr (assq 'status pod))))))

(defun k8s--pod-ip (pod)
  "Return the pod IP address."
  (cdr (assq 'podIP (cdr (assq 'status pod)))))

(defun k8s--pod-container-statuses (pod)
  "Return the vector of container statuses."
  (cdr (assq 'containerStatuses (cdr (assq 'status pod)))))

(defun k8s--pod-restarts (pod)
  "Return total restart count across all containers."
  (let ((statuses (k8s--pod-container-statuses pod))
        (total 0))
    (when statuses
      (seq-doseq (cs statuses)
        (cl-incf total (or (cdr (assq 'restartCount cs)) 0))))
    total))

(defun k8s--pod-ready-string (pod)
  "Return READY string like 1/2 for POD."
  (let ((statuses (k8s--pod-container-statuses pod)))
    (if statuses
        (let ((total (length statuses))
              (ready 0))
          (seq-doseq (cs statuses)
            (when (eq (cdr (assq 'ready cs)) t)
              (cl-incf ready)))
          (format "%d/%d" ready total))
      "0/0")))

;;; ---------------------------------------------------------------------------
;;; Section inserters

(defun k8s--insert-pod-line (pod)
  "Insert a single pod summary line as a section."
  (let* ((name (k8s--resource-name pod))
         (phase (k8s--pod-phase pod))
         (ready (k8s--pod-ready-string pod))
         (restarts (k8s--pod-restarts pod))
         (age (k8s--age-string (k8s--resource-creation-time pod)))
         (ip (or (k8s--pod-ip pod) "")))
    (magit-insert-section (pod pod t)
      (magit-insert-heading
        (format "  %-42s %-13s %-7s %-10s %-6s %s\n"
                (propertize name 'font-lock-face 'k8s-resource-name)
                (propertize (or phase "?") 'font-lock-face (k8s--phase-face phase))
                ready
                (propertize (format "%d" restarts) 'font-lock-face 'k8s-dim)
                (propertize age 'font-lock-face 'k8s-dim)
                (propertize ip 'font-lock-face 'k8s-dim)))
      ;; Collapsible detail body (hidden by default, expand with TAB)
      (k8s--insert-pod-details pod))))

(defun k8s--insert-pod-details (pod)
  "Insert expanded details for POD (containers, node, labels)."
  (let* ((spec (cdr (assq 'spec pod)))
         (node (or (cdr (assq 'nodeName spec)) "?"))
         (labels (k8s--resource-labels pod))
         (statuses (k8s--pod-container-statuses pod)))
    ;; Node
    (insert (propertize (format "    Node:   %s\n" node)
                        'font-lock-face 'k8s-dim))
    ;; Labels
    (when labels
      (insert (propertize "    Labels: " 'font-lock-face 'k8s-dim))
      (let ((first t))
        (dolist (pair labels)
          (unless first (insert (propertize "            " 'font-lock-face 'k8s-dim)))
          (insert (propertize (format "%s=%s\n" (car pair) (cdr pair))
                              'font-lock-face 'k8s-dim))
          (setq first nil))))
    ;; Containers
    (when statuses
      (insert (propertize "    Containers:\n" 'font-lock-face 'k8s-dim))
      (seq-doseq (cs statuses)
        (let ((cname (cdr (assq 'name cs)))
              (image (cdr (assq 'image cs)))
              (ready (cdr (assq 'ready cs)))
              (rc (or (cdr (assq 'restartCount cs)) 0)))
          (insert (propertize
                   (format "      %-20s %-40s ready=%-5s restarts=%d\n"
                           cname
                           (or image "?")
                           (if (eq ready t) "yes" "no")
                           rc)
                   'font-lock-face 'k8s-dim)))))
    (insert "\n")))

;;; ---------------------------------------------------------------------------
;;; Buffer refresh

(defun k8s--pods-refresh ()
  "Refresh the pods buffer content."
  (let* ((inhibit-read-only t)
         (ctx (k8s--save-point-context))
         (conn (k8s--ensure-connection))
         (pods (if (and k8s--resource-table
                        (> (hash-table-count k8s--resource-table) 0))
                   (vconcat (hash-table-values k8s--resource-table))
                 (k8s-list-pods conn k8s--namespace)))
         (grouped (k8s--group-by-namespace pods)))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (k8s-pods-root)
      (k8s--insert-header "Pods")
      (insert (propertize
               (format "  %-42s %-13s %-7s %-10s %-6s %s\n"
                       "NAME" "STATUS" "READY" "RESTARTS" "AGE" "IP")
               'font-lock-face 'k8s-section-heading))
      (insert "\n")
      (dolist (group grouped)
        (magit-insert-section (namespace (car group))
          (k8s--insert-namespace-heading (car group) (length (cdr group)))
          (dolist (pod (cdr group))
            (k8s--insert-pod-line pod))
          (insert "\n"))))
    ;; Cascade visibility: creates overlays for hidden sections
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (k8s--restore-point-context ctx)))

;;; ---------------------------------------------------------------------------
;;; Pod log viewer

(defun k8s--pod-container-names (pod)
  "Return a list of container names from POD spec."
  (let ((containers (cdr (assq 'containers (cdr (assq 'spec pod))))))
    (when containers
      (mapcar (lambda (c) (cdr (assq 'name c)))
              (append containers nil)))))

(defvar-local k8s--log-conn nil "Connection for log buffer.")
(defvar-local k8s--log-ns nil "Namespace for log buffer.")
(defvar-local k8s--log-pod nil "Pod name for log buffer.")
(defvar-local k8s--log-container nil "Container name for log buffer.")
(defvar-local k8s--log-process nil "Streaming HTTP process for this buffer.")

(defun k8s--log-cleanup ()
  "Tear down the streaming process attached to the current buffer."
  (when (process-live-p k8s--log-process)
    (delete-process k8s--log-process))
  (setq k8s--log-process nil))

(defun k8s--log-append (buf bytes)
  "Append BYTES to BUF, autoscrolling if point was at the end."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (at-end (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert bytes))
        (when at-end (goto-char (point-max)))))))

(defun k8s--log-start (&optional tail-lines)
  "Open a streaming connection for the current log buffer.
TAIL-LINES bounds the initial history (default 500)."
  (k8s--log-cleanup)
  (let* ((cfg (k8s-connection-docker-cfg k8s--log-conn))
         (path (format "/api/v1/namespaces/%s/pods/%s/log"
                       k8s--log-ns k8s--log-pod))
         (query `(("follow" . "true")
                  ("tailLines" . ,(number-to-string (or tail-lines 500)))
                  ,@(when k8s--log-container
                      `(("container" . ,k8s--log-container)))))
         (buf (current-buffer)))
    (let ((inhibit-read-only t)) (erase-buffer))
    (setq k8s--log-process
          (docker-http-stream
           cfg "GET" path
           :query query
           ;; No Accept override — the k8s API server returns 406 when
           ;; asked for text/plain even though the /log endpoint
           ;; happens to emit plain text for success.  Use the default
           ;; `application/json' from `default-headers'; for /log the
           ;; server still sends raw stdout text.
           :on-chunk (lambda (bytes) (k8s--log-append buf bytes))
           :on-close (lambda ()
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (let ((inhibit-read-only t))
                             (save-excursion
                               (goto-char (point-max))
                               (insert "\n[stream closed]\n"))))))))))

(defun k8s--log-restart ()
  "Restart the streaming connection for this buffer."
  (interactive)
  (unless (and k8s--log-conn k8s--log-ns k8s--log-pod)
    (user-error "Not a k8s log buffer"))
  (k8s--log-start))

(defun k8s--log-quit ()
  "Stop the log stream and quit the window."
  (interactive)
  (k8s--log-cleanup)
  (quit-window t))

(defvar-keymap k8s-log-mode-map
  :parent special-mode-map
  "g" #'k8s--log-restart
  "G" #'end-of-buffer
  "q" #'k8s--log-quit)

(define-derived-mode k8s-log-mode special-mode "K8s:Log"
  "Major mode for streaming Kubernetes pod logs.

\\{k8s-log-mode-map}"
  :group 'k8s
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook #'k8s--log-cleanup nil t))

(defun k8s-pod-view-logs ()
  "Show tailing logs for the pod at point."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'pod))
      (user-error "Not on a pod"))
    (let* ((pod (oref section value))
           (name (k8s--resource-name pod))
           (ns (k8s--resource-namespace pod))
           (containers (k8s--pod-container-names pod))
           (container (if (= (length containers) 1)
                          (car containers)
                        (completing-read
                         (format "Container (%s): " name)
                         containers nil t nil nil (car containers))))
           (conn (k8s--ensure-connection))
           (buf (get-buffer-create
                 (format "*k8s:logs:%s/%s[%s]*" ns name container))))
      (with-current-buffer buf
        (k8s-log-mode)
        (setq k8s--log-conn conn
              k8s--log-ns ns
              k8s--log-pod name
              k8s--log-container container)
        (k8s--log-start))
      (pop-to-buffer buf)
      (message "Streaming %s/%s[%s] — g=restart, q=quit" ns name container))))

(defun k8s-pod-browse-at-point ()
  "Open a read-only filesystem browser for the pod at point."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'pod))
      (user-error "Not on a pod"))
    (let* ((pod (oref section value))
           (name (k8s--resource-name pod))
           (ns (k8s--resource-namespace pod))
           (containers (k8s--pod-container-names pod))
           (container (k8s-fs--pick-container ns name containers))
           (conn (k8s--ensure-connection)))
      (k8s-pod-browse conn ns name container "/"))))

(defun k8s-pod-exec-at-point ()
  "Open an interactive TTY exec into the pod at point.
For multi-container pods, prompts for the container; for single-
container pods, uses the only one.  Defaults to `/bin/sh' as the
command — pass a prefix arg to enter a different one."
  (interactive)
  (require 'k8s-exec)
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'pod))
      (user-error "Not on a pod"))
    (let* ((pod (oref section value))
           (name (k8s--resource-name pod))
           (ns (k8s--resource-namespace pod))
           (containers (k8s--pod-container-names pod))
           (container (cond
                       ((null containers) nil)
                       ((= 1 (length containers)) (car containers))
                       (t (completing-read
                           (format "Container in %s/%s: " ns name)
                           containers nil t nil nil (car containers)))))
           (cmd (split-string-shell-command
                 (if current-prefix-arg
                     (read-shell-command (format "Exec in %s/%s: " ns name)
                                         "/bin/sh")
                   "/bin/sh")))
           (conn (k8s--ensure-connection)))
      (k8s-exec-interactive conn ns name container cmd))))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar-keymap k8s-pods-mode-map
  :parent magit-section-mode-map)

;; Pull in shared k8s view keys (RET, d, i, w, N, b context switch, ?, g, q)
;; first, then add pod-specific keys on top so locals can override common.
(map-keymap (lambda (key def)
              (keymap-set k8s-pods-mode-map (key-description (vector key)) def))
            k8s-common-map)
(keymap-set k8s-pods-mode-map "l" #'k8s-pod-view-logs)
(keymap-set k8s-pods-mode-map "e" #'k8s-pod-exec-at-point)
(keymap-set k8s-pods-mode-map "f" #'k8s-pod-browse-at-point)

(define-derived-mode k8s-pods-mode magit-section-mode "K8s:Pods"
  "Major mode for viewing Kubernetes pods.

\\{k8s-pods-mode-map}"
  :interactive nil
  :group 'k8s
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (k8s--pods-refresh)))
  (setq mode-line-format
        (list "%e" 'mode-line-front-space 'mode-line-mule-info
              'mode-line-modified 'mode-line-remote " "
              'mode-line-buffer-identification "  "
              '(:eval (k8s--watch-mode-line)) "  "
              'mode-line-position 'mode-line-modes
              'mode-line-end-spaces))
  (add-hook 'kill-buffer-hook #'k8s--watch-stop-for-buffer nil t))

;;; ---------------------------------------------------------------------------
;;; Interactive command

;;;###autoload
(defun k8s-pods ()
  "Display all pods in the current Kubernetes cluster."
  (interactive)
  (let ((buf (get-buffer-create "*k8s:pods*")))
    (with-current-buffer buf
      (k8s-pods-mode)
      (k8s--ensure-connection)
      (setq k8s--api-path-fn
            (lambda (ns) (k8s--list-path 'pods ns)))
      (k8s--pods-refresh))
    (pop-to-buffer buf)))

(provide 'k8s-pods)
;;; k8s-pods.el ends here
