;;; test-jump-target.el --- Tests for cross-resource jump targets -*- lexical-binding: t -*-
;;
;; The `k8s-jump-target' text property is the mechanism for every
;; future cross-resource RET (Ingress -> Service today; Pod -> Node,
;; Service -> Endpoints, etc., later).  These tests cover:
;; - The property is attached to ingress backend lines correctly.
;; - `k8s--jump-to-target' dispatches on its CAR and tolerates
;;   unrecognised kinds without erroring.

(require 'ert)
(require 'magit-section)
(require 'k8s)

(defun test-jump-target--render-ingress (ing)
  "Render INGRESS in a temp buffer; return the buffer string."
  (with-temp-buffer
    (magit-section-mode)
    (let ((inhibit-read-only t)
          (magit-insert-section--current nil))
      (k8s--insert-ingress-line ing))
    (buffer-string)))

(defun test-jump-target--collect (string property)
  "Return the unique values of PROPERTY found anywhere in STRING."
  (let ((i 0) (n (length string)) seen)
    (while (< i n)
      (let ((v (get-text-property i property string)))
        (when v (cl-pushnew v seen :test #'equal)))
      (setq i (1+ i)))
    (nreverse seen)))

(defconst test-jump-target--ingress-fixture
  '((metadata . ((name . "bookstore-ingress")
                 (namespace . "bookstore")
                 (creationTimestamp . "2026-05-20T10:00:00Z")))
    (spec . ((ingressClassName . "nginx")
             (rules . [((host . "bookstore.local")
                        (http . ((paths . [((path . "/")
                                            (backend . ((service . ((name . "bookstore-frontend")
                                                                    (port . ((number . 80))))))))
                                           ((path . "/api")
                                            (backend . ((service . ((name . "bookstore-api")
                                                                    (port . ((number . 80))))))))]))))])))
    (status . ((loadBalancer . ((ingress . [((ip . "127.0.0.1"))])))))))

(ert-deftest jump-target/ingress-backend-lines-have-property ()
  "Both rendered backend rows must carry `k8s-jump-target' with the
ingress's namespace and the Service's name."
  (let* ((text (test-jump-target--render-ingress
                test-jump-target--ingress-fixture))
         (targets (test-jump-target--collect text 'k8s-jump-target)))
    (should (member '(service "bookstore" "bookstore-frontend") targets))
    (should (member '(service "bookstore" "bookstore-api") targets))
    (should (= 2 (length targets)))))

(ert-deftest jump-target/dispatch-unknown-kind-is-friendly ()
  "An unrecognised target kind should print a message, not crash."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (k8s--jump-to-target '(thingamabob foo bar))
      (should (string-match-p "don't know how to follow"
                              (car messages))))))

(provide 'test-jump-target)
;;; test-jump-target.el ends here
