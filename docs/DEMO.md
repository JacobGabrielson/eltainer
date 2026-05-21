# Demo storyboard

This file is the **plain-English script** for `docs/exec-demo.gif`.
The implementation lives in `docs/demo-init.el` and is re-recorded by
`docs/record-demo.sh`.

The recording is a deterministic, scripted `emacs -nw` session — no
human typing, all keystrokes injected via `execute-kbd-macro` and
`process-send-string`.  Each scene below maps to a block in
`demo-init.el`; tweak the `sit-for` calls there to retime a scene.

We intentionally don't paste mock screenshots into this file — those
rot the moment a column shifts.  The point is the *narrative*: what
each section is showing the viewer, and roughly how long it lingers.

## Setup (off-camera)

- A sentinel docker container named `eltainer-ticker` is running
  (alpine, looping `echo "tick $i …"`).
- A sentinel k8s pod named `log-ticker` is running in the
  `kind-eltainer-test` cluster's default namespace (busybox, same
  tick loop).  Provides the streaming log scene.
- A two-container pod named `duo-box` is running in the same
  namespace (containers `app` / `sidecar`).  Provides the
  multi-container exec / picker scene.
- A second k8s cluster is reachable as `kind-eltainer-test` so the
  context switch lands somewhere real.  The demo starts pinned to
  `microk8s` (or whatever the default is) so the switch is visible.
- `record-demo.sh` creates all three sentinels if missing.
- `fido-vertical-mode` is enabled inside the demo Emacs so the
  container picker shows a live candidate list on screen.
- Terminal is 100 × 30, `TERM=xterm-256color`; `agg` renders Menlo at
  16pt in the Monokai theme (with sensible Linux fallbacks).

Total runtime is ~35 s.

## Scenes

| # | Beat | Linger | What the viewer sees |
|---|------|--------|----------------------|
| 1 | Dashboard | ~2 s | `M-x eltainer'.  Single screen listing every Docker and Kubernetes view, plus the live `Context: …` line for k8s.  Long enough to read `[b] switch'. |
| 2 | Docker containers | ~1.5 s | `c' on the dashboard.  Containers list with `eltainer-ticker' visible. |
| 3 | Exec into container | <1 s setup | `e' on the ticker → RET to accept `/bin/sh'.  Exec buffer opens. |
| 4 | Drive the shell | ~8 s | A handful of commands typed char-by-char (`whoami', `hostname', `echo …'), each with a short pause for the response to render.  Then `exit'. |
| 5 | Back, switch context | ~3 s | Back on the dashboard, `b' pops the context picker, the kind context is highlighted, RET commits, dashboard re-renders against the new cluster. |
| 6 | k8s pods on the new cluster | ~1.5 s | `k' lands on `*k8s:pods*' against the kind cluster — same UI, different pods. |
| 7 | Stream pod logs | ~4 s | Point moves to `log-ticker', `l' opens `*k8s:logs:default/log-ticker[ticker]*'; live tick lines stream in.  `q' to dismiss. |
| 8 | Multi-container exec | ~6 s | Point moves to `duo-box', `e' opens the container picker (fido shows `app' / `sidecar', `app' highlighted as default); RET accepts it, eltainer probes for a shell, the TTY exec buffer opens, `hostname' is typed, then `exit'. |
| 9 | Quit | <1 s | `kill-emacs 0', asciinema returns, agg builds the gif. |

## What's deliberately not shown

If you want any of these in a future recording, add a scene above and
a corresponding function in `demo-init.el`:

- `?` to pop the per-view transient dispatch.
- `g` to manually refresh.
- `i` describe-resource on a k8s row.
- Image-pull progress (`u`) with a layered pull.
- `f` for the read-only pod filesystem browser.
