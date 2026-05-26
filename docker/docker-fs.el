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

;;; ---------------------------------------------------------------------------
;;; Archive-API-backed write (host -> container)
;;
;; PUT /containers/<id>/archive?path=<dir> with a tar of one or more
;; entries in the request body unpacks them at <dir> inside the
;; container.  Works on distroless / scratch (no in-container tools
;; required).  Single-file writer for now; multi-file batched copy
;; can come later when wdired needs it.

(defun docker-fs--tar-octal (n width)
  "Format integer N as a left-zero-padded WIDTH-char octal string
followed by NUL, the way USTAR numeric fields are encoded."
  (concat (format (format "%%0%do" width) n)
          (string 0)))

(defun docker-fs--tar-checksum (header)
  "Sum the bytes in HEADER (treating the 8-byte checksum field
itself as spaces, per the USTAR spec)."
  (let ((sum 0))
    (dotimes (i 512)
      (cl-incf sum
               (if (and (>= i 148) (< i 156)) 32
                 (aref header i))))
    sum))

(defun docker-fs--make-tar-file-header (name size mode)
  "Build one 512-byte USTAR header for a regular file NAME of SIZE
bytes with octal MODE (e.g. #o644)."
  (let* ((header (make-string 512 0))
         (name-bytes (encode-coding-string name 'utf-8))
         (i 0))
    (cl-loop for c across name-bytes
             while (< i 99)
             do (aset header i c) (cl-incf i))
    ;; mode (offset 100, 8 bytes)
    (let ((m (docker-fs--tar-octal mode 7)))
      (dotimes (j (length m)) (aset header (+ 100 j) (aref m j))))
    ;; uid / gid (offsets 108 / 116, 8 bytes each) — leave as zero (root).
    (let ((z (docker-fs--tar-octal 0 7)))
      (dotimes (j (length z))
        (aset header (+ 108 j) (aref z j))
        (aset header (+ 116 j) (aref z j))))
    ;; size (offset 124, 12 bytes)
    (let ((s (docker-fs--tar-octal size 11)))
      (dotimes (j (length s)) (aset header (+ 124 j) (aref s j))))
    ;; mtime (offset 136, 12 bytes) — now
    (let ((t- (docker-fs--tar-octal (truncate (float-time)) 11)))
      (dotimes (j (length t-)) (aset header (+ 136 j) (aref t- j))))
    ;; typeflag '0' = regular file (offset 156)
    (aset header 156 ?0)
    ;; ustar magic + version (offset 257..264)
    (let ((m "ustar\000" ))
      (dotimes (j (length m)) (aset header (+ 257 j) (aref m j))))
    (aset header 263 ?0) (aset header 264 ?0)
    ;; checksum field: 6 octal digits + NUL + space (offset 148)
    (let* ((sum (docker-fs--tar-checksum header))
           (csum (concat (format "%06o" sum) (string 0) " ")))
      (dotimes (j (length csum)) (aset header (+ 148 j) (aref csum j))))
    header))

(defun docker-fs--make-tar (name bytes &optional mode)
  "Build a one-entry USTAR archive (`name', `bytes', `mode' #o644 by
default), terminated by two 512-byte NUL blocks."
  (let* ((size (length bytes))
         (header (docker-fs--make-tar-file-header
                  name size (or mode #o644)))
         (pad-len (mod (- 512 (mod size 512)) 512))
         (pad (make-string pad-len 0))
         (terminator (make-string 1024 0)))
    (concat header bytes pad terminator)))

(defun docker-fs-put (cfg container dir name bytes &optional mode)
  "Upload BYTES into CONTAINER at DIR/NAME via the archive PUT API.
DIR is the absolute directory inside the container; NAME is the
file's basename (no slashes).  MODE defaults to #o644.

PUT /containers/<id>/archive?path=DIR with the body a tar that
contains one file called NAME.  No in-container tooling required —
works on distroless / scratch.  Signals on non-2xx."
  (when (string-match-p "/" name)
    (error "docker-fs-put: NAME must be a basename (got %S)" name))
  (let* ((tar (docker-fs--make-tar name bytes (or mode #o644)))
         (full (concat (docker--api-prefix cfg)
                       (format "/containers/%s/archive" container)))
         (resp (docker-http-request
                cfg "PUT" full
                :query `(("path" . ,dir))
                :headers '(("Content-Type" . "application/x-tar"))
                :body tar)))
    (unless (docker-http-ok-p resp)
      (docker--engine-error resp full))
    nil))

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
