# Plan: dired-equivalent filesystem browse for container/pod contents

Status: **proposal** — review before coding.

## Goal

`f` on a Pod (or eventually a Docker container) opens a *real* dired
buffer — every key the user already presses in dired works the same
way: `n`/`p` navigate, `^` goes up, `RET` visits a file, `m`/`u`/`U`/
`t` mark, `D` deletes, `R` renames, `s` sorts, `(`/`)` toggle the
detail block, `g` reverts, `i` inserts a subdir.  No relearning.

Today eltainer has `k8s-fs.el` + `k8s-fs-ui.el`: read-only browser
that emulates *some* of dired's keys but isn't a real dired buffer.
Useful, but the muscle memory doesn't transfer; this plan replaces
it with the real thing.

## Inspiration / prior art

- **Emacs built-in dired** — the target UX.
- **TRAMP `docker:` / `kubectl:` methods** — the obvious shortcut, but
  they shell out to the `docker` / `kubectl` CLIs.  Eltainer's whole
  thesis is "pure Elisp talking to the engine API" (see the README's
  *Philosophy* section); using TRAMP here would break that and pull
  in CLI dependencies we've explicitly avoided.
- **`docker-tramp`, `kubernetes-tramp`** — same caveat.

So the path is "derive from `dired-mode`, intercept the I/O hooks,
keep everything else."

## 1. Inheritance vs. emulation

There are three viable architectures.  We pick A.

| | A. derive from `dired-mode` | B. emulate dired in our own mode | C. wdired-only / TRAMP |
|---|---|---|---|
| Muscle memory | ✅ identical | 🟡 close but drifts | ✅ identical |
| Maintenance | 🟡 follow dired's internals | 🟢 self-contained | 🟢 zero — TRAMP owns it |
| CLI-free | ✅ | ✅ | ❌ pulls `docker`/`kubectl` |
| Operations (delete, rename, …) | inherit dired's UI, override the action | re-implement each | inherit TRAMP magic |
| Buffer-as-file semantics | reuses dired's | none for free | reuses TRAMP's |

**A** wins.  Concretely: a new major mode `k8s-dired-mode` derived
from `dired-mode`, populated by code that synthesises a fake
`ls -al`-shaped buffer from `k8s-fs-list`'s output, with the
file-operation entry points re-routed through container exec.

## 2. Buffer construction

A real dired buffer's parser expects lines that match
`dired-re-inode-size` (basically: `ls -al` output).  The trick is to
emit text dired can already parse.

Pseudo-`ls -al` line shape:

```
  drwxr-xr-x  3 root root      4096 May  1 12:34 .
  drwxr-xr-x  3 root root      4096 May  1 12:34 ..
  -rw-r--r--  1 root root       512 May  1 12:31 app.yaml
  lrwxrwxrwx  1 root root         9 May  1 12:30 link -> realfile
```

Every field is already in `k8s-fs-entry`: mode (we have rwx), nlink,
owner, group, size, mtime, name, link target.  Format-string it into
the existing dired line shape and dired's parser does the rest —
`dired-get-filename`, navigation, marking, all of it.

Header line: a dired "ls" header — `total 0` plus the sentinel path
as a directory header — so `dired-current-directory` returns the
right thing.

## 3. Sentinel paths for `buffer-file-name`

Dired identifies files by their *path*.  Container files don't have
host-side paths.  Use a TRAMP-shaped sentinel that eltainer owns:

```
/k8s:<ns>/<pod>[<container>]:/<path-inside-container>
```

Example:

```
/k8s:default/bookstore-api-5d747c9489-7nq87[api]:/usr/share/nginx/html
```

Two things to know:

- These paths look like TRAMP, but eltainer *does not* register a
  TRAMP method — `file-name-handler-alist` stays untouched.  We
  recognise the prefix ourselves at every entry point that takes a
  filename (`find-file`, `dired-find-file`, etc.) and redirect.
- For multi-container pods, the `[container]` suffix is required so
  same-pod different-container buffers don't collide on
  `buffer-file-name`.

Helpers:

- `k8s-dired--parse-path PATH` → `(NS POD CONTAINER REMOTE-PATH)` or
  nil if not one of our sentinels.
