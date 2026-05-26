# NEWS — eltainer

User-visible changes, **reverse-chronological** by date.  Each
heading is a day; under it sit the features that landed that day.
Entries are written from the user's point of view — what's now
possible, which key does what.  Implementation detail belongs in
commit messages.

See `docs/*-plan.md` for design docs and `docs/new-features.md` for
the in-flight backlog.

---

## 2026-05-26

### Helm RESOURCES rows are jump-targets

Expanding a Helm release row shows a per-kind tally of the rendered
manifest (`1 Deployment / 1 Service …`).  Each kind line with a
registered resource view (Service, Deployment, StatefulSet,
DaemonSet, Job, CronJob, ConfigMap, Secret, Ingress, Pod) is now
`RET`-actionable — jumps to that view, switches to the release's
namespace, and pre-sets a name-regex filter narrowing to *exactly
the resources from that release*.  Resource names are pulled from
the manifest directly, so the filter is precise no matter what
labels the chart did or didn't add.

### Helm 3 releases view

`H` on the dashboard (or `?` → *Helm releases* from any k8s view)
opens a read-only listing of Helm 3 releases in the cluster.
Columns: NAME / REVISION / STATUS / CHART / APP / AGE; STATUS is
colour-coded (deployed = green, failed = red, other = yellow).

Per-row actions:
- `RET` / `TAB` — expand the row.  Shows a per-kind tally of the
  rendered manifest (`3 Service / 5 ConfigMap / 1 Deployment …`)
  and the chart's `NOTES.txt`.
- `v` — pop a buffer with the release's `values.yaml` (pretty-
  printed JSON, falls into `json-mode` when available).
- `m` — pop a buffer with the rendered manifest.
- `h` — pop the full revision history (every revision of this
  release, newest first; the main view shows only the active one).
- `F` — narrow composes with helm's `owner=helm` baseline.

Decoded directly from the API-server release Secrets — no `helm`
CLI invoked.

### Filter / narrow views by label (`F` prefix)

Every k8s view and the docker containers view now narrow on the
fly.  `F l SELECTOR` applies a K8s-style label selector
(`tier=frontend,env!=dev`).  `F n REGEX` narrows by name regex.
`F c` clears.  Filters are per-buffer and survive `g`.  The
mode-line shows `[label:… name:…]` in the warning face when
active.

Labels go server-side (K8s `?labelSelector=`, docker `?filters=`
JSON).  Name-regex is client-side.  Docker's filter is
equality-only — `!=` / `!key` terms in the selector are dropped
with a one-line warning.

### DNS lookup from inside a container (`D`)

On the pods view (or docker containers view), `D` prompts for a
hostname and resolves it *from inside that container*.  Tries
`getent hosts` → `nslookup` → falls back to dumping
`/etc/resolv.conf` + `/etc/hosts` (first probe that exits 0 wins).
Result pops a read-only buffer.  Distroless images get a clear
"no shell, no getent, no nslookup" diagnostic.

### Ingress backend `RET` jumps to the Service

When an Ingress section is expanded, each `host/path → service:port`
row is now actionable — `RET` jumps to that Service in the services
view.  Foundation for a general `k8s-jump-target` text-property
mechanism that future cross-resource jumps will reuse (Pod → Node,
Service → Endpoints, etc.).

### Age column colour tiers

The AGE column in every resource view now colour-codes by tier:

| Age      | Face                    | Default colour |
|----------|-------------------------|----------------|
| < 1 hour | `eltainer-age-very-new` | warning        |
| < 1 day  | `eltainer-age-new`      | success        |
| < 1 week | `eltainer-age-medium`   | default fg     |
| < 30 days| `eltainer-age-old`      | shadow         |
| ≥ 30 days| `eltainer-age-ancient`  | shadow + light |

Themable via `M-x customize-face`.

### Log views: `p` is `previous-line` again

In `k8s-multilog-mode`, `p` used to toggle pause/resume — but
every other view uses `n`/`p` for line navigation, so muscle
memory tripped.  Pause has moved to capital `P`.  All log buffers
(single-pod, multipod, docker) now enable `hl-line-mode` so the
cursor line is visibly highlighted.

### Writable filesystem browser (container-dired v2)

The dired-mode buffer over a container's filesystem (`f` on a pod
or container) is now writable.  The standard dired keys route
through the container's exec backend, after a yes-or-no confirm:

| Key | Action |
|-----|--------|
| `D` | Delete marked files (`rm -rf` inside the container) |
| `R` | Rename or move marked files (`mv`) |
| `C` | Copy in-container (`cp -r`) or export to host (`host:` prefix) |
| `+` | Create directory (`mkdir -p`) |
| `I` | Import a host file *into* this directory |
| `C-x C-q` | wdired — edit names in the buffer, `C-c C-c` commits the batch |

Host → container import uses Docker's archive PUT API on the
docker side, base64-through-argv on the k8s side (256 KB cap).
The first writable op probes for `rm` / `mv` / `mkdir` / `cp` and
caches the result on the buffer — distroless surfaces a single
friendly error instead of one per operation.

### Read-only filesystem browser (container-dired v1)

