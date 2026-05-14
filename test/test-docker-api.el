;;; test-docker-api.el --- Tests for docker-api -*- lexical-binding: t -*-

(require 'ert)
(require 'docker-api)
(require 'docker-config)

(ert-deftest docker-api-plain-command-info ()
  "`docker info' returns non-empty output."
  (let* ((cfg (docker-config-detect))
         (output (docker-plain-command cfg "info" "--format" "{{.ServerVersion}}")))
    (should output)
    (should (stringp output))
    (should (> (length output) 0))))

(ert-deftest docker-api-json-command-info ()
  "`docker info --format json' returns valid JSON."
  (let* ((cfg (docker-config-detect))
         (json (docker-json-command cfg "info" "--format" "{{json .}}")))
    (should json)))

(ert-deftest docker-api-failed-command ()
  "A non-existent docker command returns nil."
  (let* ((cfg (docker-config-detect))
         (result (docker-json-command cfg "nonexistent-command")))
    (should-not result)))

(ert-deftest docker-api-version-inspect ()
  "`docker version' returns version info."
  (let* ((cfg (docker-config-detect))
         (json (docker-json-command cfg "version" "--format" "{{json .}}")))
    (should json)))

(provide 'test-docker-api)
;;; test-docker-api.el ends here
