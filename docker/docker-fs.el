;;; docker-fs.el --- Docker-side filesystem access -*- lexical-binding: t -*-
;;
;; The docker counterpart of `k8s-fs.el'.  list / stat ride the shared
;; POSIX scripts (in `eltainer-fs') over `docker-exec-run'; cat is on
;; the Docker archive API (`GET /containers/<id>/archive') so it works
;; even on distroless / scratch images where there's no `cat' or `sh'
;; inside the container.
;;
;; Public API:
;;   (docker-fs-list cfg container path)
;;   (docker-fs-stat cfg container path)
;;   (docker-fs-cat  cfg container path &optional max-bytes)
;;
;; All `path' values are absolute paths inside the container.

(require 'cl-lib)
(require 'docker-api)
(require 'docker-exec)
(require 'docker-http)
(require 'eltainer-fs)

;;; ---------------------------------------------------------------------------
;;; Exec-backed paths (list + stat)

(defun docker-fs--check (r context)
  "Raise an error iff `docker-exec-run' result R isn't success.
Delegates to the same `eltainer-fs-check-failure' the k8s side
uses — same distroless-friendly diagnostic on either backend."
  (eltainer-fs-check-failure
   context
   :exit-code (docker-exec-result-exit-code r)
   :stderr    (docker-exec-result-stderr r)))

(defun docker-fs-list (cfg container path)
  "Return entries in directory PATH inside CONTAINER via CFG.
Result is a list of `eltainer-fs-entry' (excluding . and ..).
Requires `sh', `find', `stat', `readlink' inside the container —
distroless / scratch images surface the friendly error from
`eltainer-fs-check-failure'."
  (let ((r (docker-exec-run
            cfg container
            (list "sh" "-c" eltainer-fs-list-script "_" path))))
    (docker-fs--check r (format "list %s" path))
    (eltainer-fs-parse-list-output (docker-exec-result-stdout r))))

(defun docker-fs-stat (cfg container path)
  "Return an `eltainer-fs-entry' describing PATH inside CONTAINER."
  (let ((r (docker-exec-run
            cfg container
            (list "sh" "-c" eltainer-fs-stat-script "_" path))))
    (docker-fs--check r (format "stat %s" path))
    (eltainer-fs-parse-stat-output (docker-exec-result-stdout r))))

;;; ---------------------------------------------------------------------------
;;; Archive-API-backed cat
;;
;; `GET /containers/<id>/archive?path=PATH' streams back a tar of
;; PATH.  For a single file the tar contains exactly one entry; we
;; parse its 512-byte USTAR header for the size and slice off the
;; payload.  No `cat' or `sh' needed inside the container — works on
;; distroless and scratch images for any path that exists.

(defun docker-fs--archive-bytes (cfg container path)
  "GET the tar of PATH from CONTAINER via CFG; return the raw bytes.
Signals `docker-api-error' on non-2xx (e.g. 404 if PATH is missing)."
  (let* ((full (concat (docker--api-prefix cfg)
                       (format "/containers/%s/archive" container)))
         (resp (docker-http-request cfg "GET" full
                                    :query `(("path" . ,path)))))
    (unless (docker-http-ok-p resp)
      (docker--engine-error resp full))
    (docker-http-response-body resp)))

(defun docker-fs--tar-string (bytes start max-len)
  "Return the NUL-terminated string at BYTES[START..START+MAX-LEN]."
  (let ((nul (string-search "\0" bytes start)))
    (substring bytes start
               (cond
                ((null nul) (+ start max-len))
                ((> nul (+ start max-len)) (+ start max-len))
                (t nul)))))

(defun docker-fs--tar-header-size (header)
  "Read the size field (offset 124, 12 bytes, octal) from tar HEADER."
  (let* ((raw (substring header 124 136))
         ;; Strip the NUL / space terminators tar uses on numeric fields.
         (trimmed (replace-regexp-in-string "[\0 ]+\\'" "" raw)))
    (if (string-empty-p trimmed) 0
      (string-to-number trimmed 8))))

(defun docker-fs--untar-first-file (tar-bytes path)
  "Parse TAR-BYTES (unibyte), return the first entry's content as bytes.
PATH is the requested file name, used for diagnostics only.
Signals if the first entry isn't a regular file."
  (when (< (length tar-bytes) 512)
    (error "docker-fs-cat: %s — tar response shorter than one header (%d bytes)"
           path (length tar-bytes)))
  (let* ((header (substring tar-bytes 0 512))
         (typeflag (aref header 156))
         (size (docker-fs--tar-header-size header)))
    (cond
     ((or (= typeflag ?0) (= typeflag 0))   ; regular file (USTAR '0' or old NUL)
      (substring tar-bytes 512 (+ 512 size)))
     ((= typeflag ?5)
      (error "docker-fs-cat: %s is a directory" path))
     ((= typeflag ?2)
      (error "docker-fs-cat: %s is a symlink to %S — cat the target instead"
             path (docker-fs--tar-string header 157 100)))
     (t
      (error "docker-fs-cat: %s — unsupported tar entry type %S" path typeflag)))))

(defun docker-fs-cat (cfg container path &optional max-bytes)
  "Return the contents of regular file PATH inside CONTAINER via CFG.
Uses the Docker archive API so the container doesn't need a `sh' or
`cat' binary inside it — this is the distroless-friendly path.

Returns the file's raw bytes (unibyte string); the caller is
responsible for decoding.  Refuses to return more than MAX-BYTES
\(default `eltainer-fs-max-cat-bytes').  The cap is checked
post-fetch since the archive endpoint has no preflight; a future
streaming variant can bail mid-fetch on the tar header's size
field."
  (let* ((cap (or max-bytes eltainer-fs-max-cat-bytes))
         (tar-bytes (docker-fs--archive-bytes cfg container path))
         (content (docker-fs--untar-first-file tar-bytes path)))
    (when (> (length content) cap)
      (error "docker-fs-cat: %s is %d bytes (cap %d) — pass MAX-BYTES to override"
             path (length content) cap))
    content))

(provide 'docker-fs)
;;; docker-fs.el ends here
