;;; eltainer-net.el --- Shared network primitives for container backends -*- lexical-binding: t -*-
;;
;; Network-related operations that ride on top of the docker / k8s
;; sync-exec primitives.  Today: a DNS-lookup chain (`getent hosts'
;; -> `nslookup' -> fall back to dumping `/etc/resolv.conf' +
;; `/etc/hosts').  Future home for port-forward helpers, curl-style
;; HTTP probes, etc.
;;
;; The caller passes ONE closure (RUN-FN) that runs an argv inside
;; the target container and returns a `(EXIT-CODE . STDOUT)' cons.
;; Both backends already have a sync-exec primitive — three lines of
;; wrapping each.  Keeps this module backend-agnostic.

(require 'cl-lib)

(defgroup eltainer-net nil
  "Shared network primitives for container-side ops."
  :group 'eltainer
  :prefix "eltainer-net-")

(cl-defstruct (eltainer-net-dns-result
               (:constructor eltainer-net-dns-result--new)
               (:copier nil))
  "Result of `eltainer-net-lookup-dns'.
TOOL is the tool that produced OUTPUT (\"getent\", \"nslookup\", or
\"resolv-conf-fallback\")."
  tool
  output)

(defconst eltainer-net--dns-probes
  '(("getent"               . ("getent" "hosts" "%s"))
    ("nslookup"             . ("nslookup" "%s"))
    ("resolv-conf-fallback" . ("sh" "-c"
                               "echo '== /etc/resolv.conf =='; \
cat /etc/resolv.conf 2>/dev/null; \
echo; echo '== /etc/hosts =='; cat /etc/hosts 2>/dev/null")))
  "Probe chain for `eltainer-net-lookup-dns', in fall-back order.
Each entry is `(TOOL-NAME . ARGV-TEMPLATE)'.  `%s' in argv is
substituted with the hostname.  The resolv-conf-fallback entry
takes no hostname substitution but is still useful — at minimum
the caller sees what the container thinks DNS is.")

(defun eltainer-net--substitute (argv host)
  "Return ARGV with each `%s' element substituted with HOST."
  (mapcar (lambda (a) (if (string-match-p "%s" a) (format a host) a)) argv))

(defun eltainer-net-lookup-dns (run-fn host)
  "Resolve HOST inside the container described by RUN-FN.

RUN-FN is `(lambda (ARGV) (cons EXIT-CODE STDOUT))' — runs an argv
in the container synchronously.  The caller closes over its own
backend-specific exec function.

Tries each entry in `eltainer-net--dns-probes' in order, returning
the first one with EXIT-CODE 0 as an `eltainer-net-dns-result'.
If every probe fails (binary missing / no shell — typical
distroless), returns an `eltainer-net-dns-result' with TOOL =
\"unresolved\" and OUTPUT carrying a diagnostic message."
  (cl-loop for (tool . argv-tpl) in eltainer-net--dns-probes
           for argv = (eltainer-net--substitute argv-tpl host)
           for result = (condition-case _err
                            (funcall run-fn argv)
                          (error nil))
           for exit = (car-safe result)
           for stdout = (cdr-safe result)
           when (eql exit 0)
           return (eltainer-net-dns-result--new
                   :tool tool :output (or stdout ""))
           finally return
           (eltainer-net-dns-result--new
            :tool "unresolved"
            :output (format
                     "eltainer-net: every DNS probe failed for %s — \
container has no `getent', no `nslookup', and no shell (likely a \
distroless or scratch image).  Use `kubectl debug --image=busybox' \
or its docker equivalent."
                     host))))

(defun eltainer-net-format-dns-buffer (title host result)
  "Format the contents for a DNS-lookup result buffer.
TITLE describes the container (e.g. `default/log-ticker' or
`docker:eltainer-ticker'); HOST is the hostname queried; RESULT is
the `eltainer-net-dns-result' from `eltainer-net-lookup-dns'."
  (let ((tool   (eltainer-net-dns-result-tool result))
        (output (eltainer-net-dns-result-output result)))
    (format "DNS lookup from %s for %s\nvia %s:\n\n%s"
            title host tool
            (if (string-empty-p output) "(no output)" output))))

(provide 'eltainer-net)
;;; eltainer-net.el ends here
