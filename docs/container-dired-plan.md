# Plan: dired-equivalent filesystem browse for container/pod contents

Status: **proposal** — review before coding.

## Goal

`f` on a **Docker container** *or* a **Kubernetes pod** opens a
*real* dired buffer — every key the user already presses in dired
works identically (navigation, marking, sort, revert, subdir insert,
later: rename / delete / mkdir / wdired).  Both halves share one
mode and one rendering path; the only thing that differs is "how do
I exec a script in this container."

Today the pods side has `k8s-fs-ui.el`: read-only, emulates *some*
of dired's keys but isn't a real dired buffer — the muscle memory
doesn't transfer.  The docker side has nothing.  This plan replaces
the existing UI with a shared dired-derived mode that fronts both.

## Inspiration / prior art

- **Emacs built-in `dired-mode`** — the target UX.
- **TRAMP `docker:` / `kubectl:` methods** — explicitly rejected.
  Eltainer's no-CLI thesis ([README](../README.md#philosophy))
  rules out shelling to `docker` / `kubectl` without an explicit
  exception (CLAUDE.md, top of file).  We use the engine APIs.
- **`docker-tramp`, `kubernetes-tramp`** — same caveat.

## 1. Architecture (decided)

Derive from `dired-mode`, synthesise `ls -al`-shaped lines, override
the I/O hooks.

| | derive from `dired-mode` (chosen) | emulate / custom mode | TRAMP |
|---|---|---|---|
| Muscle memory | ✅ identical | 🟡 close, drifts | ✅ identical |
| Maintenance | 🟡 follow dired's internals | 🟢 self-contained | 🟢 zero |
| CLI-free | ✅ | ✅ | ❌ pulls `docker`/`kubectl` |
| Operations (rm, mv, …) | inherit dired's UI; override action | re-implement each | inherits TRAMP magic |

Derive wins on muscle-memory + the implicit "every dired
operation we don't override just works against a list of marked
files".  The CLI constraint kills the TRAMP option.

## 2. Module layout

Shared parent + per-backend leaves.  No code duplication between
the docker and k8s halves.

```
eltainer-fs.el         struct, POSIX list / stat / cat shell
                       scripts, line parser.  Backend-agnostic.
eltainer-dired.el      `eltainer-dired-mode' parent (derived from
                       `dired-mode'): sentinel-path parser, ls-al
                       text synthesis, hook overrides, marker for
                       "this is one of ours".  Holds buffer-local
                       function slots (`-list-fn', `-stat-fn',
                       `-cat-fn', `-exec-fn') the children plug.

docker/docker-fs.el    docker-exec-run wrapper around the shared
                       scripts.  Plus archive-API helpers for
                       the cat / cp fast path (see §6).
docker/docker-dired.el `docker-dired-mode' (derived from
                       eltainer-dired-mode); plugs in docker
                       backends; entry point `docker-dired-browse'.

k8s/k8s-fs.el          (refactored) k8s-exec wrapper around the
                       shared scripts.  Loses the script + parser
                       + entry struct (moved up).
k8s/k8s-dired.el       `k8s-dired-mode' (derived from
                       eltainer-dired-mode); plugs in k8s
                       backends; entry point `k8s-dired-browse'.
```

Function-slot indirection (rather than a `pcase` over kind) is what
makes the unification cheap: each child mode binds its three or
four backend functions buffer-locally; the parent never knows
whether it's talking to docker or k8s.

## 3. Sentinel paths (decided shape)

Used as `buffer-file-name` so dired's `dired-get-filename` /
`dired-current-directory` return the right thing.

```
docker:    /docker:<container>:/<path-inside-container>
k8s:       /k8s:<ns>/<pod>[<container>]:/<path-inside-container>
```

The `[<container>]` suffix on the k8s form is required for
multi-container pods so same-pod-different-container buffers don't
collide on `buffer-file-name`.

Helpers in `eltainer-dired.el`:

- `eltainer-dired--parse-path PATH` → plist `(:backend docker|k8s
  :container ID :ns NS :pod POD :pod-container C :remote PATH)` or
  nil.
- `eltainer-dired--make-docker-path CONTAINER PATH` and
  `eltainer-dired--make-k8s-path NS POD CONTAINER PATH` for builders.

These paths *look* like TRAMP.  We **do not** register a TRAMP
method — `file-name-handler-alist` stays untouched.  We recognise
the prefix ourselves at every entry point that takes a filename
(`find-file`, `dired-find-file`, etc.) and redirect.

## 4. Buffer construction

Dired's parser expects `ls -al`-shaped lines (`dired-re-inode-size`
roughly):

```
  drwxr-xr-x  3 root root      4096 May  1 12:34 .
  drwxr-xr-x  3 root root      4096 May  1 12:34 ..
  -rw-r--r--  1 root root       512 May  1 12:31 app.yaml
  lrwxrwxrwx  1 root root         9 May  1 12:30 link -> realfile
