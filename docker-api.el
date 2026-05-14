;;; docker-api.el --- Docker CLI wrapper -*- lexical-binding: t -*-
;;
;; Pure Elisp wrapper around the Docker CLI.  Uses `call-process' for
;; synchronous commands and `start-process' for asynchronous operations
;; (log tailing, exec).  All output parsing (JSON, plaintext) is pure
;; Elisp.
;;
;; Usage:
;;   (docker-command "ps" "--format" "{{json .}}")
;;   (docker-json-command docker-api-cfg "ps" "-a")
;;   (docker-async-command docker-api-cfg "logs" "-f" "my-container")

(require 'cl-lib)
(require 'json)
(require 'docker-config)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup docker-api nil
  "Docker CLI integration for eldocker."
  :prefix "docker-"
  :group 'docker)

(defcustom docker-cli-path "docker"
  "Path to the docker CLI executable."
  :type 'string
  :group 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Internal state

(defvar docker--last-exit-code 0
  "Exit code from the last synchronous docker command.")

;;; ---------------------------------------------------------------------------
;;; Synchronous commands

(defun docker-command (&rest args)
  "Run docker CLI synchronously with ARGS.  Return (EXIT-CODE . OUTPUT).
ARGS are strings passed to the docker executable."
  (let* ((path (or docker-cli-path "docker"))
         (exit-code 0)
         (output
          (with-temp-buffer
            (setq exit-code (apply #'call-process
                                   path nil t nil
                                   args))
            (buffer-string))))
    (setq docker--last-exit-code exit-code)
    (cons exit-code output)))

(defun docker-json-command (cfg &rest args)
  "Run docker CLI with ARGS, parse JSON output, return parsed alist.
CFG is a `docker-config' (used for TLS flags).
Returns nil on non-zero exit code."
  (let* ((tls-args (docker--tls-flags cfg))
         (all-args (append tls-args args))
         (result (apply #'docker-command all-args))
         (exit-code (car result))
         (output (cdr result)))
    (if (eq exit-code 0)
        (condition-case nil
            (with-temp-buffer
              (insert output)
              (goto-char (point-min))
              (let* ((json-object-type 'alist)
                     (json-array-type 'vector)
                     (json-key-type 'symbol))
                (json-read)))
          (error
           (message "docker-api: JSON parse failed: %s" (car (cdr args)))
           nil))
      (message "docker-api: command failed (exit %d): %s"
               exit-code (mapconcat #'prin1-to-string args " "))
      nil)))

(defun docker-ndjson-command (cfg &rest args)
  "Run docker CLI with ARGS expected to print one JSON object per line.
Return a list of parsed alists (empty on no output, nil on failure).
CFG is a `docker-config' (used for TLS flags)."
  (let* ((tls-args (docker--tls-flags cfg))
         (all-args (append tls-args args))
         (result (apply #'docker-command all-args))
         (exit-code (car result))
         (output (cdr result)))
    (if (eq exit-code 0)
        (let ((json-object-type 'alist)
              (json-array-type 'vector)
              (json-key-type 'symbol)
              objs)
          (dolist (line (split-string output "\n" t "[ \t\r\n]+"))
            (condition-case err
                (push (json-read-from-string line) objs)
              (error
               (message "docker-api: NDJSON parse failed on line %S: %s"
                        line (error-message-string err)))))
          (nreverse objs))
      (message "docker-api: command failed (exit %d): %s"
               exit-code (mapconcat #'prin1-to-string args " "))
      nil)))

(defun docker-plain-command (cfg &rest args)
  "Run docker CLI with ARGS, return stdout string (or nil on failure).
CFG is a `docker-config' (used for TLS flags)."
  (let* ((tls-args (docker--tls-flags cfg))
         (all-args (append tls-args args))
         (result (apply #'docker-command all-args))
         (exit-code (car result))
         (output (cdr result)))
    (if (eq exit-code 0)
        (when (> (length output) 0) output)
      (message "docker-api: command failed (exit %d): %s"
               exit-code (mapconcat #'prin1-to-string args " "))
      nil)))

;;; ---------------------------------------------------------------------------
;;; TLS flag helper

(defun docker--tls-flags (cfg)
  "Return TLS-related CLI flags for CFG, as a list of strings."
  (let (flags)
    (when (docker-config-tls-verify cfg)
      (push "--tlsverify" flags)
      (let ((ca (docker-config-tls-ca-cert cfg)))
        (when ca (push (concat "--tlscacert=" ca) flags)))
      (let ((cert (docker-config-tls-cert cfg)))
        (when cert (push (concat "--tlscert=" cert) flags)))
      (let ((key (docker-config-tls-key cfg)))
        (when key (push (concat "--tlskey=" key) flags))))
    (nreverse flags)))

;;; ---------------------------------------------------------------------------
;;; Async commands (process filters)

(defvar docker--async-processes nil
  "Hash table of active async docker processes: (PID . BUFFER).")

(defun docker-async-command (cfg buffer &rest args)
  "Run docker CLI async with ARGS, sending output to BUFFER.
CFG is a `docker-config' (used for TLS flags).
Returns the process object."
  (let* ((tls-args (docker--tls-flags cfg))
         (all-args (append tls-args args))
         (process (apply #'start-process
                         (format "docker-%s" (car (last args)))
                         buffer
                         (or docker-cli-path "docker")
                         all-args)))
    (set-process-coding-system process 'utf-8 'utf-8)
    process))

;;; ---------------------------------------------------------------------------
;;; Convenience: inspect

(defun docker-inspect (cfg name)
  "Inspect a Docker object named NAME.
Returns parsed JSON alist or nil on failure."
  (docker-json-command cfg "inspect" name))

;;; ---------------------------------------------------------------------------
;;; Error condition

(define-error 'docker-api-error "Docker API error")

(provide 'docker-api)
;;; docker-api.el ends here
