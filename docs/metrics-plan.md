# Plan: container / pod metrics with minimalist gauges

Status: **proposal** — nothing here is implemented yet.  This document
is the design to review before writing code.

## Goal

Show live resource usage — CPU, memory, and (later) disk — for
containers, pods, and nodes in the eltainer k8s views, rendered as
compact text gauges.  No new package dependencies: pure-Elisp parsing,
the existing `docker-http` transport, text + faces for the gauges.

## 1. Where the numbers come from

### CPU + memory — `metrics.k8s.io` (metrics-server)

metrics-server is already enabled on both dev clusters.  It serves an
aggregated API the normal `docker-http` path can hit:

| Endpoint | Yields |
|----------|--------|
| `GET /apis/metrics.k8s.io/v1beta1/namespaces/{ns}/pods/{pod}` | one `PodMetrics` |
| `GET /apis/metrics.k8s.io/v1beta1/namespaces/{ns}/pods` | all `PodMetrics` in a namespace |
| `GET /apis/metrics.k8s.io/v1beta1/pods` | all `PodMetrics`, all namespaces |
| `GET /apis/metrics.k8s.io/v1beta1/nodes` | per-node `NodeMetrics` |

`PodMetrics.containers[]` carries `{name, usage:{cpu, memory}}`.
Usage values are **resource-quantity strings** (`"123456789n"`,
`"218Mi"`).

The API may be absent (no metrics-server) — treat a 404 on the
`metrics.k8s.io` group as "metrics unavailable" and degrade gracefully
(show a one-line "metrics-server not installed" note, no gauges).

### The denominator — pod spec requests / limits

Usage alone isn't a gauge; a gauge needs a 0..1 fraction.  The
denominator, per container, in priority order:

1. `spec.containers[].resources.limits.{cpu,memory}` — the hard cap.
2. `spec.containers[].resources.requests.{cpu,memory}` — the
   scheduled reservation, if no limit is set.
3. Node allocatable (`NodeMetrics` / node `status.allocatable`) — a
   rough fallback so a limitless container still shows *something*.

The pod spec is already in hand (the pods view holds the full pod
alist), so 1 and 2 cost nothing extra.

Render notes alongside the gauge so the basis is never ambiguous:
`62%  124m / 200m (limit)` vs `… (request)` vs `… (node)`.

### Disk — deferred to phase 2

`metrics.k8s.io` does **not** expose filesystem usage.  Per-container
ephemeral-storage usage lives in the kubelet Summary API:

`GET /api/v1/nodes/{node}/proxy/stats/summary`
→ `.pods[].containers[].rootfs.usedBytes`, `.ephemeral-storage`.

This works but is heavier: per-node, needs `nodes/proxy` RBAC, and the
shape is less stable than `metrics.k8s.io`.  **Phase 1 ships CPU +
memory only.**  Phase 2 adds disk; until then the detail line can show
the static `resources.{requests,limits}."ephemeral-storage"` from the
spec (no gauge, just the numbers) if they're set.

## 2. Parsing resource quantities

Two small pure-Elisp parsers (new file `k8s/k8s-metrics.el`):

- `k8s-metrics--parse-cpu` → millicores (float).
  Suffixes: `n` ×1e-6, `u` ×1e-3, `m` ×1, none ×1000.
  `"250m"` → 250.0, `"1"` → 1000.0, `"123456789n"` → ~123.5.

- `k8s-metrics--parse-memory` → bytes (integer).
  Binary `Ki/Mi/Gi/Ti/Pi` (×1024ⁿ), decimal `K/M/G/T/P` (×1000ⁿ),
  bare = bytes.  `"218Mi"` → 228589568.

Each returns nil on an unparseable string; callers treat nil as
"unknown" and skip the gauge.

## 3. The gauge — minimalist text rendering

A horizontal bar built from Unicode block elements, giving 1/8-cell
precision so a narrow gauge still reads smoothly.  No images, no
package — just a propertized string.

Eighth-blocks: `▏▎▍▌▋▊▉█` (1/8 … 8/8).  Empty cell = space.

```elisp
(defun k8s-metrics--gauge (fraction width)
  "Return a WIDTH-cell bar string for FRACTION (0.0..1.0)."
  (let* ((f      (max 0.0 (min 1.0 (or fraction 0.0))))
         (eighths (round (* f width 8)))
         (full   (/ eighths 8))
         (rem    (% eighths 8))
         (parts  ["" "▏" "▎" "▍" "▌" "▋" "▊" "▉"]))
    (concat (make-string full ?█)
            (unless (zerop rem) (aref parts rem))
            (make-string (max 0 (- width full (if (zerop rem) 0 1)))
                         ?\s))))
```

The bar is wrapped in thin end-caps (`▕`…`▏`) and given a face by
threshold:

| Fraction | Face | Colour |
|----------|------|--------|
| < 0.70   | `k8s-gauge-low`  | green  |
| 0.70–0.90 | `k8s-gauge-mid` | yellow |
| > 0.90   | `k8s-gauge-high` | red    |

A `defcustom k8s-metrics-gauge-width` (default 16) sizes it; a
`defcustom k8s-metrics-gauge-style` can offer an ASCII fallback
(`#`/`-`) for terminals/fonts without block glyphs.

### Mockup — inline in the expanded pod section

The pod's container rows already became `container` subsections (for
container-aware `l`/`e`/`f`).  Metrics add one indented line per
container under each:

