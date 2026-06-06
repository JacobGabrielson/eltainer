# CLAUDE.md — Working notes for Claude in this repo

The behavioural guidelines below are adapted from
[forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills)
— "a single CLAUDE.md file to improve Claude Code behaviour, derived
from Andrej Karpathy's observations on LLM coding pitfalls."  They
bias toward caution over speed.  For trivial tasks, use judgment.

## Think before coding

**Don't assume.  Don't hide confusion.  Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly.  If uncertain, ask.
- If multiple interpretations exist, present them — don't pick
  silently.
- If a simpler approach exists, say so.  Push back when warranted.
- If something is unclear, stop.  Name what's confusing.  Ask.

## Simplicity first

**Minimum code that solves the problem.  Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: *"would a senior engineer say this is
overcomplicated?"*  If yes, simplify.

## Surgical changes

**Touch only what you must.  Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports / variables / functions that *your* changes made
  unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's
request.

## Goal-driven execution

**Define success criteria.  Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "write tests for invalid inputs, then make them
  pass".
- "Fix the bug" → "write a test that reproduces it, then make it
  pass".
- "Refactor X" → "ensure tests pass before and after".

For multi-step tasks, state a brief plan:

```
1. [step] → verify: [check]
2. [step] → verify: [check]
3. [step] → verify: [check]
```

Strong success criteria let you loop independently.  Weak criteria
("make it work") require constant clarification.

These guidelines are working if: fewer unnecessary changes in diffs,
fewer rewrites due to overcomplication, and clarifying questions
come *before* implementation rather than *after* mistakes.

---

The remaining sections are eltainer-specific working notes.

## What eltainer is

A pure Emacs Lisp, magit-style browser for Docker and Kubernetes.
All parsing, UI rendering, and business logic is Elisp; the only
runtime dependencies are a handful of Emacs packages (see
`Package-Requires:` in `eltainer.el` and the README `Requirements`
block).  The user is an expert Elisp developer — keep responses
concise.

## UI conventions — magit by default

