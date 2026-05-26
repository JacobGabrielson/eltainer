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

(defcustom k8s-fs-put-max-bytes (* 256 1024)
  "Upload-size cap for `k8s-fs-put'.
We encode bytes as base64 in the exec argv (no stdin streaming in
the WebSocket sync exec path), which Linux ARG_MAX makes unsafe
above a few hundred KB.  Below the cap is the common-case file
edit; for larger uploads a streaming variant can come later."
  :type 'integer
  :group 'k8s)

(defun k8s-fs-put (conn ns pod container dir name bytes)
  "Upload BYTES into POD/CONTAINER at DIR/NAME via base64-through-argv.
DIR is the absolute directory; NAME is the file's basename (no
slashes).  Refuses files larger than `k8s-fs-put-max-bytes' — that
cap exists because we don't (yet) stream stdin through the
WebSocket exec; bytes ride along base64-encoded in the argv."
  (when (string-match-p "/" name)
    (error "k8s-fs-put: NAME must be a basename (got %S)" name))
  (when (> (length bytes) k8s-fs-put-max-bytes)
    (error "k8s-fs-put: %d-byte payload exceeds cap %d (argv-encoded)"
           (length bytes) k8s-fs-put-max-bytes))
  (let* ((path (concat (file-name-as-directory dir) name))
         (b64 (base64-encode-string bytes 'no-line-break))
         (script (concat "printf '%s' \"$1\" | base64 -d > \"$2\""))
         (r (k8s-exec conn ns pod container
                      (list "sh" "-c" script "_" b64 path))))
    (k8s-fs--check r (format "put %s" path))
    nil))

(provide 'k8s-fs)
;;; k8s-fs.el ends here
