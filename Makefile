# Eltainer dev helpers.  Most of the time you just want `make clean'
# to wipe stale .elc files before a fresh byte-compile (the user
# normally byte-compiles via `M-x eltainer-reload' from inside Emacs).

.PHONY: clean compile help

help:
	@echo "make clean   - delete every .elc file in the tree"
	@echo "make compile - clean + byte-compile every .el file"

clean:
	@find . -name '*.elc' -type f -delete
	@echo "removed .elc files"

# Byte-compile every .el file from a fresh state.  Useful for
# CI-style sanity checks; the normal dev loop is M-x eltainer-reload.
compile: clean
	@emacs -Q --batch \
	  --eval "(dolist (d '(\".\" \"docker\" \"k8s\")) (add-to-list 'load-path (expand-file-name d)))" \
	  --eval "(dolist (p (directory-files \"~/.emacs.d/elpa\" t \"^[a-z]\")) (when (file-directory-p p) (add-to-list 'load-path p)))" \
	  --eval "(dolist (f (append (directory-files \".\" t \"\\\\.el\\\\'\") \
	                             (directory-files \"docker\" t \"\\\\.el\\\\'\") \
	                             (directory-files \"k8s\" t \"\\\\.el\\\\'\"))) \
	             (unless (string-match-p \"reload\\\\.el\\\\'\" f) (byte-compile-file f)))"
