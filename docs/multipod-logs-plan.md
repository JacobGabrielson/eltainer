# Plan: multi-pod log tailing for workloads

Status: **proposal** — review before coding.

## Goal

A [`stern`](https://github.com/stern/stern)-style multi-pod log tailer
built into eltainer.  `l` on a Deployment (and later StatefulSet /
DaemonSet / Job / Service) row opens a *single* buffer that follows
every selected pod's stdout/stderr, interleaved, with each pod colored
distinctly and line-prefixed.  Reuses eltainer's existing streaming
HTTP transport — no external `stern` binary, no `kubectl` shellout.

## Inspiration

- [`stern`](https://github.com/stern/stern) — the de-facto Go tool for
  this (multi-pod tail, colored by pod).
- `kubectl logs --prefix --selector=app=foo --all-containers -f`
  (native, less polished than stern).
- The user's "wercker-style" reference — Wercker (the early CI/CD
  platform Oracle acquired in 2017) had a build UI that showed
  parallel pipeline stages with color-coded interleaved logs.  Same
  visual pattern: many streams, one viewport, one color per source.

## 1. Trigger

`l` on each of these section types binds to a new
`k8s-<kind>-view-multilog-at-point` command:

- `deployment`  → tails pods owned by its current ReplicaSet
- `statefulset` → tails its pods (ordered `-0`, `-1`, …)
- `daemonset`   → tails its pods (one per node)
- `job`         → tails its pods (typically 1, may be parallel)
- `service`     → tails pods matching `spec.selector`

Mirrors the existing `k8s-cronjob-view-logs-at-point` pattern from
the recent CronJob-logs work.  Also surfaced in the `?`
context-aware dispatch when point is on one of those sections.

## 2. Pod resolution

Per kind:

- **Deployment** — derive labelSelector from
  `spec.selector.matchLabels`, list pods, filter to those owned by
  the *current* ReplicaSet (avoid terminating pods from the previous
  rollout — toggleable via `k8s-multilog-include-old-rollouts`).
- **StatefulSet / DaemonSet** — same selector approach.
- **Job** — `ownerReferences[].kind = "Job"` + name match.
- **Service** — `spec.selector` directly (no managed-by indirection).

Result: ordered list of `(POD-NAME . CONTAINERS)` tuples.  Container
selection: the deployment's `spec.template.spec.containers[0]` by
default; `k8s-multilog-all-containers` flag follows every container.

## 3. Cap

`k8s-multilog-max-pods` (defcustom, default 10).  When the resolved
pod count exceeds the cap, prompt:

```
Tail logs for 32 pods?  [y]es / [f]irst-10 / [n]o
```

`first-10` is the default (matches stern's `--max-log-requests`).

## 4. Buffer layout

Single buffer named `*k8s:multilog:<kind>/<name>*`.  Each rendered
line:

```
[ns/pod-name]   actual log line content here
[ns/another  ]  another pod's output
```

The bracketed prefix carries the pod's color face; the body inherits
the default face.  Prefix width is padded to the longest pod name in
the set so output stays column-aligned.  With `timestamps=true` (the
K8s `/log` query param), the apiserver inserts an RFC3339 stamp at
the start of each line; we leave that intact between the prefix and
the body.

## 5. Color palette

Use [Sasha Trubetskoy's "20 simple distinct
colors"](https://sashamaps.net/docs/resources/20-colors/) — designed
for qualitative legibility, vetted across viz libraries (Bokeh,
Plotly, observable).  The first 12 work well on both light and dark
Emacs themes (drops a couple of the lighter pastels that read poorly
on white backgrounds):

| # | hex     | name    |
|---|---------|---------|
| 1 | #e6194B | red     |
| 2 | #3cb44b | green   |
| 3 | #4363d8 | blue    |
| 4 | #f58231 | orange  |
| 5 | #911eb4 | purple  |
| 6 | #42d4f4 | cyan    |
| 7 | #f032e6 | magenta |
| 8 | #bfef45 | lime    |
| 9 | #469990 | teal    |
|10 | #9A6324 | brown   |
|11 | #800000 | maroon  |
|12 | #aaffc3 | mint    |

Defined as faces `k8s-multilog-pod-1` … `k8s-multilog-pod-12`, each
with `:foreground HEX` + `:weight bold` on the prefix.  Beyond 12
pods we cycle with `:slant italic` added — still visually
distinguishable from the first dozen.

Pods are assigned colors in **order of first line seen**
(deterministic within a session, robust to pod-name churn).

## 6. Streaming + interleaving

Per pod: open `/api/v1/namespaces/NS/pods/POD/log?follow=true&...`
via `docker-http-stream` (so we get the perf-PR-2 buffered chunked
decoder for free).  The chunk handler:

1. Appends bytes to a per-pod **line-buffer** (the
   `docker-stream-make-ndjson` pattern, but split on `\n` rather
   than parsed as JSON).
2. For each complete line, builds:
   `[ns/pod]<TAB><line>\n`
   with the pod's color face on the prefix only, then inserts at
   `(point-max)` of the multilog buffer.

Interleaving is by **arrival order** — same as stern.  No global
timestamp re-sort; users who want strict order pass
`timestamps=true` and the apiserver-prefixed stamps make it
visually obvious where reorderings happen.

Auto-scroll: insertions scroll to bottom *unless* point is above
the last line (matches the existing `docker-logs`/`k8s-pod-log-mode`
behaviour).

## 7. Controls (within the multilog buffer)

| key   | action |
|-------|--------|
| `g`   | restart every stream (re-resolves pods first) |
| `q`   | quit (kill-buffer-hook tears down all streams) |
| `p`   | pause/resume rendering (streams keep running, output queued) |
| `c`   | clear the buffer (streams keep running) |
| `RET` on a `[ns/pod]` prefix | open single-pod log buffer for that pod |
| `f`   on a `[ns/pod]` prefix | filter the buffer to show only that pod |
| `M-n` / `M-p` | jump to the next/previous line from a different pod |

## 8. Lifecycle

- Each per-pod stream's process goes into a buffer-local list
  `k8s-multilog--processes`.
- `kill-buffer-hook` iterates the list, calls `delete-process` on
  each + `(funcall closure 'cleanup)` on the per-pod line-splitter
  (PR-2 pattern).
- Pod-stream close (pod terminates / restarts): append
  `[ns/pod/closed]` line in the pod's color; remove from active set.
- All streams closed: append `[all streams closed]`.

## 9. Watching new pods (v2)

v1 ships with a static pod set fixed at open time.  v2:

- Watch the workload's pods via `k8s-watch-start` on
  `/api/v1/namespaces/NS/pods?labelSelector=…&watch=true`.
- On `ADDED` with a new pod: open a stream, assign next color slot.
- On `DELETED`: leave the closed-stream marker; new pod with same
  name in the future gets a fresh color slot (don't try to "remember"
  — keeps things simple).

## 10. Resource limits

Each per-pod stream is one open socket to the apiserver.  Tailing 50
pods means 50 long-lived TCP connections + 50 TLS handshakes (per
the existing transport — the keep-alive pool from PR-4 is for
short-request bursts, doesn't help here).  Mitigations:

- The default cap of 10 keeps it sane.
- README will document the apiserver-side cost (some operators
  rate-limit `pods/log` per-IP).

## 11. Testing

Per `docs/test-fixtures-plan.md`:

- New fixture `microk8s-deployment-multipod-tail` — deployment + 3
  pods, recorded `pods?watch=true` + 3 simultaneous `/log` streams,
  with chunks deliberately split mid-line to exercise the line
  splitter.
- Render-snapshot test: assert per-pod color-face on prefixes,
  ordering by arrival, prefix-column padding.
- Cleanup test: kill the buffer, assert all 3 processes are dead.

## 12. Order of work

1. **Faces + line splitter** — `k8s/k8s-multilog-faces.el` (the
   12-color palette) and a `k8s-multilog--make-line-splitter` helper
   (similar to `docker-stream-make-ndjson`'s scratch-buffer pattern
   but newline-split, not JSON).
2. **One-pod multilog** — open the buffer, stream one pod into it
   with the prefix machinery.  Validates the rendering shape.
3. **Multi-pod static** — N parallel streams, pod→color slot
   assignment on first-line, buffer-local process list,
   kill-buffer cleanup.
4. **Trigger wiring** — bind `l` on deployment / statefulset /
   daemonset / job / service.  Update `?` dispatch.
5. **Cap + interactive prompt.**
6. **Per-prefix actions** (RET → single-pod, `f` filter, `M-n`/`M-p`).
7. **Watch new pods (v2).**
8. **README + fixture + tests.**

Each step ships independently; the v1 vertical slice is steps 1-5.