```

Every field is already in the `eltainer-fs-entry` struct (mode as
rwx, nlink, owner, group, size, mtime, name, link target).
`eltainer-dired--emit-entries` formats them into the dired line
shape; dired does the rest.

Header line: dired's `total 0` plus the sentinel as the directory
header, so `dired-current-directory` returns the right thing for
the listing block.

## 5. I/O hooks to override

| Dired entry point | Eltainer redirect |
|---|---|
| `dired-find-file` | Visit-in-buffer via `eltainer-dired--cat-fn` (read-only). |
| `find-file-noselect` for a sentinel path | Same. |
| `revert-buffer` (`g`) | Re-call `eltainer-dired--list-fn`, re-render. |
| `dired-do-delete` (`D`) | v1: `user-error` pointing to this plan.  v2: `--exec-fn rm`. |
| `dired-do-rename` (`R`) | v1: error.  v2: `--exec-fn mv`. |
| `dired-do-copy` (`C`) | v1: error.  v2: docker archive API (§6), or `--exec-fn cp` for k8s. |
| `dired-create-directory` (`+`) | v1: error.  v2: `--exec-fn mkdir`. |
| `wdired-finish-edit` | v2 only. |

Overrides are gated on `(derived-mode-p 'eltainer-dired-mode)` so
global dired behaviour stays untouched in any other dired buffer
the user has open.

## 6. Docker-uniquely: the archive API

The Docker Engine exposes
[`/containers/<id>/archive`](https://docs.docker.com/reference/api/engine/version/v1.47/#tag/Container/operation/ContainerArchive)
— `GET` streams a tar of any path; `PUT` accepts one.  That means
the *file-read* + *file-write* / *cp* paths can bypass exec
entirely:

- **`cat` (file visit) on docker** → `GET /containers/<id>/archive
  ?path=/etc/foo`, untar in-process, hand the file body to the
  visit-buffer.  **No `sh` or `cat` binary needed inside the
  container.**  Works on distroless / scratch when the path is
  known.
- **`C` (copy host↔container)** in v2 → PUT/GET archive, no
  in-container `cp` binary.

This is the one place docker is *better* than k8s.  k8s has no
analogous endpoint, so the k8s-dired `cat` keeps exec'ing `cat`.

**Listing** still needs `sh + find + stat`.  No API endpoint
returns "the entries in this directory with stat info"; that's
why distroless directories remain unbrowsable on either backend
(same hard limit as today's `k8s-fs.el`).

## 7. v1 scope (read-only)

Shipped behaviour:

- Navigation: `n p RET ^ < > o C-d C-u`.
- Marking + the full dired mark set (`m u U t DEL M-DEL * ! * ?` —
  the same set we already standardised for the resource views).
- Visit file (`RET` / `f`) opens a read-only buffer with the
  file's contents via the buffer's `-cat-fn`, capped at the
  existing `eltainer-fs-max-cat-bytes`.
- `g` reverts.
- `i` inserts a subdirectory (re-renders just that block in dired's
  conventional shape).
- `s` sort (pure dired; works once the buffer parses).
- `(` / `)` toggle the detail block.

Explicit non-goals (clear `user-error` so the muscle-memory press
doesn't silently misbehave):

- `D` delete, `R` rename, `C` copy, `+` mkdir, `M` chmod, `O` chown,
  `T` touch.
- Distroless / scratch container *directories* (same constraint as
  today; friendly error already shipped in `6c2b060`).

## 8. v2 scope (writable)

Each operation maps to one engine-API call or one exec.

| Op | docker backend | k8s backend |
|----|----------------|-------------|
| `D` delete | `--exec-fn` running `rm -rf "$@"` after confirmation | same |
| `R` rename | `--exec-fn mv "$src" "$dst"` | same |
| `+` mkdir | `--exec-fn mkdir -p` | same |
| `C` copy (in-container) | `--exec-fn cp -r` | same |
| `C` copy host↔container | `PUT /containers/.../archive` (no exec) | `--exec-fn` + chunked tar |
| `wdired-finish-edit` | diff old/new buffer, emit one `mv` per renamed line | same |

A single `command -v rm mv mkdir cp` probe runs lazily on the
first write and caches the result on the buffer.  If the
container lacks the binary, the operation fails with a clear
"this container has no `rm` (distroless or scratch image)"
message.

## 9. `k8s-fs-ui.el` retirement (decided)

Hard replace.  Once `k8s-dired-browse` lands and `f` in the pods
view points at it, `k8s-fs-ui.el` is deleted in the same commit.
A short note in the commit message + README references explain the
change.

`k8s-fs.el` (the *non-UI* layer) stays — it's the backend the new
mode plugs into; the shared scripts/struct move *up* into
`eltainer-fs.el`, leaving k8s-fs.el as the k8s-exec wrapper.

## 10. Risks / open questions

- **Dired internals stability.**  We tie into the parser, the mark
  format, and a handful of operation entry points.  Emacs reshapes
  dired occasionally (subdir layout, marker char, wdired).  Test
  against Emacs 30 and 31 (we already require 30+).
- **Docker exec hijack vs. listing.**  The current
  `docker-exec.el` is interactive-only (eat-backed TTY).  We add a
  small sync collector — `docker-exec-run` — for the one-shot
  listing / rm / mv path.  Returns `(EXIT-CODE STDOUT STDERR)`.
- **Sentinel-path collision with TRAMP.**  `/docker:` and `/k8s:`
  prefixes could theoretically conflict with a user-registered
  TRAMP method.  We don't go through `file-name-handler-alist`,
  so no functional clash; if the user has TRAMP `/k8s:` configured
  for the same prefix, `find-file /k8s:…` would route through
  TRAMP, not eltainer.  Acceptable; flagged in the README's
  "Things to know".
- **`docker-exec-run` and the archive API are both new docker-side
  surface.**  Worth one round-trip's worth of byte-buffer testing
  to make sure the tar parsing doesn't choke on edge cases
  (sparse files, symlinks, owner/uid serialisation).

## 11. Testing

Per `docs/test-fixtures-plan.md`:

- `docker-fs-listing` fixture — recorded `docker-exec-run`
  responses for `/`, `/etc`, `/var/log` (with a symlink and a
  subdir) against a small busybox container.
- `microk8s-pod-fs-listing` — k8s analogue.
- `docker-fs-archive-roundtrip` — recorded
  `GET /containers/.../archive` responses for a small file + a
  symlink + an empty directory.
- Snapshot test: render the buffer, assert
  `(dired-get-marked-files)` works, marks survive `g`, navigation
  hits the expected lines.
- Negative test: distroless fixture — assert the friendly error
  fires (regression hook for `6c2b060`).
- v2 tests use replay fixtures of the exec / archive responses.

## 12. Order of work — docker first

Vertical slices.  Each step ships independently.

1. **Refactor: extract `eltainer-fs.el`.**  Move the list/stat
   scripts, the `eltainer-fs-entry` struct (renamed from
   `k8s-fs-entry`), the line parser, and the friendly
   distroless-error regexp out of `k8s-fs.el` into the new shared
   module.  `k8s-fs.el` becomes a thin k8s-exec wrapper around
   them.  No behaviour change for the existing k8s-fs-ui path.
2. **`docker-exec-run`.**  Sync collector built on top of the
   existing `docker-exec--start-hijacked` / `docker-stream-make-
   demux`.  Returns `(EXIT-CODE STDOUT STDERR)`.  Reused by both
   the new `docker-fs.el` and any future "run-this-and-tell-me"
   docker tool.
3. **`docker-fs.el`.**  `docker-fs-list` / `docker-fs-stat` /
   `docker-fs-cat`.  Cat uses the archive API for the distroless
   bonus; list / stat use `docker-exec-run` with the shared
   scripts.
4. **`eltainer-dired.el`.**  Parent mode (derived from
   `dired-mode`), sentinel-path parser, ls-al emitter, hook
   overrides, function-slot fields.  Hard work; entirely backend-
   agnostic.
5. **`docker-dired.el`.**  Tiny: define `docker-dired-mode`
   inheriting from `eltainer-dired-mode`, plug in the docker
   backends, expose `docker-dired-browse`.  Bind `f` in
   `docker-containers-mode-map`.  *This is the user-visible v1
   ship on the docker side.*
6. **`k8s-dired.el`.**  Same pattern, plugs in k8s backends,
   exposes `k8s-dired-browse`.
7. **Switch the pods view `f`** from `k8s-pod-browse-at-point`
   (current `k8s-fs-ui.el` entry point) to `k8s-dired-browse`.
   Delete `k8s-fs-ui.el`.  *This is v1 ship on the k8s side.*
8. **README + fixtures + tests.**
9. **(v2)** writable operations across both backends, per §8.
10. **(future)** `kubectl debug`-style ephemeral debug container
    injection for distroless directory listing — out of scope for
    this plan, lives in its own doc.

Steps 1–5 are the docker v1 slice; 6–8 finish the k8s v1 slice on
top of the same shared parent.