- `k8s-dired--make-path NS POD CONTAINER PATH` → the string.

## 4. I/O hooks to override

Dired calls into a known set of file-handling functions; intercept
each one.

| Hook | Eltainer redirect |
|------|-------------------|
| `dired-find-file` | Visit-in-buffer via `k8s-fs-cat` (read-only). |
| `find-file-noselect` for a sentinel path | Auto-detect, drive `k8s-fs-cat`. |
| `revert-buffer` (`g`) | Re-call `k8s-fs-list`, re-render. |
| `dired-do-delete` (`D`) | v1: error "read-only — see v2".  v2: `k8s-exec rm`. |
| `dired-do-rename` (`R`) | v1: error.  v2: `k8s-exec mv`. |
| `dired-do-copy` (`C`) | v1: error.  v2: in-container `k8s-exec cp` or eltainer-side copy via `cat + cat >'. |
| `dired-create-directory` (`+`) | v1: error.  v2: `k8s-exec mkdir`. |
| `wdired-finish-edit` | v2 only. |

The override mechanism: per-mode `(setq-local
dired-file-handler-function …)` style indirections where dired
exposes them, plus `advice-add` on the few that don't.  We keep the
advice gated on `(eq major-mode 'k8s-dired-mode)` so global dired
behaviour stays untouched.

## 5. Subdirectories (`i`)

Dired supports inserting a subdirectory in the same buffer (`i`).
For us:

1. `i` → resolve the directory at point to its sentinel path.
2. Call `k8s-fs-list CONN NS POD CONTAINER SUBDIR`.
3. Render that subdir block in the dired-conventional way (header
   line + blank + entries) and re-let dired's parser pick it up.

Subdir `g` / `^` / etc. then work for free.

## 6. v1 scope (read-only)

What v1 ships:

- Navigation: `n p RET ^ < > o C-d C-u`.
- Marking + the full dired mark keymap (now matches what we already
  did for the resource views — `m u U t DEL M-DEL * ! * ?`).
- Visit file (`RET` / `f`) opens a read-only buffer with the file's
  contents via `k8s-fs-cat`, capped at `k8s-fs-max-cat-bytes`.
- `g` reverts.
- `i` inserts a subdirectory.
- `s` sorts (this is pure dired; works once the buffer parses).
- `(` / `)` toggle the detail block.

What v1 explicitly does **not** do (clear error if attempted):

- `D` delete, `R` rename, `C` copy, `+` mkdir, `M` chmod, `O` chown,
  `T` touch.  Each is a known dired binding; we override to a
  `user-error "k8s-dired v1 is read-only — see docs/container-dired-plan.md"`
  so the muscle-memory press doesn't silently misbehave.

What v1 also doesn't do:

- Distroless / scratch containers.  Same constraint as `k8s-fs.el`
  today — the listing script needs `sh + find + stat`.  v1 reuses
  the existing friendly error.

## 7. v2 scope (writable)

Each operation maps to a single `k8s-exec` call against the
container.  Order of work:

1. `D` — `rm -rf` with confirmation that lists every marked file.
2. `R` — `mv "$src" "$dst"`.
3. `+` — `mkdir -p`.
4. `C` — `cat "$src" | …` round-trip through eltainer (single-file
   only at first); in-container `cp` for the same-pod case.
5. `wdired-finish-edit` — diff the wdired buffer against the
   pre-edit state, emit one `mv` per renamed line, apply
   atomically.

Each operation gates on the container having the needed binary.
A single probe step (`k8s-exec sh -c 'command -v rm mv mkdir cp'`)
runs lazily on first write and caches the result on the buffer.

## 8. Relationship to the existing `k8s-fs-ui.el`

Two options, listed for review:

- **Hard replace** — delete `k8s-fs-ui.el`, rebind `f` to the new
  `k8s-dired` entry point.  Cleaner, but a behaviour change for
  anyone who had muscle memory on the existing UI.
- **Coexist + flag** — keep `k8s-fs-ui.el` as the default for one
  cycle, add `k8s-dired` behind `eltainer-use-dired-browse` (custom,
  default nil).  Flip the default once v1 lands.  Migrate users
  gently.

Recommendation: **hard replace.**  `k8s-fs-ui.el` is small and the
dired version supersedes it on every axis we care about; carrying
both adds noise.  The plan-doc + a commit message + a README note
explain the change.

`k8s-fs.el` (the *non-UI* layer with `k8s-fs-list` /
`k8s-fs-stat` / `k8s-fs-cat`) stays.  The new mode is a UI layered
on top.

## 9. Docker side (v3, parked)

Docker containers have the same exec primitive (`docker-exec.el`'s
non-TTY hijack).  The same dired-derived mode could front both:

- Generalise the sentinel scheme: `/k8s:…:` for pods,
  `/docker:<container>:/<path>` for docker.
- Push the parse + emit + override down to an `eltainer-dired-mode`
  parent; `k8s-dired-mode` and `docker-dired-mode` inherit and plug
  in their respective `list` / `cat` / exec backends.

Not in v1 scope; called out so v1's interfaces don't paint the
docker path into a corner.

## 10. Risks / open questions

Things I'm assuming and would push back on if asked again:

- **Dired internals are stable enough.**  We tie into `dired-mode`'s
  parser, mark format, and a handful of functions.  Emacs has
  reshaped dired before (subdir layout, marker char, wdired).  The
  shim should test against Emacs 30 and 31; behaviour on older
  Emacs versions is out of scope (we already require 30+).
- **No TRAMP integration.**  We *intentionally* don't register a
  TRAMP method (per the README's no-CLI thesis).  Users who'd
  prefer `C-x C-f /docker:foo:/etc/hosts` keep using TRAMP — we
  don't compete.
- **Distroless coverage is a non-goal.**  v1 needs sh + coreutils.
  A future `kubectl debug`-style ephemeral-debug-container path is
  the right answer for distroless and lives in its own plan.
- **Sentinel-path collision with TRAMP.**  `/k8s:` could
  theoretically conflict with a user-registered TRAMP method.  We'd
  detect (`tramp-methods` lookup) at load time and message a
  warning; the eltainer commands don't go through
  `file-name-handler-alist` so there's no functional clash, only
  cosmetic confusion if they type the same prefix into `find-file`.

## 11. Testing

Per `docs/test-fixtures-plan.md`:

- New fixture `microk8s-pod-fs-listing` — recorded `k8s-fs-list`
  responses for a pod's `/`, `/etc`, `/var/log` (with a symlink
  and a subdir).
- Snapshot test: render the buffer, assert
  `(dired-get-marked-files)` works, marks survive `g`, navigation
  hits the expected lines.
- Negative test: distroless container fixture — assert the
  friendly error fires (already done; just a regression hook).
- v2 only: write-op tests using replay fixtures of the exec
  responses for `rm` / `mv` / `mkdir`.

## 12. Order of work

1. **Path helpers** — `k8s-dired--parse-path` / `--make-path`,
   plus the regexp registered.  Trivial; lets the rest reference
   them.
2. **List → dired text** — convert `k8s-fs-list`'s entries into
   `ls -al`-shaped lines + header.  Verify dired's parser accepts
   them (in a one-shot scratch test, no major mode yet).
3. **`k8s-dired-mode`** — derive from `dired-mode`, render in the
   buffer, set `buffer-file-name` to the sentinel.  At this point
   navigation + marking work (dired does the heavy lifting).
4. **Visit-file path** — intercept `dired-find-file' for sentinel
   buffers; route through `k8s-fs-cat'.  Read-only result buffer.
5. **`i` subdir** — re-call `k8s-fs-list' for the subdir, insert in
   the existing dired-conventional shape.
6. **`g' revert** — `setq-local revert-buffer-function`.
7. **Read-only guard** — override `dired-do-delete` / `-rename` /
   `-copy` / `dired-create-directory` to a clear `user-error`.
8. **Hook `f`** on the pods view to `k8s-dired-browse` (replacing
   the current `k8s-pod-browse-at-point' indirection through
   `k8s-fs-ui.el`).  Retire `k8s-fs-ui.el'.
9. **README + fixture + test.**
10. **(v2)** writable operations as described in §7.
11. **(v3)** docker-side `docker-dired-mode' on top of a shared
    `eltainer-dired' parent.

Each step ships independently; the v1 vertical slice is steps 1–9.