`f` on a pod or container row opens a real `dired-mode` buffer over
the container's filesystem.  Inherits every navigation / marking
keystroke from muscle memory.  Sentinel paths are
`/docker:NAME:/path` and `/k8s:NS/POD[CONTAINER]:/path` — *not*
TRAMP; eltainer never shells out.  Reads go through the engine
API directly, so distroless can still be catted (docker side) and
gives a clean error message instead of OCI noise (k8s side).

### `make test` / `make test-all`

`make test` runs the pure-Elisp unit suite (parsers, path
arithmetic, regression tests) with no daemon or cluster needed.
`make test-all` adds the live-daemon and live-cluster integration
suites — they `skip-unless` cleanly when nothing's reachable.
`make compile` does a clean byte-compile sanity check.

---

## 2026-05-25

### Friendlier error on distroless / scratch containers

When `f` (or any other exec-dependent action) hit a distroless or
scratch image, the user used to see several lines of raw OCI
runtime noise.  Now they get a single line:

```
eltainer-fs: container has no `sh' / `find' / `stat'
(distroless or scratch image) — filesystem browse needs a POSIX
shell + GNU/BusyBox coreutils inside the container
```

---

## 2026-05-24

### Dired-style marks across every view

`m` / `u` / `U` / `t` / `DEL` (plus `M-DEL`, `* !`, `* ?`) mark /
unmark resources in any k8s view.  Marks then feed multi-target
commands.

### Multi-pod log tailing (stern-style, `L`)

`L` on the pods view streams every marked pod's logs into one
buffer, each pod a distinct colour.  Or `l` on a controller
(Deployment / StatefulSet / DaemonSet / Job / Service / CronJob)
tails every pod the controller owns automatically.  Point at tail
on open / restart / clear.

### ANSI colour rendering in log buffers

Pod / container log streams used to leak `^[[` escape sequences
into the buffer.  They now render colour and basic SGR styles
inline.

### Stable cursor across refreshes; CronJob last-run logs

`g` (refresh) keeps the cursor on the same resource even when the
list above shifts.  `l` on a CronJob row tails the last run's
pod's logs.

---

## 2026-05-23

### `M-x eltainer-stop-all` panic button

A single command that closes every eltainer view, cancels every
metrics timer, and tears down every open watch stream.  Useful
when a slow cluster has made Emacs feel unresponsive.

Default metrics polling interval also relaxed (from 5 s to 30 s).

---

## 2026-05-22

### Kubernetes Nodes view, optionally Prometheus-enriched

`o` from the dashboard / `?` resource switcher opens a cluster
nodes view: per-node CPU and memory usage gauges off
`metrics.k8s.io`, plus disk usage from the kubelet Summary API.
If a Prometheus Service is present in the cluster, node 1m / 5m /
15m load averages and range queries fold in too.

### Kubernetes Sandboxes view (agent-sandbox SIG)

`A` opens a view of `agents.x-k8s.io/v1alpha1` `Sandbox` resources
when the CRD is installed.  Degrades gracefully (no rows, no
error) when it isn't.

### Container metrics dashboard (docker side)

`M` on a docker container row opens a per-container metrics buffer
with CPU, memory, disk I/O, network, and PIDs gauges — sampled
from the engine's `/stats` endpoint.  Fetched asynchronously so
slow daemons don't hang Emacs.  Memory gauges against host RAM for
containers with no explicit limit.

### Kubernetes metrics (phase 1 / 1.5 / 2)

Inline CPU and memory gauges render directly under each pod
section in the pods view, fed by `metrics.k8s.io`.  `M` on a pod
opens a per-pod metrics dashboard.  Disk usage gauges and network
sparklines from the kubelet Summary API.  Trend sparklines show
the recent history.  `?` dispatch grew an entry for the per-pod
metrics buffer.

---

## 2026-05-21

### Container-aware `l` / `e` / `f`

When point is on an expanded *container* sub-section of a pod
(vs. the pod row itself), `l` / `e` / `f` / `M` target that
container directly — no picker prompt.  On the pod line,
multi-container pods get a picker.

### Buffer-based container picker (no completion framework needed)

The multi-container picker for `e` / `l` is now its own
self-contained buffer with `n` / `p` / `RET` / `q` — works
identically regardless of whether the user has vertico / fido /
plain minibuffer completion configured.

### `k8s exec` always prompts for the command

`e` on a pod / container now always pops a prompt pre-filled with
`/bin/sh`.  Accept the default to trigger a shell probe; type
anything else (`bash`, `ash -x`, `python3 -c …`) to run that
instead.

---

## 2026-05-20

### Multi-container exec / logs picker

When `e` or `l` is invoked on a multi-container pod, eltainer
prompts for the container instead of silently picking the first.

---

## 2026-05-19

### Shell probe + readable failures for `k8s exec`

`e` defaults to `/bin/sh`, but if that doesn't exist eltainer
probes `bash`, `busybox sh`, `ash` and the first one that works.
Distroless images get a clear error message pointing at
`kubectl debug --image=busybox` instead of the bare engine error.

### Streaming pod logs

Pod logs stream in live (`l`) instead of being one-shot fetched.
`g` restarts the stream; `k` stops it.
