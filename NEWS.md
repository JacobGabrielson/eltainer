# NEWS — eltainer

User-visible changes to eltainer, **reverse-chronological** (newest
first).  Entries land here when a feature ships, not when it's
planned — see `docs/*-plan.md` for design docs and
`docs/new-features.md` for the in-flight backlog.

Entries are written from the user's perspective: what's now possible
that wasn't, which key does what, what surface the user looks at.
Implementation detail belongs in commit messages, not here.

---

## Unreleased

### Helm 3 releases view

`H` on the dashboard (or `?` → *Helm releases* from any k8s view)
opens a read-only listing of every Helm 3 release in the cluster.
Columns: NAME / REVISION / STATUS / CHART / APP / AGE; STATUS is
colour-coded (deployed = green, failed = red, other = yellow).
`RET` on a row expands it to show the chart's `NOTES.txt`.  `v` pops
the release's `values.yaml`; `m` pops the rendered manifest.

Decoded directly from the release Secrets the API server already
exposes (`owner=helm,status!=superseded` label selector) — no `helm`
CLI is invoked.

### Filter / narrow views by label (`F` prefix)

Every k8s view and the docker containers view now narrow on the fly.
`F l SELECTOR` applies a K8s-style label selector
(`tier=frontend,env!=dev`).  `F n REGEX` narrows by name regex.
`F c` clears.  Filters are per-buffer and survive `g`.  The
mode-line shows `[label:… name:…]` in the warning face when active.

Labels go server-side (K8s `?labelSelector=`, docker `?filters=`
JSON).  Name-regex is client-side.  Docker's filter is
equality-only — `!=` / `!key` terms in the selector are dropped
with a one-line warning.

### DNS lookup from inside a container (`D`)

On the pods view (or docker containers view), `D` prompts for a
hostname and resolves it *from inside that container*.  Tries
`getent hosts` → `nslookup` → falls back to dumping `/etc/resolv.conf`
+ `/etc/hosts` (first probe that exits 0 wins).  Result pops a
read-only buffer.  Distroless images get a clear "no shell, no
getent, no nslookup" diagnostic.

### Ingress backend `RET` jumps to the Service

When an Ingress section is expanded, each `host/path → service:port`
row is now actionable — `RET` jumps to that Service in the services
view.  This is the first arm of a general `k8s-jump-target` text
property mechanism that future cross-resource jumps will reuse (Pod
→ Node, Service → Endpoints, etc.).

### Age column colour tiers

The AGE column in every resource view used to render in a single
dim face — old and brand-new resources looked the same.  Now each
age tier gets its own face:

| Age      | Face                       | Default colour |
|----------|----------------------------|----------------|
| < 1 hour | `eltainer-age-very-new`    | warning (yellow / orange) |
| < 1 day  | `eltainer-age-new`         | success (green) |
| < 1 week | `eltainer-age-medium`      | default foreground |
| < 30 days| `eltainer-age-old`         | shadow |
| ≥ 30 days| `eltainer-age-ancient`     | shadow + light weight |

Faces are themable via `M-x customize-face`.

### Log views: `p` is `previous-line` again

In the multipod log buffer (`k8s-multilog-mode`), `p` used to toggle
pause/resume — but every other view uses `n`/`p` for line
navigation, so muscle memory tripped.  Pause has moved to capital
`P`.  All log buffers (single-pod, multipod, docker) now enable
`hl-line-mode` so the cursor line is visibly highlighted.

### Writable filesystem browser (container-dired v2)

The dired-mode buffer over a container's filesystem (`f` on a pod
or container) is now writable.  The standard dired keys all route
through the container's exec backend, after a yes-or-no confirm:

| Key | Action |
|-----|--------|
| `D` | Delete marked files (`rm -rf` inside the container) |
| `R` | Rename or move marked files (`mv`) |
| `C` | Copy in-container (`cp -r`) or export to host (`host:` prefix) |
| `+` | Create directory (`mkdir -p`) |
| `I` | Import a host file *into* this directory |
| `C-x C-q` | wdired — edit names in the buffer, `C-c C-c` commits the batch as `mv` execs |

Host → container import uses Docker's archive PUT API (works on
distroless / scratch) on the docker side, base64-through-argv on
the k8s side (256 KB cap; the WebSocket sync exec has no stdin).
The first writable op probes for `rm` / `mv` / `mkdir` / `cp` and
caches the result on the buffer — distroless surfaces a single
friendly error instead of one per operation.

### Read-only filesystem browser (container-dired v1)