The UI must behave like magit: section-based buffers, transient
dispatch menus, single-letter actions, `n`/`p`/`TAB` navigation, `g`
to refresh, `q` to quit, `b` for switch-like actions.  When in doubt,
do what magit does.  Deviate only when the Docker / Kubernetes domain
has no magit-equivalent concept — and call any such deviation out in
the diff (and here, if it'd surprise a contributor).

- All views derive from `magit-section-mode`.
- Buffer names: `*docker:<view>*` / `*k8s:<view>*`; log buffers
  `*docker:logs:<container>*`.
- Use `completing-read` for resource selection and `transient` for
  action menus.
- The full per-view key tables live in `README.md` — keep them there
  (see README hygiene below), not duplicated here.

## Core constraints

- **Pure Elisp only.**  Every line of production code is Emacs Lisp.
- **Talk to the daemon directly over HTTP.**  Both the Docker daemon
  and the Kubernetes API server are reached via `docker-http` (Unix
  socket / TCP / TCP+TLS via built-in GnuTLS).  No `docker` CLI and
  no `kubectl` in production paths.  See `docs/architecture.md`.
- **Native JSON only.**  `json-parse-string` / `json-parse-buffer`
  and `json-serialize`; refuse to load on an Emacs without them.
- **Narrowly-scoped exceptions**, each in a clearly-named helper:
  - Docker: build / buildx (BuildKit gRPC), `docker compose`, CLI
    plugins, `docker login` config writes, `DOCKER_HOST=ssh://…`
    transport, `docker-credential-*` helpers.
  - K8s: `users.exec` credential plugins (`aws eks get-token`,
    `gke-gcloud-auth-plugin`, …).
  Test scaffolding may shell out for sentinel containers; production
  code never does.
- **Target Emacs 30+.**

## Code style

- Always `lexical-binding: t` in the file header.
- Use `cl-lib` (`cl-defstruct`, `cl-loop`, …) — ships with Emacs.
- Public symbols are prefixed by their module (`docker-…`, `k8s-…`,
  `eltainer-…`); internal/private symbols use the double-dash form
  (`docker--…`).
- `defcustom` for user-facing configuration; `defvar` vs `defconst`
  for state vs. reloadable data per the rule further below.

## Watch files, don't poll them

When eltainer needs to react to a file or directory changing on disk
— a kubeconfig appearing, a config being rewritten — use Emacs's
`filenotify` (`file-notify-add-watch`) to get an event, rather than
re-`stat`-ing on a timer or re-globbing the filesystem on every
refresh.  The kubeconfig discovery in `eltainer.el`
(`eltainer--discover-sync-watches`) is the reference pattern: watch
the search dirs, nil the cache in the callback, reconcile the watch
set on each discovery run, and degrade gracefully (re-glob) when a
watch can't be established.

One deliberate exception worth understanding: `k8s-config-load`'s
parse cache stays keyed on the file's mtime rather than a watch.  A
single `file-attributes` stat on access is cheaper than maintaining a
per-file watch, and an mtime key survives the atomic-rename-on-save
that most editors do — which would otherwise strand a `file-notify`
watch on the old inode.  So: reach for `filenotify` for
*directory*-level "did something appear or vanish" detection; a cheap
mtime key is fine for "has this one file I'm about to read changed."

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

### `defvar` vs `defconst` — the silent stale-data trap

`defvar SYMBOL VALUE` only assigns when `SYMBOL` is unbound.
Reloading a file that contains `(defvar foo '...new value...)` is a
**no-op** if `foo` was already bound — Emacs silently keeps the old
value.  This bit us: adding a row to `eltainer-views` (a `defvar`)
made the new dashboard launcher invisible until Emacs restart, even
after `eltainer-reload`.

Rule of thumb:

- **`defconst`** for any top-level data the user might edit and
  expect to pick up on reload — dashboard rows, URL-template tables,
  static lookup maps, default key-binding tables, the
  `eltainer-{docker,k8s}-modules` lists, etc.  `defconst` always
  reassigns on each evaluation.
- **`defvar`** for genuine runtime state: caches, history lists,
  mode-maps populated incrementally, hooks, user-mutable overrides
  (`k8s-context-override` etc.), process / timer handles.

Mode-maps (`*-mode-map`) are usually fine as `defvar` because the
file populates them with `keymap-set` / `set-keymap-parent` *after*
the defvar — those calls re-run on reload and mutate the existing
map.  But never put bindings in the `defvar` initial-value form for
the same reason: they won't get re-applied.

If you find a bug where "I edited the file and reloaded and nothing
changed," the first suspect is a stale `defvar`.

## `Package-Requires:` must stay current

`eltainer.el`'s header carries the package's `Package-Requires:`
list — that's what `package-vc-install` (and `use-package :vc`)
reads to pull in deps automatically.  The README's install
recipe relies on it.  Keep it accurate:

- When a new `(require 'foo)` for an external Emacs package
  lands anywhere in the source tree, add `(foo "X.Y.Z")` to
  `Package-Requires:` — the floor version should be whatever's
  currently shipping on MELPA / NonGNU ELPA / GNU ELPA.
- When the last use of a package goes away, drop the entry.
- If the minimum Emacs version moves (a new built-in feature
  used, a tree-sitter API, etc.), bump the `(emacs "X.Y")` entry.
- Bump the package's own `Version:` header on a user-visible
  shipping change too.  This is the version `package-vc` shows
  in `M-x list-packages`; it's also what users pin against if
  they prefer `:rev "v0.2.0"` over `:rev :newest`.

If unsure of the floor version: check
`~/.emacs.d/elpa/<pkg>-*/` for the version currently installed,
and use that as the floor (older floors are fine too; newer
floors will refuse installs that would otherwise work).

This goes hand-in-hand with the `Requirements` block in
`README.md` — they should never drift apart.

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

## NEWS.md hygiene

`NEWS.md` is a reverse-chronological, user-facing log — Emacs-style.
It is grouped by **date** (`## YYYY-MM-DD`), newest day first.
Under each day sit the features that landed that day as
`### Short feature name`, followed by a short user-perspective
description (a few sentences, optionally a table of new keys).

When a feature ships that's visible to the end user — a new key, a
new view, a new behaviour, a UX change they'd notice — add an
entry to `NEWS.md` in the same commit:

1. If a `## <today's date>` heading already exists at the top of
   the file, prepend the new `### entry` under it.
2. Otherwise, prepend a fresh `## <today's date>` block at the top
   (above any existing day) and put the entry there.

The trigger is the same list as README hygiene above (key tables,
new dependency, new module, demo references).

Do *not* add an entry for:
- Pure-internal refactors that don't change behaviour.
- Performance fixes that aren't visibly faster.
- Plan-doc edits, README rewording, bug fixes that restore
  documented behaviour.
- Test-only changes.

Write from the user's point of view (*"`F` now narrows by label"*),
not the implementation's (*"added eltainer-filter.el"*).  Commit
messages are where the how lives; `NEWS.md` is the what.

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
