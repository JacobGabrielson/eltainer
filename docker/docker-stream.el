;;; docker-stream.el --- Frame parsers for streaming docker endpoints -*- lexical-binding: t -*-
;;
;; Two parsers consumed by `docker-http-stream' callbacks:
;;
;; - `docker-stream-make-demux'    8-byte multiplex frames the daemon uses
;;                                 for non-TTY logs / attach / exec output.
;;                                 Each frame: [type:1][0:3][size:4 BE][payload].
;;                                 type 0=stdin, 1=stdout, 2=stderr.
;;
;; - `docker-stream-make-ndjson'   line-oriented JSON-per-line, used by
;;                                 /events and image-pull progress streams.
;;
;; Each constructor returns a closure that you feed raw bytes; the
;; closure invokes per-frame callbacks and remembers partial input.

(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; Scratch-buffer accumulators
;;
;; Each parser used to append every chunk to a string accumulator —
;; `(setq buf (concat buf bytes))' — which is quietly O(n²) in total
;; bytes received.  Now each closure owns a hidden unibyte buffer
;; instead: `insert' is O(chunk), and the parser walks point /
;; `delete-region's consumed prefixes, so total work stays O(n).
;;
;; Buffer lifetime: callers should `(funcall closure 'cleanup)' on
;; stream close for prompt release; if they forget, a finalizer
;; attached to the closure kills the scratch buffer when the
;; closure is garbage-collected.
;;
;; NOTE: the finalizer's lambda *must not* reference the closure
;; (directly or indirectly) — otherwise the closure stays alive
;; forever and the finalizer never fires.  We only capture
;; `scratch' in the finalizer's body, and the closure body has a
;; `(ignore finalizer)' to keep finalizer alive as long as the
;; closure is reachable.

(defun docker-stream--make-scratch (name)
  "Create a hidden unibyte scratch buffer for stream parsing."
  (let ((buf (generate-new-buffer (concat " *" name "*") t)))
    (with-current-buffer buf
      (set-buffer-multibyte nil))
    buf))

;;; ---------------------------------------------------------------------------
;;; Multiplex stream demuxer

(defun docker-stream-make-demux (on-frame)
  "Return a function that feeds bytes through the 8-byte multiplex framer.
ON-FRAME is `(lambda (STREAM-TYPE PAYLOAD-BYTES))', STREAM-TYPE one of
`stdin' / `stdout' / `stderr' / `unknown'.

The returned closure recognises a `cleanup' sentinel symbol:
calling it with that symbol in place of bytes releases the
parser's scratch buffer eagerly.  Without that, the buffer is
killed only when the closure is garbage-collected."
  (let* ((scratch (docker-stream--make-scratch "docker-stream-demux"))
         (finalizer (make-finalizer
                     (lambda ()
                       (when (buffer-live-p scratch)
                         (kill-buffer scratch))))))
    (lambda (bytes)
      (ignore finalizer)
      (cond
       ((eq bytes 'cleanup)
        (when (buffer-live-p scratch) (kill-buffer scratch)))
       ((null bytes) nil)
       ((buffer-live-p scratch)
        (with-current-buffer scratch
          (goto-char (point-max))
          (insert bytes)
          (goto-char (point-min))
          (catch 'incomplete
            (while (>= (- (point-max) (point)) 8)
              (let* ((p (point))
                     (typ (char-after p))
                     (size (logior (ash (char-after (+ p 4)) 24)
                                   (ash (char-after (+ p 5)) 16)
                                   (ash (char-after (+ p 6)) 8)
                                   (char-after (+ p 7))))
                     (frame-end (+ p 8 size)))
                (if (> frame-end (point-max))
                    (throw 'incomplete nil)
                  (let ((payload (buffer-substring-no-properties
                                  (+ p 8) frame-end)))
                    (delete-region (point-min) frame-end)
                    (funcall on-frame
                             (pcase typ
                               (0 'stdin)
                               (1 'stdout)
                               (2 'stderr)
                               (_ 'unknown))
                             payload))))))))))))

;;; ---------------------------------------------------------------------------
;;; NDJSON splitter

(defun docker-stream-make-ndjson (on-object &optional on-malformed)
  "Return a function that splits bytes into newline-terminated JSON objects.
ON-OBJECT is `(lambda (OBJECT))' invoked with each decoded alist/list.
ON-MALFORMED is `(lambda (LINE ERR-STRING))' for parse failures (optional).

The returned closure recognises a `cleanup' sentinel symbol:
calling it with that symbol in place of bytes releases the
parser's scratch buffer eagerly.  Without that, the buffer is
killed only when the closure is garbage-collected."
  (let* ((scratch (docker-stream--make-scratch "docker-stream-ndjson"))
         (finalizer (make-finalizer
                     (lambda ()
                       (when (buffer-live-p scratch)
                         (kill-buffer scratch))))))
    (lambda (bytes)
      (ignore finalizer)
      (cond
       ((eq bytes 'cleanup)
        (when (buffer-live-p scratch) (kill-buffer scratch)))
       ((null bytes) nil)
       ((buffer-live-p scratch)
        (with-current-buffer scratch
          (goto-char (point-max))
          (insert bytes)
          (goto-char (point-min))
          (while (search-forward "\n" nil t)
            (let ((line (buffer-substring-no-properties
                         (point-min) (1- (point)))))
              (delete-region (point-min) (point))
              (when (> (length (string-trim line)) 0)
                (condition-case err
                    (funcall on-object
                             (json-parse-string
                              line
                              :object-type 'alist
                              :array-type 'list
                              :null-object nil
                              :false-object :false))
                  (error
                   (when on-malformed
                     (funcall on-malformed line
                              (error-message-string err))))))
              (goto-char (point-min))))))))))

(provide 'docker-stream)
;;; docker-stream.el ends here
