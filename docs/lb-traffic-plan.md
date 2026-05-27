# Plan: ingress / egress traffic per load balancer

Status: **proposal** — review before coding.

## Goal

Show how much traffic is flowing through each load balancer in the
cluster — bytes per second in / out, with a short history sparkline
and a per-port breakdown.  "Load balancer" here means a K8s
`Service` (any type — ClusterIP / NodePort / LoadBalancer / headless)
or an `Ingress` plus its controller.

UX target: a `IN/s   OUT/s` pair of columns in the Services view, an
`M`-key per-Service metrics buffer with sparklines, and an analogous
per-Ingress breakdown (measured at the ingress controller's pods).
All read-only.  Existing infrastructure (kubelet Summary API +
optional Prometheus) supplies the bytes.

## 1. What "traffic through a load balancer" actually is

The wire reality on Linux + Kubernetes:

- **`ClusterIP` Service**: a VIP that kube-proxy DNATs to a backing
  pod IP.  The "load balancer" is iptables / IPVS rules in the kernel;
  no separate device.  Traffic counters that count it are at the pod
  network interface (kubelet Summary) or at the kernel
  (`/proc/net/dev`, cAdvisor's `container_network_*`).
- **`NodePort`**: ClusterIP + a port reservation on every node.
  Same backing-pod traffic; the node-port hop just gets the packet to
  some pod somewhere.
- **`LoadBalancer`**: NodePort + an external L4 device (cloud-managed
  or MetalLB).  The cloud LB has its own counters (CloudWatch, GCP
  monitoring) but those are out of scope for a CLI tool — and the
  backing pods still see every byte that gets DNAT'd to them.
- **`Ingress`**: NOT a kernel construct.  An L7 reverse proxy
  (ingress-nginx, traefik, …) running as pods in the cluster decodes
  HTTP and forwards to backend Services.  The "load balancer" for an
  Ingress is the controller pod set; its network counters carry the
  signal.
- **Headless Service** (clusterIP=None): no kube-proxy, no VIP.
  Clients hit pod IPs directly via DNS.  Pod network counters still
  measure correctly, even though there's no proxy.

**Implication.**  For every K8s "load balancer" shape we care about,
the *backing pods'* network counters carry the right answer.  We do
not need to scrape any LB-device-specific metrics endpoint.  This
keeps the design uniform.

Counter caveats:

- A pod behind multiple Services will overcount (counters can't
  attribute by destination Service).  Acceptable — the common case
  is 1 Service → 1 deployment.
- Pods doing outbound traffic to non-Service destinations
  (`crond`-driven backups, telemetry pushes) get folded into the
  egress number.  We surface this in the docs; it matches what
  `kubectl top` / cloud monitoring would show.

## 2. Bytes sources we already have

`k8s/k8s-metrics.el:233` (`k8s-metrics--summary-network`) already
pulls per-pod `network.{rxBytes, txBytes}` from the kubelet Summary
API on the polling tick.  `k8s-metrics-net-sample` keeps a short
history per pod for the sparkline in the per-pod metrics buffer.

`k8s/k8s-prom.el:175` (`k8s-prom-query`) and
`k8s-prom-query-range` give us PromQL when Prometheus is in the
cluster.  We discover Prometheus via the `app.kubernetes.io/name`
label and proxy queries through the API server — no extra
configuration on the user's side.

Both already work; both already feed the Nodes view and the per-pod
M buffer.  This plan extends them to a new aggregation level
(Service → its backing pods).

## 3. Module layout

One new file, one extended one:

- **`k8s/k8s-traffic.el`** *(new)* — the aggregation + sparkline +
  rendering layer specific to "traffic through a load balancer".
  Public API:
  - `k8s-traffic-poll CONN NS` — fetches one tick of Summary for
    every pod in NS, returns a hash `service-name -> (RX-RATE
    TX-RATE BACKING-POD-COUNT)`.
  - `k8s-traffic-history-record CACHE SERVICE-KEY RATES` — folds
    one tick into the per-Service history ring used for sparklines.
  - `k8s-traffic-prom-rate-for-service CONN SVC` — when
    `k8s-prom-available-p', uses `rate(container_network_*[1m])`
    grouped by the Service's selector.  Falls back to the Summary
    path on Prometheus miss / 404.
- **`k8s/k8s.el`** — `k8s--insert-service-line` gains two new
  columns: `IN/s` and `OUT/s`.  Right-aligned; defaults to
  human-friendly KB/MB/GB (`eltainer-ui-bytes-rate` — small new
  helper).
- **`k8s/k8s.el`** — `?` dispatch on a Service row offers
  "Traffic" as an action; `M` on a Service opens the buffer too.

## 4. Service → backing pods resolution

Already done as `k8s--label-selector-for-resource'
(`k8s/k8s.el:1321`).  For a Service:

```elisp
(cdr (assq 'selector (cdr (assq 'spec service))))
```

Yields an alist like `((app . "podinfo") (tier . "frontend"))`.
Convert to a labelSelector string, hit
`/api/v1/namespaces/NS/pods?labelSelector=...` — we have
`k8s-list-pods-by-selector' for this exact case.  Cache the result
on the polling tick (5–30 s).

Edge cases:
- **Headless `clusterIP: None`** — same selector logic works.
- **Selectorless Services** — paired with an explicit Endpoints
  object.  Resolve via `GET /endpoints/NAME`.  v1: render `—`, defer
  to v2.
- **ExternalName Service** — DNS CNAME; no pods; render `—`.

## 5. Per-service M buffer

`M` on a Service row → `*k8s:traffic:NS/NAME*`.

Contents (modeled on the per-pod M buffer):

```
Service:   bookstore/bookstore-api
Type:      ClusterIP   Selector: app=bookstore-api,tier=api
Ports:     80→8080/TCP   443→8443/TCP

  IN/s       1.2 MB/s   ▁▂▃▆▇▅▄▃▂▁
  OUT/s    420.5 KB/s   ▁▁▂▂▃▄▃▂▂▁

Backing pods (3):
  bookstore-api-6f4-abc   3.2 MB/s in   ▁▂▃▄▅
  bookstore-api-6f4-def   1.1 MB/s in   ▁▁▂▃▃
  bookstore-api-6f4-ghi   0.8 MB/s in   ▁▁▁▂▂
```

`g` re-polls; `q` quits.  Polling timer shared with the existing
per-pod metrics ticker so we don't double-fetch the Summary.

## 6. Ingresses view: same shape

The Ingresses view already shows backend lines (`bookstore.local/api
→ bookstore-api:80`) that today jump to the Service.  For traffic:

- Each Ingress row gets an `IN/s` column showing aggregate ingress-
  controller bandwidth attributable to *all* ingresses on that
  controller (we can't split per Ingress without scraping the
  controller's metrics endpoint — see §8 for the fast-path).
- `M` on an Ingress opens an analogous buffer that lists the
  controller's pods + their network rates.

Identifying the controller's pods: by the Ingress's
`ingressClassName`, look up the `IngressClass` resource, follow its
`spec.controller` field's convention (typically points at a
deployment in `ingress-nginx` / `traefik` / `kube-system`).  v1:
look in the same namespace for a Service labelled
`app.kubernetes.io/name=ingress-nginx-controller` etc., with a small
hardcoded alist for the common controllers.

## 7. Sparkline + rate math

Already worked out for the per-pod buffer
(`k8s/k8s-metrics.el:316` `k8s-metrics--net-history`):

- Keep last N (default 30) samples in a ring buffer.
- Rate = `(byte_now - byte_prev) / (t_now - t_prev)`.
- Counter reset (a value smaller than the previous sample) ⇒ discard
  that delta — pod was restarted, the counter went back to 0.

Reuse `eltainer-gauge--sparkline` for the rendering.

## 8. Prometheus fast-path (optional, when available)

When `k8s-prom-available-p`, prefer:

```promql
sum by (service) (
  rate(container_network_receive_bytes_total{namespace="bookstore"}[1m])
  * on(namespace, pod) group_left(service)
  kube_pod_info{namespace="bookstore"}
  # join via a kube-state-metrics relation
)
```

Prometheus already does all the bookkeeping (counter resets,
restarts, per-container interface counters).  We trade one PromQL
query for `N pods` of Summary parsing.  On clusters without
kube-state-metrics, fall back to the Summary path.

This is an enhancement, not a v1 requirement — the Summary path
works everywhere kubelet does.

## 9. Docker side (deferred, sketch only)

In Docker, a "load balancer" is just a container running nginx /
haproxy / traefik / etc.  Per-container network counters from
`GET /containers/{id}/stats` already feed the per-container metrics
buffer (`M` in the docker containers view).  The K8s "Service →
backing pods" aggregation has no docker analog — Docker users
typically point clients at a single container's exposed port.

If we ever want a Docker-level Traffic view, the right shape is
probably "containers labelled `eltainer.role=loadbalancer` get a
dedicated row" — same `M` buffer machinery, no new metrics source.
Defer to a follow-up plan once anyone asks.

## 10. Rollout / order of work

1. **`eltainer-ui-bytes-rate`** helper (eltainer-ui.el) — render
   bytes/second as `KB/s` / `MB/s` / `GB/s` with one significant
   digit.  Small + foundational; one defun, one test.
2. **`k8s-traffic.el` poll layer** — selector resolution, summary
   fetch, history ring.  Pure function; unit-testable against
   recorded Summary JSON (no live cluster needed).
3. **`k8s--insert-service-line` columns** — wire in `IN/s` / `OUT/s`.
   Behind a `k8s-services-show-traffic` defcustom (default `t`).
4. **`k8s-traffic-buffer-for-service`** + `M`-key binding.  Reuses
   the sparkline renderer.
5. **Polling ticker** — fold the Service-aggregate poll into the
   existing per-pod metrics tick to share the Summary HTTP cost.
6. **Ingresses analog** — controller-pod resolution + IN/s column +
   `M` buffer.  Smaller scope: controller identification is the only
   new bit.
7. **Prometheus fast-path** — `k8s-prom`-backed query when
   available, fall back to Summary aggregation when not.
8. **Tests** — fixture-driven against a recorded Summary blob;
   selector → pod-names resolution; rate arithmetic with a counter-
   reset case.
9. **NEWS entry + README** — document the columns + `M` action.

## 11. Risks / open questions

- **Counter attribution.**  Pod network counters are per-interface,
  not per-conversation.  A pod behind two Services has its rx/tx
  split between them — we can't tell from the kubelet which Service's
  traffic that is.  Document the limitation; it's the same limitation
  as `kubectl top` and friends.
- **Polling cost.**  Each tick already hits the Node's `/stats/
  summary` endpoint once per node.  No new HTTP — the aggregation is
  purely client-side over the already-cached payload.  Good.
- **Service selector mismatch.**  If a pod gets its labels rewritten
  mid-poll (rolling update), it may show up in 0 selectors during the
  window between deletion and the new pod becoming ready.  Doesn't
  matter for cumulative correctness — the rate just drops to 0 for a
  tick.
- **Selectorless Services.**  Resolving via Endpoints is a second API
  call per render.  Cache per-poll.  v1 renders `—` and skips them.
- **Localised LB ingress controllers we miss.**  Custom controllers
  (Contour, Kong CE, custom CRD-driven) won't be picked up by our
  hardcoded controller-discovery alist.  Surface "controller pods
  unknown" in the Ingress's `M` buffer and link to a
  `defcustom k8s-traffic-controller-selectors` for users to register
  their own.
