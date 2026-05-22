# eltainer

A pure Emacs Lisp porcelain for **Docker and Kubernetes**, fronted by
a single magit-style UI.

![eltainer dashboard + docker exec](docs/exec-demo.gif)

*`M-x eltainer` opens a dashboard listing every available view in
both backends, including the currently-active kubeconfig context.
`c` jumps to the docker containers list; `e` on a row opens a real
shell inside the container via HTTP Upgrade hijack of
`POST /exec/{id}/start`, rendered in `eat`.  `b` switches Kubernetes
contexts the way `b` switches branches in magit.  No `docker` CLI
or `kubectl` involved.*

## Philosophy

**Pure Elisp talking directly to the daemon.**

eltainer speaks HTTP/1.1 to the Docker daemon over its Unix socket
**and** HTTPS to the Kubernetes API server.  Both halves share one
transport, one streaming/event pipeline, one terminal abstraction.
JSON via native `json-parse-*`, TLS via built-in GnuTLS; the package
refuses to load without the former and refuses to TLS-connect
without the latter.

CLI fallbacks are kept *only* for things the engine APIs genuinely
can't do — `docker build` (BuildKit gRPC), `docker compose`, CLI
plugins, `docker login` config writes, `DOCKER_HOST=ssh://…`
transport, `docker-credential-*` helpers, and Kubernetes
`users.exec` plugins (`aws eks get-token`, `gke-gcloud-auth-plugin`,
…).  Each is one clearly-named function in one place.  See
[docs/architecture.md](docs/architecture.md).

## What you can do

`M-x eltainer` is the home screen.  From there, single-key launchers:

| Backend | Key | View |
|---------|-----|------|
| Docker | `c` | Containers (running; `a` toggles all) |
| Docker | `I` | Images |
| Docker | `N` | Networks (+ connected containers) |
| Docker | `u` | Pull image (streamed per-layer progress) |
| Kubernetes | `k` | Pods grouped by namespace |
| Kubernetes | `d` | Deployments |
| Kubernetes | `s` | Services |
| Kubernetes | `S` | StatefulSets |
| Kubernetes | `D` | DaemonSets |
| Kubernetes | `j` / `J` | Jobs / CronJobs |
| Kubernetes | `i` | Ingresses |
| Kubernetes | `m` / `x` | ConfigMaps / Secrets |
| — | `b` | Switch Kubernetes context (across all discovered kubeconfigs) |
| — | `g` | Refresh dashboard |

`M-x docker` and `M-x k8s` still work directly and bypass the
dashboard if that's what you want.

### Inside any docker view

| Key | Action |
|-----|--------|
| `?` | Transient dispatch menu |
| `g` | Refresh |
| `q` | Quit window |
| `RET` | Toggle section / DWIM |
| `i` | Inspect resource at point |
| `d` | Delete / disconnect (context-aware) |
| `a` | Toggle running-only vs. all (containers view) |
| `s` `S` `r` `K` | Start / Stop / Restart / Kill container |
| `l` | Tail logs (streaming, stdout / stderr demuxed) |
| `e` | Exec a shell inside the container (TTY) |
| `M` | Per-container metrics buffer (containers view) |
| `j` `J` | Join / leave a network |

