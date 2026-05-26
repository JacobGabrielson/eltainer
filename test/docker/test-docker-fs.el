;;; test-docker-fs.el --- Tests for docker-fs -*- lexical-binding: t -*-
;;
;; - Pure unit tests for the USTAR header parser (no daemon required).
;; - Integration tests that hit the live Docker daemon, mirroring the
;;   style of `test-docker-ps.el'.  They run the listing script in a
;;   short-lived `busybox' container and assert on the entries.

(require 'ert)
(require 'cl-lib)
(require 'docker-config)
(require 'docker-fs)

;;; ---------------------------------------------------------------------------
;;; USTAR header parser (no daemon needed)

(defun test-docker-fs--make-tar (name content)
  "Return a one-entry USTAR archive for NAME containing CONTENT."
  (let* ((size (length content))
         (header (make-string 512 0))
         (name-bytes (encode-coding-string name 'utf-8))
         (size-octal (format "%011o" size))
         ;; ustar fields we need: name (0..99), size (124..135),
         ;; typeflag (156).  Magic / version / checksum optional for
         ;; our parser's purposes (we only read size + typeflag).
         (i 0))
    ;; name (NUL-terminated within 100-byte field)
    (cl-loop for c across name-bytes
             while (< i 99)
             do (aset header i c) (cl-incf i))
    ;; size: 11 octal digits + NUL/space terminator at offset 124..135
    (cl-loop for c across size-octal
             for j from 124
             do (aset header j c))
    (aset header 135 0)
    ;; typeflag: regular file '0' at offset 156
    (aset header 156 ?0)
    ;; Pad content to 512-byte block.
    (let* ((pad-len (mod (- 512 (mod size 512)) 512))
           (pad (make-string pad-len 0)))
      (concat header content pad))))

(ert-deftest docker-fs/tar-header-size ()
  (let ((tar (test-docker-fs--make-tar "hostname" "elatainer-host\n")))
    (should (= 15 (docker-fs--tar-header-size (substring tar 0 512))))))

(ert-deftest docker-fs/untar-first-file-extracts-content ()
  (let* ((content "hello world\n")
         (tar (test-docker-fs--make-tar "greeting" content)))
    (should (equal content (docker-fs--untar-first-file tar "greeting")))))

(ert-deftest docker-fs/untar-empty-file ()
  (let ((tar (test-docker-fs--make-tar "empty" "")))
    (should (equal "" (docker-fs--untar-first-file tar "empty")))))

(ert-deftest docker-fs/untar-truncated-raises ()
  (should-error (docker-fs--untar-first-file (make-string 100 0) "junk")))

(ert-deftest docker-fs/untar-directory-raises ()
  "Directories (typeflag '5') aren't catable; surface a clear error."
  (let* ((tar (test-docker-fs--make-tar "dir" "")))
    (aset tar 156 ?5)
    (let ((err (should-error (docker-fs--untar-first-file tar "dir"))))
      (should (string-match-p "directory" (cadr err))))))

;;; ---------------------------------------------------------------------------
;;; Tar PUT builder (no daemon required)

(ert-deftest docker-fs/tar-put-roundtrip ()
  "A tar built by `docker-fs--make-tar' should be parseable by
`docker-fs--untar-first-file' — the same byte format on both sides."
  (let* ((content "imported from host\n")
         (tar (docker-fs--make-tar "import.txt" content #o644)))
    (should (equal content
                   (docker-fs--untar-first-file tar "import.txt")))))

(ert-deftest docker-fs/tar-put-checksum-valid ()
  "USTAR checksum field must verify (header bytes summed, with the
checksum field itself treated as 8 spaces).  Without it real `tar'
implementations refuse the archive."
  (let* ((tar (docker-fs--make-tar "x" "hello"))
         (header (substring tar 0 512))
         ;; Read the recorded checksum out of the header.
         (recorded (string-to-number
                    (replace-regexp-in-string
                     "[\0 ]+\\'" ""
                     (substring header 148 156))
                    8)))
    (should (= recorded (docker-fs--tar-checksum header)))))

;;; ---------------------------------------------------------------------------
;;; Integration: hit a real container via the live daemon

(defun test-docker-fs--running-container-name (cfg)
  "Return the name of any running container with a working `sh',
or nil if there isn't one.  Used to keep the integration tests
opt-in: they noop silently when nothing suitable is around."
  (require 'docker-ps)
  (let* ((containers (ignore-errors (docker-list-containers cfg))))
    (when (and containers (> (length containers) 0))
      (cl-loop for c across containers
               for name = (docker-container-name c)
               for r = (ignore-errors
                         (docker-exec-run cfg name '("sh" "-c" "echo ok") 5))
               when (and r (eql 0 (docker-exec-result-exit-code r))
                         (equal "ok\n" (docker-exec-result-stdout r)))
               return name))))

(ert-deftest docker-fs/list-root-of-live-container ()
  "Live-daemon: list `/' in any running container with `sh', expect
to find at least one of the usual top-level dirs."
  (let* ((cfg (ignore-errors (docker-config-detect)))
         (name (and cfg (test-docker-fs--running-container-name cfg))))
    (skip-unless name)
    (let* ((entries (docker-fs-list cfg name "/"))
           (names (mapcar #'eltainer-fs-entry-name entries)))
      (should (> (length entries) 0))
      (should (cl-some (lambda (n) (member n names))
                       '("etc" "bin" "usr" "var" "tmp" "proc"))))))

(ert-deftest docker-fs/cat-via-archive-api ()
  "Live-daemon: `/etc/hostname' should come back through the archive API."
  (let* ((cfg (ignore-errors (docker-config-detect)))
         (name (and cfg (test-docker-fs--running-container-name cfg))))
    (skip-unless name)
    (let ((bytes (docker-fs-cat cfg name "/etc/hostname")))
      (should (stringp bytes))
      (should (> (length bytes) 0)))))

(provide 'test-docker-fs)
;;; test-docker-fs.el ends here
