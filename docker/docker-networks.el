;;; docker-networks.el --- Docker network listing & manipulation -*- lexical-binding: t -*-
;;
;; List networks, inspect their connected members, and connect or
;; disconnect containers.  Uses the Docker CLI via docker-api.el.
;;
;; Usage:
;;   (docker-list-networks cfg)
;;   (docker-inspect-networks cfg '("bridge" "my-app-net"))
;;   (docker-network-connect cfg "my-app-net" "my-container")
;;   (docker-network-disconnect cfg "my-app-net" "my-container")

(require 'cl-lib)
(require 'json)
(require 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Data model

(cl-defstruct (docker-network (:constructor docker-network--new) (:copier nil))
  "A Docker network summary (from `docker network ls')."
  id name driver scope created-at)

(cl-defstruct (docker-network-member (:constructor docker-network-member--new) (:copier nil))
  "A container connected to a network."
  network-name container-id container-name ipv4 ipv6)

(cl-defstruct (docker-network-detail (:constructor docker-network-detail--new) (:copier nil))
  "Detailed network info (from `docker network inspect')."
  id name driver scope subnet gateway internal members)

;;; ---------------------------------------------------------------------------
;;; Listing

(defun docker-list-networks (cfg)
  "Return a vector of `docker-network' structs via GET /networks."
  (let ((data (docker-engine-get cfg "/networks")))
    (vconcat
     (mapcar (lambda (j)
               (docker-network--new
                :id (alist-get 'Id j)
                :name (alist-get 'Name j)
                :driver (alist-get 'Driver j)
                :scope (alist-get 'Scope j)
                :created-at (alist-get 'Created j)))
             data))))

(defun docker-inspect-networks (cfg names)
  "Inspect networks NAMES in parallel.  Returns a list of
`docker-network-detail' (same order as NAMES; nil entries dropped).

The Docker Engine `/networks' list endpoint omits the `Containers'
field, so a per-network `/networks/{id}' GET is the only way to
get the connected-containers detail.  Each call is independent —
fan them out via `docker-http-fan-out-sync' instead of the old
serial loop, turning N×latency into one round-trip's worth."
  (when names
    (let* ((prefix (docker--api-prefix cfg))
           (specs (mapcar
                   (lambda (name)
                     (let ((path (concat prefix (format "/networks/%s" name))))
                       (lambda (cb)
                         (docker-http-get-async
                          cfg path
                          (lambda (body)
                            (funcall cb
                                     (and body (> (length body) 0)
                                          (ignore-errors
                                            (json-parse-string
                                             body
                                             :object-type 'alist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object :false)))))))))
                   names))
           (raws (docker-http-fan-out-sync specs)))
      (delq nil
            (mapcar (lambda (d) (and d (docker--network-detail-from-json d)))
                    raws)))))

(defun docker-inspect-network-json (cfg name)
  "Return the raw /networks/NAME alist (for the inspect view)."
  (condition-case nil
      (docker-engine-get cfg (format "/networks/%s" name))
    (docker-api-error nil)))

(defun docker--network-detail-from-json (d)
  "Build a `docker-network-detail' from one inspect entry D."
  (let* ((ipam (cdr (assq 'IPAM d)))
         (cfg-list (cdr (assq 'Config ipam)))
         (first (when cfg-list (car cfg-list)))
         (containers (cdr (assq 'Containers d)))
         (name (cdr (assq 'Name d)))
         (members
          (mapcar (lambda (e)
                    (let* ((cid (symbol-name (car e)))
                           (m (cdr e)))
                      (docker-network-member--new
                       :network-name name
                       :container-id cid
                       :container-name (cdr (assq 'Name m))
                       :ipv4 (cdr (assq 'IPv4Address m))
                       :ipv6 (cdr (assq 'IPv6Address m)))))
                  containers)))
    (docker-network-detail--new
     :id (cdr (assq 'Id d))
     :name name
     :driver (cdr (assq 'Driver d))
     :scope (cdr (assq 'Scope d))
     :subnet (and first (cdr (assq 'Subnet first)))
     :gateway (and first (cdr (assq 'Gateway first)))
     :internal (eq t (cdr (assq 'Internal d)))
     :members members)))

;;; ---------------------------------------------------------------------------
;;; Mutating actions

(defun docker-network-connect (cfg network container)
  "Connect CONTAINER to NETWORK via POST /networks/NETWORK/connect."
  (condition-case _err
      (progn (docker-engine-post cfg (format "/networks/%s/connect" network)
                                 :json `((Container . ,container)))
             t)
    (docker-api-error nil)))

(defun docker-network-disconnect (cfg network container)
  "Disconnect CONTAINER from NETWORK via POST /networks/NETWORK/disconnect."
  (condition-case _err
      (progn (docker-engine-post cfg (format "/networks/%s/disconnect" network)
                                 :json `((Container . ,container)))
             t)
    (docker-api-error nil)))

(defun docker-remove-network (cfg name)
  "Remove network NAME via DELETE /networks/NAME."
  (condition-case _err
      (progn (docker-engine-delete cfg (format "/networks/%s" name)) t)
    (docker-api-error nil)))

(provide 'docker-networks)
;;; docker-networks.el ends here
