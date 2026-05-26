;;; k8s-fs.el --- Pod-side filesystem access via k8s-exec -*- lexical-binding: t -*-
;;
;; Filesystem operations on Kubernetes pods, layered on `k8s-exec'.
;; The shell scripts, entry struct, parser and failure-detection
;; logic live in the shared `eltainer-fs' module (alongside the
;; equivalent docker-side wrappers); this file is just the
;; k8s-exec backend.
;;
;; Public API:
;;   (k8s-fs-list conn ns pod container path)
;;   (k8s-fs-cat  conn ns pod container path &optional max-bytes)
;;   (k8s-fs-stat conn ns pod container path)
;;
;; CONTAINER may be nil for single-container pods.  All `path' values
;; are absolute paths inside the pod.

(require 'cl-lib)
(require 'eltainer-fs)
(require 'k8s-exec)

(defun k8s-fs--check (r context)
  "Raise an error iff k8s-exec result R isn't success.
Delegates to `eltainer-fs-check-failure' so both backends produce
identical diagnostics (in particular the distroless case)."
  (eltainer-fs-check-failure
   context
   :exit-code (k8s-exec-result-exit-code r)
   :status    (k8s-exec-result-status r)
   :stderr    (k8s-exec-result-stderr r)
   :message   (k8s-exec-result-message r)))

(defun k8s-fs-list (conn ns pod container path)
  "Return entries in directory PATH inside POD/CONTAINER.
Result is a list of `eltainer-fs-entry' (excluding . and ..).
Order follows `find' (typically alphabetical or directory-traversal
order; the UI layer should sort if it cares)."
  (let* ((r (k8s-exec conn ns pod container
                      (list "sh" "-c" eltainer-fs-list-script "_" path))))
    (k8s-fs--check r (format "list %s" path))
    (eltainer-fs-parse-list-output (k8s-exec-result-stdout r))))

(defun k8s-fs-stat (conn ns pod container path)
  "Return an `eltainer-fs-entry' describing PATH inside POD/CONTAINER."
  (let* ((r (k8s-exec conn ns pod container
                      (list "sh" "-c" eltainer-fs-stat-script "_" path))))
    (k8s-fs--check r (format "stat %s" path))
    (eltainer-fs-parse-stat-output (k8s-exec-result-stdout r))))

(defun k8s-fs-cat (conn ns pod container path &optional max-bytes)
  "Return the contents of regular file PATH inside POD/CONTAINER.
Refuses to read files larger than MAX-BYTES (default
`eltainer-fs-max-cat-bytes').  Returns the raw bytes (unibyte
string); the caller is responsible for decoding."
  (let* ((cap (or max-bytes eltainer-fs-max-cat-bytes))
         (entry (k8s-fs-stat conn ns pod container path)))
    (unless (eq (eltainer-fs-entry-type entry) 'file)
      (error "k8s-fs-cat: %s is a %s, not a regular file"
             path (eltainer-fs-entry-type entry)))
    (when (> (eltainer-fs-entry-size entry) cap)
      (error "k8s-fs-cat: %s is %d bytes (cap %d) — pass MAX-BYTES to override"
             path (eltainer-fs-entry-size entry) cap))
    (let ((r (k8s-exec conn ns pod container (list "cat" "--" path))))
      (k8s-fs--check r (format "cat %s" path))
      (k8s-exec-result-stdout r))))

(provide 'k8s-fs)
;;; k8s-fs.el ends here