`f` on a pod or container row opens a real `dired-mode` buffer over
the container's filesystem.  Inherits every navigation / marking
keystroke from muscle memory: `n`/`p`, `RET`, `^`, `m`/`u`/`U`/`t`,
sort, hide-by-pattern, all of it.  Sentinel paths are
`/docker:NAME:/path` and `/k8s:NS/POD[CONTAINER]:/path`, *not*
TRAMP — eltainer never shells out.

Reads tunnelled through the engine API (docker archive endpoint
on docker, exec on k8s) so distroless containers can still be
*catted* (docker side) and yield a clear error message instead of
a wall of OCI noise (k8s side, where listing needs a shell).

---

## Earlier work

### Multi-pod log tailing (stern-style)

`L` on the pods view streams every marked pod's logs into one
buffer, each pod a distinct colour.  Or `l` on a controller
(Deployment / StatefulSet / DaemonSet / Job / Service / CronJob)
tails every pod the controller owns automatically.  Point at tail
on open / restart / clear; pause with `P`.

### Dired-style marks across every view

`m` / `u` / `U` / `t` / `DEL` (and the full set: `M-DEL`, `* !`,
`* ?`) mark / unmark resources in any k8s view.  Marks then feed
multi-target commands (`L` for multipod logs, `d` for batch
delete, etc.).

### ANSI colour rendering in log buffers

Pod / container log streams used to display `^[[` escape junk;
they now render colours and basic SGR styles inline.

### Interactive TTY exec into pods + containers

`e` on a pod or container row opens a real terminal inside it,
backed by `eat`.  The remote PTY tracks the Emacs window size.
Defaults to a shell probe (`/bin/sh` → `bash` → `busybox sh`),
with a clear error on distroless.

### Container-aware launchers

When point is on an expanded *container* sub-section of a pod (vs.
the pod itself), `l` / `e` / `f` / `M` target that container
directly — no picker prompt.  On the pod line, multi-container
pods get a picker.

### Per-resource metrics buffers

`M` on a pod opens a metrics dashboard for it (CPU / memory / I/O
/ net per container, sparklines).  Same on a docker container.
Cluster-level: a Nodes view with per-node usage gauges, optionally
enriched by Prometheus load averages and range queries.

### Inline metrics gauges in resource views

CPU / memory bars render under each pod section in the pods view,
fed by `metrics.k8s.io`.  Disk I/O and network rates fold in from
the kubelet Summary API.  Trend sparklines show the recent
history.  Metrics polling is on its own timer (default 30 s),
never blocks the view's hot path.

### Kubeconfig context switcher (`b`)

`b` from the dashboard or any k8s view pops a picker listing every
context discovered in `$KUBECONFIG`, `~/.kube/config`,
`~/.kube/configs/`, and `eltainer-kubeconfig-extra-paths`.  RET
switches.

### Watch-API live updates (`w`)

`w` in any k8s view turns on live updates: pod transitions, new
pods, deletions etc. flow in from the watch stream and the buffer
re-renders incrementally.  The mode-line shows `[W]` (active) /
`[W!]` (stalled).

### Resource views

`d` Deployments / `s` Services / `S` StatefulSets / `D` DaemonSets
/ `j` Jobs / `J` CronJobs / `i` Ingresses / `m` ConfigMaps / `x`
Secrets / `o` Nodes / `A` Sandboxes (agent-sandbox SIG) / `H` Helm
releases — all reachable from the dashboard, or from each other
via the `?` resource-switcher transient.

### Dashboard (`M-x eltainer`)

A unified home screen listing every Docker and Kubernetes view
plus the active kubeconfig context.  `RET` on a row launches the
view; the dashboard refreshes its kubeconfig section automatically
on context switch.

### Direct docker engine API

eltainer no longer shells out to the `docker` CLI.  Every action
(`ps`, `logs`, `exec`, `events`, image pulls, metrics, archive
copy) talks straight to the engine's UNIX socket / TLS endpoint
via plain HTTP.  Auth (TLS certs, `docker-credential-*` helpers)
is read from `~/.docker/config.json`.

### Pre-history

Things from before NEWS started being kept — see `git log` for
the full record.  The big arcs were:

- **`eltainer` rename + repo unification** (Phase A–G) — folded
  the separate Docker and Kubernetes pure-Elisp clients into one
  tree, sharing HTTP, terminal, UI primitives.
- **Performance plan** — four tiers of measured speedups
  (parallelism, HTTP keep-alive pool, kubeconfig memoisation,
  stream-filter buffering, incremental tracking).  See
  `docs/perf-plan.md`.
- **Test fixtures plan** (proposal, see
  `docs/test-fixtures-plan.md`) — capture / replay HTTP layer for
  deterministic offline tests.  Not landed yet; current tests are
  pure-Elisp unit + live integration (`make test` / `make test-all`).
