;;; test-net.el --- Tests for the shared DNS-lookup chain -*- lexical-binding: t -*-
;;
;; `eltainer-net-lookup-dns' takes a RUN-FN that's supposed to be a
;; backend-specific exec closure.  Stubbing RUN-FN lets us verify the
;; fall-back order, the success path, and the all-fail diagnostic
;; without any container around.

(require 'ert)
(require 'eltainer-net)

(defun test-net--stub (responses)
  "Return a RUN-FN that returns a fresh entry from RESPONSES per call.
Each entry is a `(EXIT-CODE . STDOUT)' cons.  When RESPONSES runs
out subsequent calls return `(127 . \"command not found\")'."
  (let ((tail responses))
    (lambda (_argv)
      (if tail
          (prog1 (car tail) (setq tail (cdr tail)))
        (cons 127 "command not found")))))

(ert-deftest net/dns-getent-success-short-circuits ()
  "If the first probe (`getent') wins, the chain stops there."
  (let* ((called 0)
         (run-fn (lambda (_argv)
                   (cl-incf called)
                   (cons 0 "10.0.0.1 host.example\n")))
         (result (eltainer-net-lookup-dns run-fn "host.example")))
    (should (equal "getent" (eltainer-net-dns-result-tool result)))
    (should (string-match-p "10\\.0\\.0\\.1" (eltainer-net-dns-result-output result)))
    (should (= 1 called))))

(ert-deftest net/dns-falls-back-to-nslookup ()
  "Getent missing (exit 127) -> nslookup gets the call."
  (let* ((run-fn (test-net--stub
                  '((127 . "getent: not found")
                    (0 . "Server: 1.2.3.4\nName: host.example\n"))))
         (result (eltainer-net-lookup-dns run-fn "host.example")))
    (should (equal "nslookup" (eltainer-net-dns-result-tool result)))
    (should (string-match-p "Server" (eltainer-net-dns-result-output result)))))

(ert-deftest net/dns-falls-back-to-resolv-conf ()
  "Both getent + nslookup missing -> dump resolv.conf + hosts."
  (let* ((run-fn (test-net--stub
                  '((127 . "no getent")
                    (127 . "no nslookup")
                    (0 . "== /etc/resolv.conf ==\nnameserver 1.1.1.1\n"))))
         (result (eltainer-net-lookup-dns run-fn "host.example")))
    (should (equal "resolv-conf-fallback"
                   (eltainer-net-dns-result-tool result)))
    (should (string-match-p "nameserver"
                            (eltainer-net-dns-result-output result)))))

(ert-deftest net/dns-all-fail-distroless-message ()
  "Every probe failing returns the friendly distroless diagnostic."
  (let* ((run-fn (test-net--stub
                  '((127 . "") (127 . "") (127 . ""))))
         (result (eltainer-net-lookup-dns run-fn "host.example")))
    (should (equal "unresolved" (eltainer-net-dns-result-tool result)))
    (should (string-match-p "distroless"
                            (eltainer-net-dns-result-output result)))))

(ert-deftest net/dns-format-buffer ()
  "`eltainer-net-format-dns-buffer' produces a tidy multi-line string."
  (let* ((result (eltainer-net-dns-result--new
                  :tool "getent" :output "10.0.0.1 foo.example\n"))
         (text (eltainer-net-format-dns-buffer
                "k8s:default/log-ticker" "foo.example" result)))
    (should (string-match-p "DNS lookup from k8s:default/log-ticker" text))
    (should (string-match-p "for foo.example" text))
    (should (string-match-p "via getent" text))
    (should (string-match-p "10\\.0\\.0\\.1" text))))

(provide 'test-net)
;;; test-net.el ends here
