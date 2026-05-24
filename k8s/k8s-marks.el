;;; k8s-marks.el --- dired-style marks for eltainer k8s views -*- lexical-binding: t -*-
;;
;; `m' marks the resource at point, `u' unmarks, `U' unmarks all.
;; Marks survive a refresh (keyed on `metadata.uid' via the existing
;; `k8s--section-stable-id'); per-view commands operate on the marked
;; set — e.g. `L' in the pods view feeds them to `k8s-multilog'.
;;
;; Visualisation is a buffer overlay over the leading two-space indent
;; of the section's heading line, rewriting it to `* ' in
;; `k8s-mark' face.  Removing the mark drops the overlay; the source
;; text is unchanged.

(require 'cl-lib)
(require 'magit-section)

(defface k8s-mark
  '((((background dark)) :foreground "#fabd2f" :weight bold)
    (t                   :foreground "#b58900" :weight bold))
  "Face for the `* ' indicator in front of a marked section heading."
  :group 'k8s)

(defvar-local k8s--marks nil
  "Buffer-local hash UID -> overlay for the marked resource sections.
Pattern mirrors `k8s--expanded-sections': lazily initialized,
re-applied on every refresh via `k8s--marks-reapply'.")

;; Defined in k8s.el; declare to silence the byte-compiler since k8s
;; requires us (cycle).
(declare-function k8s--section-stable-id "k8s")

(defun k8s--marks-ensure ()
  "Return the buffer-local marks hash, creating it if needed."
  (unless (hash-table-p k8s--marks)
    (setq k8s--marks (make-hash-table :test 'equal)))
  k8s--marks)

(defun k8s--marks--find-section (id)
  "Walk the current buffer; return the section whose stable-id is ID."
  (let (result seen)
    (save-excursion
      (goto-char (point-min))
      (while (and (not result) (not (eobp)))
        (let ((sec (get-text-property (point) 'magit-section)))
          (when (and sec (not (memq sec seen)))
            (push sec seen)
            (when (equal (k8s--section-stable-id
                          (ignore-errors (oref sec value)))
                         id)
              (setq result sec))))
        (forward-line 1)))
    result))

(defun k8s--marks--make-overlay (sec)
  "Create the `* ' decoration overlay over SEC's heading-line indent."
  (let* ((start (oref sec start))
         ;; Heading lines all start with `  '; the overlay rewrites
         ;; those two chars via `display' so the source layout stays
         ;; intact when the mark goes away.
         (ov (make-overlay start (min (point-max) (+ start 2)))))
    (overlay-put ov 'display (propertize "* " 'face 'k8s-mark))
    (overlay-put ov 'evaporate t)
    ov))

(defun k8s--mark-id (id)
  "Mark the section identified by ID, if it's currently in the buffer."
  (when id
    (let ((tbl (k8s--marks-ensure)))
      ;; Drop any stale overlay first so re-marking is idempotent.
      (let ((existing (gethash id tbl)))
        (when (overlayp existing) (delete-overlay existing)))
      (when-let* ((sec (k8s--marks--find-section id))
                  (ov (k8s--marks--make-overlay sec)))
        (puthash id ov tbl)))))

(defun k8s--unmark-id (id)
  "Unmark the section identified by ID."
  (when (and id (hash-table-p k8s--marks))
    (let ((ov (gethash id k8s--marks)))
      (when (overlayp ov) (delete-overlay ov))
      (remhash id k8s--marks))))

(defun k8s--marks-reapply ()
  "Re-create overlays for every UID still in the marks hash.
Stale entries (resource went away in the latest render) get
pruned silently."
  (when (hash-table-p k8s--marks)
    (let (still-marked)
      (maphash (lambda (id _ov) (push id still-marked)) k8s--marks)
      (maphash (lambda (_id ov) (when (overlayp ov) (delete-overlay ov)))
               k8s--marks)
      (clrhash k8s--marks)
      (dolist (id still-marked)
        (k8s--mark-id id)))))

(defun k8s--marked-resources ()
  "Return the resource alists currently marked in this buffer.
Walks the buffer once to resolve each UID to its live section."
  (let (out)
    (when (hash-table-p k8s--marks)
      (maphash
       (lambda (id _ov)
         (when-let* ((sec (k8s--marks--find-section id))
                     (val (ignore-errors (oref sec value))))
           (when (and (listp val) (assq 'metadata val))
             (push val out))))
       k8s--marks))
    (nreverse out)))

(defun k8s--marks-count ()
  "Return the number of currently-marked resources in this buffer."
  (if (hash-table-p k8s--marks) (hash-table-count k8s--marks) 0))

;;; ---------------------------------------------------------------------------
;;; Interactive commands (wired into `k8s-common-map' from k8s.el)

(defun k8s-mark ()
  "Mark the resource at point and advance to the next line."
  (interactive)
  (let* ((sec (magit-current-section))
         (val (and sec (ignore-errors (oref sec value))))
         (id (k8s--section-stable-id val)))
    (cond
     ((null id)
      (user-error "Not on a markable resource"))
     (t
      (k8s--mark-id id)
      (forward-line 1)))))

(defun k8s-unmark ()
  "Unmark the resource at point (if marked) and advance to the next line."
  (interactive)
  (let* ((sec (magit-current-section))
         (val (and sec (ignore-errors (oref sec value))))
         (id (k8s--section-stable-id val)))
    (when id (k8s--unmark-id id))
    (forward-line 1)))

(defun k8s-unmark-all ()
  "Unmark every resource in this buffer."
  (interactive)
  (when (hash-table-p k8s--marks)
    (let ((n (hash-table-count k8s--marks)))
      (maphash (lambda (_id ov)
                 (when (overlayp ov) (delete-overlay ov)))
               k8s--marks)
      (clrhash k8s--marks)
      (message "k8s: unmarked %d resource%s" n (if (= 1 n) "" "s")))))

(defun k8s-unmark-backward ()
  "Unmark the resource on the previous line and move point to it.
Same shape as `dired-unmark-backward', bound to DEL."
  (interactive)
  (forward-line -1)
  (let* ((sec (magit-current-section))
         (val (and sec (ignore-errors (oref sec value))))
         (id (k8s--section-stable-id val)))
    (when id (k8s--unmark-id id))))

(defun k8s-toggle-marks ()
  "Toggle every resource's mark in this buffer (marked <-> unmarked).
Mirrors `dired-toggle-marks'."
  (interactive)
  (let ((tbl (k8s--marks-ensure))
        seen (currently-marked (make-hash-table :test 'equal)))
    ;; Snapshot what's marked now.
    (maphash (lambda (id _ov) (puthash id t currently-marked)) tbl)
    ;; Walk the buffer; for each resource section, mark it iff it
    ;; wasn't marked before.
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((sec (get-text-property (point) 'magit-section)))
          (when (and sec (not (memq sec seen)))
            (push sec seen)
            (let* ((val (ignore-errors (oref sec value)))
                   (id (k8s--section-stable-id val)))
              (when (and id (listp val) (assq 'metadata val))
                (if (gethash id currently-marked)
                    (k8s--unmark-id id)
                  (k8s--mark-id id))))))
        (forward-line 1)))))

;;; ---------------------------------------------------------------------------
;;; Shared keymap fragment for k8s views
;;
;; `k8s-common-map' carries every binding the view modes share —
;; navigation, describe / delete / watch / namespace, the dispatch
;; transient, and the dired-style marks above.  It used to live in
;; k8s.el, but k8s-pods.el loads before k8s.el; copying common-map's
;; bindings into `k8s-pods-mode-map' at load time picked up an
;; old (pre-reload) snapshot.  Defining it here — in a module loaded
;; before any view file — lets per-view maps inherit via :parent
;; rather than copy, so a reload that adds bindings to common-map
;; takes effect everywhere immediately.
;;
;; Several entries reference commands defined in k8s.el (k8s-dispatch,
;; k8s-describe, etc.).  Keymap entries store symbols and resolve at
;; key-press time, so those forward references are fine.

(declare-function k8s-dwim-ret             "k8s")
(declare-function k8s-delete-at-point      "k8s")
(declare-function k8s-describe             "k8s")
(declare-function k8s-watch-toggle         "k8s")
(declare-function k8s-set-namespace        "k8s")
(declare-function eltainer-switch-kubeconfig "eltainer")
(declare-function k8s-dispatch             "k8s")

;; IMPORTANT: don't use `defvar-keymap' here — it's a one-shot
;; `defvar' that no-ops on re-eval, so a reload that adds keys to
;; common-map would never see them on the existing keymap object.
;; Plain `defvar' + idempotent `keymap-set' calls (which re-run on
;; every load) is the reload-safe pattern.
(defvar k8s-common-map (make-sparse-keymap)
  "Bindings shared by every k8s view mode (pods, nodes, deployments, …).
Each view's mode-map sets this as its `:parent', so editing the
list below and reloading propagates automatically — no copy step,
no load-order surprise.")

(set-keymap-parent k8s-common-map magit-section-mode-map)

(pcase-dolist
    (`(,key ,cmd)
     '(("RET"   k8s-dwim-ret)
       ("d"     k8s-delete-at-point)
       ("i"     k8s-describe)
       ("w"     k8s-watch-toggle)
       ("N"     k8s-set-namespace)
       ("b"     eltainer-switch-kubeconfig)
       ("?"     k8s-dispatch)
       ("g"     revert-buffer)
       ("q"     quit-window)
       ;; dired-style marks
       ("m"     k8s-mark)
       ("u"     k8s-unmark)
       ("U"     k8s-unmark-all)
       ("t"     k8s-toggle-marks)
       ("DEL"   k8s-unmark-backward)
       ;; Dired also accepts `M-DEL', `* !', `* ?' for "unmark all";
       ;; we only have one mark character so they collapse together.
       ("M-DEL" k8s-unmark-all)
       ("* !"   k8s-unmark-all)
       ("* ?"   k8s-unmark-all)))
  (keymap-set k8s-common-map key cmd))

(provide 'k8s-marks)
;;; k8s-marks.el ends here