```
  duo-box                          Running   2/2   0   12m   10.244.0.7
    Node:   eltainer-test-control-plane
    Containers:
      app          alpine:3.20            ready=yes  restarts=0
        cpu  ▕███████▍         ▏  74m / 200m   37% (limit)
        mem  ▕██████████▊      ▏ 218Mi / 256Mi  85% (limit)
      sidecar      busybox:1.37           ready=yes  restarts=0
        cpu  ▕█▏               ▏   3m / —        (no limit; node 0.4%)
        mem  ▕██▍              ▏  12Mi / —       (no limit)
```

### Mockup — node header / a dedicated metrics buffer

A fuller view (see §4) can stack pod and node gauges:

```
Node  eltainer-test-control-plane
  cpu  ▕████████████▏    ▏  1.9 / 4 cores   48%
  mem  ▕███████████████▎▏  6.1 / 7.8 GiB    78%
```

## 4. Where metrics surface

Two complementary surfaces:

1. **Inline, in the expanded pod section** — the gauges in the mockup
   above.  Cheap, always visible once you `TAB` a pod open.  This is
   phase 1.

2. **A dedicated metrics buffer** — `*k8s:metrics:{ns}/{pod}*` or a
   node-wide `*k8s:metrics*`, opened by a context command (§5).
   Bigger gauges, per-container breakdown, node totals, refreshes on
   its own timer.  Phase 1.5 / 2.

## 5. Surfacing it: context-aware commands

(Generalises beyond metrics — applies to delete, logs, exec, etc.)

Today the k8s view keymaps bind resource actions flatly and each
action calls `magit-current-section` then `user-error`s if it's the
wrong type.  Two improvements:

### 5a. Actions already guard — keep that

`k8s--pod+container-at-point` (just landed) and the existing
`magit-current-section` checks already make an action a no-op /
`user-error` when point isn't on the right resource.  Good — keep
every action defensively guarded.  "Delete" must refuse unless point
is genuinely on a deletable resource.

### 5b. `?` should show only the relevant actions

`k8s-dispatch` (the `?` transient) should present a layout tailored to
the section under point:

- on a **pod**     → Logs, Exec, Browse-fs, Describe, **Metrics**, Delete
- on a **container** → Logs, Exec, Browse-fs, **Metrics**
- on a **deployment** → Scale, Restart, Describe, Delete
- on **nothing**   → just the view-switch + navigation entries

`transient` supports this directly: every suffix / group takes an
`:if` predicate.  Define `k8s--section-type-at-point` and gate each
suffix:

```elisp
(transient-define-prefix k8s-dispatch ()
  [:if (lambda () (k8s--point-on-p 'pod))
   "Pod at point"
   ("l" "Logs"     k8s-pod-view-logs)
   ("e" "Exec"     k8s-pod-exec-at-point)
   ("f" "Browse"   k8s-pod-browse-at-point)
   ("M" "Metrics"  k8s-pod-metrics-at-point)
   ("D" "Delete"   k8s-delete-at-point)]
  [:if (lambda () (k8s--point-on-p 'container))
   "Container at point"
   ("l" "Logs"    k8s-pod-view-logs)
   ("e" "Exec"    k8s-pod-exec-at-point)
   ("M" "Metrics" k8s-pod-metrics-at-point)]
  [ "Views" ...always-shown... ])
```

So `?` becomes genuinely contextual — the same magit muscle memory
the project already commits to (see AGENT.md).  The plain keybindings
(`l`, `e`, `M`, …) stay bound globally in the view for users who skip
the menu; they keep their own at-point guards.

`M` (metrics) is the new entry; it opens the dedicated buffer of §4
for the pod/container under point.

## 6. Refresh cadence

metrics-server scrapes every ~15 s — fetching metrics on every
watch-driven pods refresh would be wasteful and slow the render.

- Keep a per-buffer cache: an alist/hash of `pod-uid → PodMetrics`
  plus a fetch timestamp.
- Refresh it on a dedicated timer (`k8s-metrics-refresh-interval`,
  default 15 s) and only while a `*k8s:pods*` / metrics buffer is
  live and displayed.
- The pods-view render reads the cache; a cache miss just omits the
  gauge that cycle.
- The dedicated metrics buffer runs its own timer while open.

This keeps metrics off the hot path of the existing event/watch
refresh.

## 7. New / changed files

| File | Change |
|------|--------|
| `k8s/k8s-metrics.el` | new — quantity parsers, gauge renderer, metrics fetch + cache, faces, `k8s-pod-metrics-at-point`, metrics buffer mode |
| `k8s/k8s-api.el` | add `k8s-pod-metrics` / `k8s-node-metrics` request helpers |
| `k8s/k8s-pods.el` | inline gauge lines under each container subsection |
| `k8s/k8s.el` | make `k8s-dispatch` context-aware (`:if` predicates); add `k8s--section-type-at-point` / `k8s--point-on-p` |
| `README.md` | document the metrics view + `M` |

## 8. Phasing

1. **Phase 1** — `k8s-metrics.el`: parsers, gauge, fetch+cache;
   inline CPU/mem gauges in the expanded pod section; graceful
   degradation when metrics-server is absent.
2. **Phase 1.5** — context-aware `k8s-dispatch`; `M` opens a
   dedicated per-pod metrics buffer.
3. **Phase 2** — disk usage via the kubelet Summary API; node-level
   metrics view.

## 9. Open questions

- Key for metrics in the pods view — `M` (`m` is taken by ConfigMaps
  on the dashboard, but inside the k8s view it could still be free;
  confirm against `k8s-pods-mode-map`).
- Inline gauges always on, or only when a pod section is expanded?
  (Lean: only when expanded — keeps the collapsed list compact.)
- Show sparthan-history (tiny trend sparkline) later?  Out of scope
  for now; the gauge helper could grow a `k8s-metrics--sparkline`
  sibling if wanted.