Views auto-refresh as the daemon's `/events` stream tells us what
changed (debounced).  The TTY exec lands in an
[`eat`](https://codeberg.org/akib/emacs-eat) buffer — eat is a hard
dependency (see [Requirements](#requirements)).

`TAB` on a running container shows live gauges — CPU% (with a
`throttled` note when it's hitting its CFS limit), memory, block-I/O
and network throughput sparklines, and the PID count — polled from
`/containers/{id}/stats`.  `M` opens a focused, self-refreshing
metrics buffer for the container.

### Inside the k8s view

| Key | Action |
|-----|--------|
| `?` | Context-aware dispatch — actions for the resource under point, plus `v` for the view switcher |
| `g` | Refresh |
| `N` | Switch namespace |
| `w` | Toggle live watch (auto-update via the K8s watch API) |
| `b` | Switch kubeconfig context (same picker as from the dashboard) |
| `i` | Describe resource |
| `l` | Tail pod logs (streamed) |
| `e` | Interactive TTY exec into the pod (pods view only) |
| `f` | Read-only filesystem browser for the pod (pods view only) |
| `M` | Per-pod metrics buffer (pods view only) |
| `d` | Delete resource (with confirmation) |
| `TAB` | Expand / collapse section |

`?` is **context-aware** — the first group of the menu reflects
whatever the cursor is on (a pod, a container, or another resource),
so it only ever offers actions that apply there.  `l` / `e` / `f` /
`M` on a container row target that container directly.

`TAB` on a pod expands it to show its containers, each as its own
section — point on a container row makes `l` / `e` / `f` target that
container directly (no picker).  Expanded containers also show live
CPU, memory and disk gauges (with trend sparklines), and the pod
gets a network rx/tx sparkline — CPU/memory need metrics-server,
disk/network need the kubelet stats API; each degrades gracefully if
unavailable.  `M` opens a focused, self-refreshing metrics buffer
for the pod; `?` → `o` (or `M-x k8s-nodes-metrics`) opens a
cluster-wide per-node CPU/memory/disk view.

### Switching contexts

`b` (on the dashboard *or* any k8s view) enumerates every context
across every discovered kubeconfig file (`$KUBECONFIG`, anything
under `~/.kube` and `~/.kube/configs`, plus
`eltainer-kubeconfig-extra-paths`).  Pick one and the dashboard
flips immediately: any open `*k8s:…*` buffers are killed so they
re-open against the new context the next time you visit them.
Same muscle memory as `b` in magit for branches.

## Architecture

```
eltainer.el              Dashboard + `M-x eltainer'
eltainer-ui.el           Shared faces, age-string, describe-value
eltainer-gauge.el        Shared text gauges + sparklines for the metrics views
eltainer-terminal.el     eat-backed terminal host for interactive exec
eltainer-shell-helper.el Invoke external helpers (cred / exec plugins)
reload.el                Dev helper: byte-compile + reload both halves

docker/
  docker-http.el         HTTP/1.1 over unix / TCP / TCP+TLS (GnuTLS)
                         + chunked-decoded streaming.  Used by k8s too.
  docker-stream.el       8-byte multiplex demux + ndjson splitter
  docker-api.el          /vX.Y-prefixed engine GET / POST / DELETE
  docker-config.el       Connection params struct (used by k8s too)
  docker-ps.el           Containers: list / inspect / lifecycle
  docker-images.el       Images: list / inspect / tag / remove
  docker-networks.el     Networks: list / inspect / connect / remove
  docker-events.el       Long-lived /events stream + pub/sub
  docker-logs.el         Streaming /containers/{id}/logs, demuxed
  docker-exec.el         Upgrade-hijacked /exec/{id}/start TTY
  docker-auth.el         ~/.docker/config.json + docker-credential-* helpers
  docker-pull.el         Streamed /images/create with per-layer progress
  docker-metrics.el      Container /stats gauges: cpu / mem / io / net / pids
  docker.el              magit-section views + transient + actions

k8s/
  k8s-config.el          kubeconfig YAML parser (subset)
  k8s-api.el             REST client (thin wrapper over docker-http)
  k8s-watch.el           Watch streams on docker-http-stream
  k8s-metrics.el         Usage gauges / sparklines: metrics.k8s.io +
                         kubelet Summary API; per-pod + node views
  k8s-pods.el            Pods view: phases, restarts, streamed logs,
                         container subsections, inline metrics
  k8s-fs.el / k8s-fs-ui.el  Pod-fs browser
  k8s-exec.el            One-shot + interactive TTY pod exec
  k8s.el                 Shared k8s magit-section views + transient
```

## Requirements

- Emacs 30+ with native JSON (`json-parse-string`) and, for any TLS
  target, GnuTLS (`gnutls-available-p`).  eltainer refuses to load
  without the former and refuses to TLS-connect without the latter.
- `magit-section`, `transient`.
- [`eat`](https://codeberg.org/akib/emacs-eat) (`M-x package-install
  RET eat RET` from MELPA / NonGNU ELPA).  Pure-Elisp xterm emulator;
  the sole supported terminal backend for `e` (interactive exec) in
  both Docker and Kubernetes views.  `eltainer-terminal.el` refuses
  to load without it.

  Why insist on eat?  The docker-exec and k8s-exec paths feed bytes
  through a custom process filter (HTTP-Upgrade hijack for Docker,
  WebSocket framing for Kubernetes).  built-in `term-mode` only
  renders bytes from an Emacs subprocess's stdout, and `vterm`
  doesn't expose a clean byte-injection seam — both silently no-op
  in this codebase.  eat does the right thing
  (`eat-term-process-output`) and is pure-Elisp, so it's a no-cost
  dep.
- A running Docker daemon and / or a kubeconfig.

## Quick start

```elisp
(add-to-list 'load-path "/path/to/eltainer")
(require 'eltainer)

;; Then any of:
;;   M-x eltainer          ; dashboard listing every view + active context
;;   M-x docker            ; jump straight to docker containers
;;   M-x k8s               ; jump straight to k8s pods
```

For development:

```elisp
(load "/path/to/eltainer/reload.el")
;; M-x eltainer-reload       ; byte-compile + reload + re-enter open buffers
```

## Demo

The GIF up top is regenerated by `docs/record-demo.sh` (requires
[asciinema](https://asciinema.org/) and
[agg](https://github.com/asciinema/agg) — `brew install agg`).  It
spins up a sentinel container, scripts an `emacs -nw` session
through [`docs/demo-init.el`](docs/demo-init.el), records with
asciinema, and converts to GIF.

## License

Apache 2.0 — see [LICENSE](LICENSE).
