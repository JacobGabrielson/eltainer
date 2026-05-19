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
  (alpine, looping `echo "tick $i …"`).  `record-demo.sh` creates it
  if missing.
- A second k8s cluster is reachable as `kind-eltainer-test` so the
  context switch lands somewhere real.  The demo starts pinned to
  `microk8s` (or whatever the default is) so the switch is visible.
- Terminal is 100 × 30, `TERM=xterm-256color`; `agg` renders Menlo at
  16pt in the Monokai theme.

Total runtime is ~18–20 s.

## Scenes

| # | Beat | Linger | What the viewer sees |
|---|------|--------|----------------------|
| 1 | Dashboard | ~2 s | `M-x eltainer'.  Single screen listing every Docker and Kubernetes view, plus the live `Context: …` line for k8s.  Long enough to read `[b] switch'. |
| 2 | Docker containers | ~1.5 s | `c' on the dashboard.  Containers list with `eltainer-ticker' visible. |
| 3 | Exec into container | <1 s setup | `e' on the ticker → RET to accept `/bin/sh'.  Exec buffer opens. |
| 4 | Drive the shell | ~8 s | A handful of commands typed char-by-char (`whoami', `hostname', `echo …'), each with a short pause for the response to render.  Then `exit'. |
| 5 | Back, switch context | ~3 s | Back on the dashboard, `b' pops the context picker, the kind context is highlighted, RET commits, dashboard re-renders against the new cluster. |
| 6 | k8s pods on the new cluster | ~3 s | `k' lands on `*k8s:pods*' against the kind cluster — same UI, different pods. |
| 7 | Quit | <1 s | `kill-emacs 0', asciinema returns, agg builds the gif. |

## What's deliberately not shown

If you want any of these in a future recording, add a scene above and
a corresponding function in `demo-init.el`:

- `l` to stream pod logs.
- `?` to pop the per-view transient dispatch.
- `g` to manually refresh.
- `i` describe-resource on a k8s row.
- Image-pull progress (`u`) with a layered pull.
- `e` for interactive TTY exec into a k8s pod (currently on the
  `wip-k8s-tty-exec` branch).
- `f` for the read-only pod filesystem browser.
