# Eltainer dev helpers.  Most of the time you just want `make clean'
# to wipe stale .elc files before a fresh byte-compile (the user
# normally byte-compiles via `M-x eltainer-reload' from inside Emacs).

.PHONY: clean compile test test-unit test-all audit-keys help

help:
	@echo "make clean       - delete every .elc file in the tree"
	@echo "make compile     - clean + byte-compile every .el file"
	@echo "make test        - run pure-elisp unit tests (no daemon / cluster)"
	@echo "make test-all    - run everything, including live-daemon /"
	@echo "                   live-cluster integration tests"
	@echo "make audit-keys  - print the keymap construction + cross-mode"
	@echo "                   drift report (see docs/keymap-audit.md)"

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

# Pure-elisp tests — no docker daemon, no kubeconfig required.
# Loads only the top-level `test/test-*.el' files (skipping the
# subdirectory integration suites).
test:
	@ELTAINER_TEST_MODE=unit emacs -Q --batch -l test/run-tests.el

# Everything, including the live-daemon (test/docker/) and live-cluster
# (test/k8s/) integration tests.  Skips individual tests cleanly when
# the daemon / cluster isn't reachable; doesn't fail the whole suite.
test-all:
	@ELTAINER_TEST_MODE=integration emacs -Q --batch -l test/run-tests.el

# Keymap audit: loads every module, walks every *-mode-map, prints a
# construction-pattern survey + per-map binding list + cross-mode
# drift table.  Curated read of the output lives in
# `docs/keymap-audit.md`.
audit-keys:
	@emacs -Q --batch \
	  --eval "(dolist (d '(\".\" \"docker\" \"k8s\" \"test\")) (add-to-list 'load-path (expand-file-name d)))" \
	  --eval "(dolist (p (and (file-directory-p \"~/.emacs.d/elpa\") (directory-files \"~/.emacs.d/elpa\" t \"^[a-z]\"))) (when (file-directory-p p) (add-to-list 'load-path p)))" \
	  --eval "(dolist (d '(\".\" \"docker\" \"k8s\")) (dolist (f (directory-files (expand-file-name d) t \"\\\\.el\\\\'\")) (let ((feat (intern (file-name-base f)))) (unless (memq feat '(reload eltainer-news)) (ignore-errors (require feat f))))))" \
	  --eval "(require 'keymap-audit)" \
	  --eval "(keymap-audit-print \".\")"
