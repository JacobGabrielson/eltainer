;;; k8s-dired.el --- Dired-style FS browser for K8s pod containers -*- lexical-binding: t -*-
;;
;; The k8s child of `eltainer-dired-mode': plugs `k8s-fs-list' and
;; `k8s-fs-cat' into the shared dired-derived parent, exposes
;; `k8s-dired-browse' as the user-visible entry, and provides the
;; `f'-binding command for the pods view.  Multi-container pods pick
;; a container via `completing-read', remembered per (ns, pod) for
;; the session.
;;
;; All the heavy lifting (rendering, navigation, marking, sort,
;; revert, the v1 read-only guards) lives in `eltainer-dired.el'.

(require 'cl-lib)
(require 'eltainer-dired)
(require 'k8s-fs)

;; Forward declarations -- defined in k8s-pods.el / k8s.el which
;; we don't require to avoid the cycle.
(declare-function k8s--pod+container-at-point "k8s-pods")
(declare-function k8s--pod-container-names    "k8s-pods")
(declare-function k8s--resource-name          "k8s")
(declare-function k8s--resource-namespace     "k8s")
(declare-function k8s--ensure-connection      "k8s")

(define-derived-mode k8s-dired-mode eltainer-dired-mode "K8s-Dired"
  "Browse a Kubernetes pod container's filesystem with dired-mode keys.
Backend functions live in `k8s-fs.el'; the shared rendering,
navigation, marking and v1 read-only guards live in
`eltainer-dired.el'.

Triggered by `f' on a pod / container row in the pods view
\(`k8s-dired-browse-at-point').  See
`docs/container-dired-plan.md' for the design.")

(defvar k8s-dired--container-memo (make-hash-table :test 'equal)
  "Map (NS . POD) cons to the last-chosen container name for the session.
Migrated from the deleted `k8s-fs-ui.el'.")

(defun k8s-dired--pick-container (ns pod containers)
  "Choose a container in NS/POD from CONTAINERS (list of strings).
Returns nil for single-container pods; otherwise prompts via
`completing-read', remembering the choice for the session."
  (cond
   ((<= (length containers) 1) nil)
   (t
    (let* ((key (cons ns pod))
           (last (gethash key k8s-dired--container-memo))
           (default (or last (car containers)))
           (choice (completing-read
                    (format "Container in %s/%s: " ns pod)
                    containers nil t nil nil default)))
      (puthash key choice k8s-dired--container-memo)
      choice))))

;;;###autoload
(defun k8s-dired-browse (conn ns pod container &optional initial-dir)
  "Open a `k8s-dired-mode' buffer at INITIAL-DIR inside POD/CONTAINER.
CONN is the k8s connection; CONTAINER may be nil for single-container
pods.  INITIAL-DIR defaults to `/'.

Also wires the v2 writable ops: `exec-fn' / `check-fn' / `write-fn'
route through `k8s-exec' and (for host -> container) base64
through argv."
  (let* ((dir (or initial-dir "/"))
         (csuffix (if container (format "[%s]" container) ""))
         (label (format "k8s:%s/%s%s" ns pod csuffix))
         (prefix (format "/k8s:%s/%s%s:" ns pod csuffix))
         (list-fn  (lambda (path) (k8s-fs-list conn ns pod container path)))
         (cat-fn   (lambda (path) (k8s-fs-cat  conn ns pod container path)))
         (exec-fn  (lambda (argv) (k8s-exec conn ns pod container argv)))
         (check-fn #'k8s-fs--check)
         (write-fn (lambda (remote-dir basename bytes)
                     (k8s-fs-put conn ns pod container
                                 remote-dir basename bytes)))
         (buf (eltainer-dired-open label prefix dir list-fn cat-fn
                                   :mode #'k8s-dired-mode)))
    (with-current-buffer buf
      (setq-local eltainer-dired--exec-fn  exec-fn
                  eltainer-dired--check-fn check-fn
                  eltainer-dired--write-fn write-fn))
    buf))

;;;###autoload
(defun k8s-dired-browse-at-point ()
  "Browse the filesystem of the pod / container at point.
On a container subsection, browses that container directly;
on the pod line, picks a container via
`k8s-dired--pick-container'.  Bound to `f' in `k8s-pods-mode-map'."
  (interactive)
  (let* ((target (k8s--pod+container-at-point))
         (pod (car target))
         (preselected (cdr target))
         (name (k8s--resource-name pod))
         (ns (k8s--resource-namespace pod))
         (containers (k8s--pod-container-names pod))
         (container (or preselected
                        (k8s-dired--pick-container ns name containers)))
         (conn (k8s--ensure-connection)))
    (k8s-dired-browse conn ns name container "/")))

(provide 'k8s-dired)
;;; k8s-dired.el ends here
