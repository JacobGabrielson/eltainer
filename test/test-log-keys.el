;;; test-log-keys.el --- Tests for log-view key bindings -*- lexical-binding: t -*-
;;
;; Regression: every log-view keymap must have `p' bound to
;; `previous-line', and (in views that support pause) `P' must be the
;; pause toggle.  We don't enter the modes (avoiding socket setup) —
;; just look up keys on the static maps.

(require 'ert)
(require 'docker-logs)
(require 'k8s-multilog)
(require 'k8s-pods)

(ert-deftest log-keys/multilog-p-is-previous-line ()
  "Regression: `p' must navigate, not toggle pause."
  (should (eq #'previous-line
              (keymap-lookup k8s-multilog-mode-map "p")))
  (should (eq #'next-line
              (keymap-lookup k8s-multilog-mode-map "n")))
  (should (eq #'k8s-multilog-pause-toggle
              (keymap-lookup k8s-multilog-mode-map "P"))))

(ert-deftest log-keys/docker-logs-p-not-shadowed ()
  "`p' must NOT be bound on `docker-logs-mode-map' or its parent
chain — that lets the global-map `previous-line' binding through."
  (should-not (keymap-lookup docker-logs-mode-map "p")))

(ert-deftest log-keys/k8s-log-p-not-shadowed ()
  "Same for the single-pod log mode."
  (should-not (keymap-lookup k8s-log-mode-map "p")))

(provide 'test-log-keys)
;;; test-log-keys.el ends here
