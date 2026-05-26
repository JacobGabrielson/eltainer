;;; test-age-face.el --- Tests for the age-tier face dispatcher -*- lexical-binding: t -*-

(require 'ert)
(require 'eltainer-ui)

(defun test-age-face--iso (secs-ago)
  "Return an ISO-8601 timestamp SECS-AGO seconds in the past."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (time-subtract (current-time) secs-ago) t))

(ert-deftest age-face/tiers ()
  "Each tier maps to its own face; boundaries pick the lower-age tier."
  (should (eq 'eltainer-age-very-new
              (eltainer-ui-age-face (test-age-face--iso 30))))      ; 30s
  (should (eq 'eltainer-age-very-new
              (eltainer-ui-age-face (test-age-face--iso 1800))))    ; 30m
  (should (eq 'eltainer-age-new
              (eltainer-ui-age-face (test-age-face--iso 4000))))    ; ~1h+
  (should (eq 'eltainer-age-medium
              (eltainer-ui-age-face (test-age-face--iso 90000))))   ; ~1d+
  (should (eq 'eltainer-age-old
              (eltainer-ui-age-face (test-age-face--iso 700000))))  ; ~8d
  (should (eq 'eltainer-age-ancient
              (eltainer-ui-age-face (test-age-face--iso 3000000))))) ; ~35d

(ert-deftest age-face/nil-timestamp-falls-back ()
  "A nil timestamp returns the generic dim face, not an error."
  (should (eq 'eltainer-dim (eltainer-ui-age-face nil))))

(ert-deftest age-face/render-is-propertised ()
  "`eltainer-ui-age-render' returns a string with the right
`font-lock-face' property already attached."
  (let* ((iso (test-age-face--iso 30))
         (rendered (eltainer-ui-age-render iso)))
    (should (stringp rendered))
    (should (eq 'eltainer-age-very-new
                (get-text-property 0 'font-lock-face rendered)))))

(provide 'test-age-face)
;;; test-age-face.el ends here
