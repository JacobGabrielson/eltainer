# CLAUDE.md — Working notes for Claude in this repo

## Scratch files: use `./tmp/`, not `/tmp/`

This repo has a `tmp/` dir at the top level (gitignored).  Put all
throwaway files — probe scripts, captured output, ad-hoc test elisp,
intermediate artifacts — under `./tmp/` (i.e. `tmp/` relative to the
repo root), not under the system `/tmp/`.

If `tmp/` is missing, just `mkdir -p tmp` and proceed.  The whole
directory is gitignored, so anything you drop in there stays local.

Reasons:
- Scratch files are easy to find again next session.
- Settled into one place, they don't pollute the user's `/tmp` or
  collide with system temp files.
- The user can grep / inspect them without searching the filesystem.

## Avoid gratuitous `cd <dir> && <cmd>` commands

The user runs Claude in a permission-prompted setup where any
`cd path && something` invocation triggers a separate approval from
the plain `something` form.  Don't tack a `cd` onto a command unless
you actually need a different working directory.

In particular:
- `git` operates on the current working tree by default — never
  prepend `cd /path/to/repo && git …`; just run `git …`.
- For commands that *do* need to run somewhere else, prefer the
  command's own working-directory flag (`make -C dir`, `kubectl
  --kubeconfig path`, `git -C dir`, etc.) over `cd dir && …`.
- Use absolute paths when you need to point at a file outside the
  current directory.

If you genuinely need a different `pwd` for a subshell, that's fine
— just don't reach for `cd` reflexively when an in-place form would
do.

## Reloading code mid-session

`reload.el` defines `eltainer-reload`, which byte-compiles and
re-loads every module listed in its
`eltainer-{docker,k8s,…}-modules` defconsts.  Those lists are
captured at reload.el's own load time, which gives two gotchas worth
surfacing to the user proactively whenever you ship a change they
need to reload:

- When *reload.el itself* changes (a new module file, a re-ordered
  load list), `eltainer-reload` won't see the change until reload.el
  is `M-x eval-buffer`'d first.
- The `*eltainer*` dashboard buffer is `eltainer-mode`, not
  `docker-…` / `k8s-…`, so `eltainer-reload` does not refresh it.
  After reload, `g` in the dashboard (or re-running `M-x eltainer`)
  is what makes new launchers / wording appear.

`eltainer-reload` runs `eltainer-stop-all` first (in keep-buffers
mode) to cancel timers and close streams from the *old* code before
the new code redefines anything, so timers don't get orphaned across
a reload.

## Plan docs for non-trivial features

For anything beyond a bug fix or a one-line tweak, get the design
on paper before coding.  If the change spans multiple commits,
multiple files, or a new dependency, check the plan in as
`docs/<feature>-plan.md`.  Convention is established — see
`docs/metrics-plan.md`, `docs/docker-metrics-plan.md`,
`docs/perf-plan.md`, `docs/test-fixtures-plan.md`:

- Lead with `Status: **proposal**` until shipped.
- One short *Goal* paragraph.
- Numbered sections; concrete file references; an explicit
  *Rollout* / *Order of work* at the end.
- Mark "shipped" (or drop the proposal status) once the
  corresponding code lands.  If the plan reshapes
  mid-implementation, update the doc in the same PR.

## README hygiene

After any change that touches the user-visible surface, update
`README.md` in the same PR.  Watch in particular:

- **Key-binding tables** — `Inside the docker view`, `Inside the
  k8s view`, the dashboard launchers, the context-aware `?`
  dispatch.  A new key, a renamed command, a new dispatch entry →
  update the table.
- **External Emacs dependencies** — the `Requirements` section.
  When you `(require 'foo)` a new package anywhere in the source
  tree, add it there; when the last use of a package goes away,
  drop it.  Keep the rationale next to non-obvious entries (the
  `eat` block is the existing pattern).
- **Architecture file list** — the `docker/` / `k8s/` source-tree
  block.  Add new files, drop deleted ones, update the one-line
  descriptions when a module's scope shifts.
- **Inline GIF/demo references** — only update when the recorded
  demo actually changes (`docs/record-demo.sh`); don't claim
  features the GIF doesn't show.

Pure-internal changes (perf fix, refactor with no API change) don't
need a README update.

## Testing

Tests live under `test/` and use ERT.  The harness replays HTTP
responses captured from real clusters via the seam in
`docker/docker-http.el` (`docker-http-request` /
`docker-http-stream`).  Design and conventions:
`docs/test-fixtures-plan.md`.

Add or update an ERT test, driven from a fixture in
`test/fixtures/<scenario>/`, whenever you change:

- JSON parsing or resource-shape handling.
- Magit-section rendering (per-resource inserters, line layouts,
  context-aware bindings).
- Metrics math (gauges, sparklines, rate / ratio computation,
  node-to-series matching).
- Watch-event handling or stream debouncing.
- API path construction or query-string building.

Capture new fixtures by driving eltainer against a live cluster
with the recording layer (see plan), redact sensitive payloads
(`Secret` data, bearer tokens, cert material), then check them in
alongside the test.

When a change genuinely can't be ERT-tested (an interactive UI
gesture, an exec TTY round-trip, real socket lifecycle), say so
explicitly in the PR — don't imply "tested" when it isn't.
