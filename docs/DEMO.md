# Demo storyboard

This file is the **plain-English script** for `docs/exec-demo.gif`.
Edit it to change what the demo shows; the implementation lives in
`docs/demo-init.el` and is re-recorded by `docs/record-demo.sh`.

The recording is a deterministic, scripted `emacs -nw` session — no
human typing, all keystrokes injected via `execute-kbd-macro` and
`process-send-string`.  Each "scene" below corresponds to a block in
`demo-init.el`; rewrite a scene here and propagate the change to that
file before re-recording.

## Setup (off-camera)

Before the gif starts:

- A sentinel container named `eldocker-ticker` is running (alpine,
  echoing `tick $i $(date)` on a 5-second loop).  Other sentinels
  (`eldocker-nginx`, `-redis`, `-postgres`, `-httpbin`) may also be
  running and will appear in the containers list.
- A `kind` cluster named `eltainer-demo` is up — registered in
  `~/.kube/config` as the `kind-eltainer-demo` context, alongside the
  Docker-Desktop-provided `docker-desktop` context.
- The demo starts with `k8s-context-override` pinned to
  `docker-desktop` so the first dashboard render shows that context.

Terminal dimensions are forced to 100 × 30; `TERM=xterm-256color`;
the `agg` post-processor renders with Menlo at 16pt in the Monokai
theme.

## Scene 1 — Dashboard (≈2.5 s)

`M-x eltainer` fires.  The buffer renders:

```
eltainer — unified container porcelain

Press the key beside an entry, or RET on a row.
g refreshes, q quits.

Docker
  c  Containers
  I  Images
  N  Networks
  u  Pull

Kubernetes
  Context:  docker-desktop  —  ~/.kube/config    [b] switch
  k  Pods
  d  Deployments
  …
```

The viewer should have ~2 seconds to read the Context line and notice
`[b] switch`.

## Scene 2 — Docker containers view (≈1.5 s)

`c` is pressed.  The dashboard is replaced by `*docker:containers*`:

```
Docker:    Containers (running)
Endpoint:  unix:///var/run/docker.sock

  NAME                  STATE      IMAGE         PORTS                  AGE
  eltainer-demo-control-plane  running  kindest/node:v1.35.0@s…  127.0.0.1:55002→6443/tcp  …
  eldocker-ticker              running  alpine:3.20              …                          3d
  eldocker-httpbin             running  kennethreitz/httpbin     0.0.0.0:8081→80/tcp       …
  eldocker-postgres            running  postgres:16-alpine       0.0.0.0:5433→5432/tcp     …
  eldocker-redis               running  redis:7-alpine           0.0.0.0:6380→6379/tcp     …
  eldocker-nginx               running  nginx:alpine             0.0.0.0:8080→80/tcp       5d
```

Point lands on `eldocker-ticker` (a real `re-search-forward` in the
script).

## Scene 3 — Exec into the container (≈0.8 s setup)

`e` is pressed.  The minibuffer prompts `Exec in eldocker-ticker:
/bin/sh` — `RET` accepts the default.  `docker-exec-at-point` opens
`*docker:exec:eldocker-ticker*` in the resolved terminal backend
(`eat` if installed, falls back to `vterm` → `term`).

The viewer sees the buffer split: the exec buffer on top, the docker
containers list still visible below.

## Scene 4 — Drive the shell (≈8 s)

Each command is typed character-by-character at ~25 cps via
`process-send-string` on the network process, then a short pause to
let the response render:

| Command | Pause after |
|---------|-------------|
| `whoami\n` → `root` | 0.6 s |
| `hostname\n` → container ID (e.g. `25d8782c53bb`) | 0.6 s |
| `uname -a\n` → `Linux … aarch64 Linux` | 0.8 s |
| `echo hello from eltainer\n` → `hello from eltainer` | 2.0 s |
| `exit\n` | — |

After `exit`, the shell process dies and the modeline shows
`[Eat[semi-char]:no process]`.  The exec buffer is then killed
(with `kill-buffer-query-functions` muted) and we return to the
dashboard.

## Scene 5 — Context switch (≈1.8 s)

Back on `*eltainer*`.  The script simulates pressing `b` by
`cl-letf`-overriding `completing-read` to return the
`kind-eltainer-demo` entry from the candidates alist.
`eltainer-switch-kubeconfig` runs, which:

1. Sets `k8s-kubeconfig-path` to `~/.kube/config`.
2. Sets `k8s-context-override` to `"kind-eltainer-demo"`.
3. Kills any open `*k8s:…*` buffers.
4. Re-renders the dashboard.

The Context line flips to `kind-eltainer-demo  —  ~/.kube/config`.
The echo area shows `eltainer: switched to kind-eltainer-demo
(~/.kube/config)`.  The viewer should have ~1.5 s to register the
change.

## Scene 6 — Kubernetes pods view (≈3 s)

`k` is pressed.  `*k8s:pods*` opens against the new context:

```
Cluster:   127.0.0.1:60000ish
User:      kind-eltainer-demo
Resource:  Pods
Namespace: all

  NAME                                      STATUS    READY   RESTARTS   AGE    IP

kube-system (8)
  coredns-…                                 Running   1/1     0          1m     10.244.0.…
  etcd-eltainer-demo-control-plane          Running   1/1     0          1m     172.18.0.…
  kindnet-…                                 Running   1/1     0          1m     …
  kube-apiserver-…                          Running   1/1     0          1m     …
  kube-controller-manager-…                 Running   1/1     0          1m     …
  kube-proxy-…                              Running   1/1     0          1m     …
  kube-scheduler-…                          Running   1/1     0          1m     …
  local-path-provisioner-…                  Running   1/1     0          1m     …

default (2)
  hello-eltainer-…                          Running   1/1     0          1m     10.244.0.…
  hello-eltainer-…                          Running   1/1     0          1m     10.244.0.…
```

The viewer has ~2.8 s to see that the same UI is now showing a
completely different cluster.

## Scene 7 — Tear down (≈0.5 s)

`(kill-emacs 0)` exits.  asciinema's `rec --command` returns, and
`agg` converts the cast into the final GIF.

## Timing

Approximate total: 18–20 seconds of gif at 1× speed.  agg renders at
the cast's real cadence; speed is *not* compressed.  If a scene feels
rushed or sluggish, tweak the `sit-for` calls in the matching
`demo--*-segment` function in `demo-init.el`.

## What's deliberately *not* shown

If you want any of these in a future recording, add a scene above
and a corresponding function in `demo-init.el`:

- `l` to stream pod logs (real-time chunked output).
- `?` to pop the per-view transient dispatch.
- `g` to manually refresh (auto-refresh on `/events` is invisible to
  a viewer of a static gif anyway).
- `i` describe-resource on a k8s row.
- Image-pull progress (would need a fresh `docker rmi` before
  recording so the pull actually does work).
- `e` for interactive TTY exec into a k8s pod — scaffolded on the
  `wip-k8s-tty-exec' branch, not yet on `main'.
- `f` for the read-only pod filesystem browser.
