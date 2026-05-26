# Plan: filter / narrow views by label

Status: **shipped** — k8s + docker containers view both support `F`.

## Goal

Let the user narrow any resource view to entries matching a label
selector, without leaving the magit-section view.  Common case:
"show me only the pods in the `bookstore-api` deployment" or "show me
only `tier=frontend` services across the cluster".

Today the only filter we have is namespace (`N`).  This adds a
second axis.

## 1. Keystroke surface

Reviewed alternatives:

- **`/` prefix (ibuffer)** — natural muscle memory but conflicts
  with `isearch-forward-regexp` if the user has rebound `C-s`, and
  in magit-section buffers `/` is sometimes a search prefix.
- **`L` (capital)** — currently unbound across our views; only
  collision is the multipod-log binding `L` in `k8s-pods-mode-map`,
  which we *do* want to preserve.  So this is out for the pods view.
- **`l` (lowercase)** — taken by "tail logs" on the pods view.
- **`F` (capital)** — "filter".  Unbound everywhere.  Clear.

**Decision: `F` is the filter prefix.**  It mirrors `N` (narrow by
namespace) so the two filters compose visually:

```
F l <selector>    add a label selector
F n <regex>       narrow by name regex (also useful)
F c               clear the filter
F F               show the active filter in the echo area
```

`F` alone (with no follow-up) opens a transient with the same four
choices.  The transient gives discoverability; the direct two-key
form gives speed.

## 2. Selector syntax

Accept the standard k8s `labelSelector` mini-language exactly as
`kubectl` accepts it:

- `key=value` / `key==value` — equality
- `key!=value` — inequality
- `key` — presence (truthy match)
- `!key` — absence
- `a=b,c=d` — AND across comma-separated terms

No client-side parsing required — the API server understands this
verbatim as a query-string param.

## 3. Server-side vs client-side

**Server-side wins.**  The K8s API takes `?labelSelector=` on every
list endpoint we hit (`k8s-list-pods`, `k8s-list-services`, …).
Pushing the filter to the server:

- Saves bandwidth (often a *lot* — a cluster with 5k pods rendering
  the 3 we care about is wasteful).
- Composes correctly with existing `?fieldSelector=` (namespace
  filter).
- Makes the API call deterministic — no "what if a label changes
  between watch and re-render" race.

We thread one optional `:label-selector` keyword down through
`k8s-list-pods` / `k8s-list-services` / etc. — `k8s-api.el` already
builds the query string; this is a one-line addition per `list`
function.

For *docker* — labels exist on containers (`docker run --label`).
The list endpoint doesn't take a `labelSelector` query but does
accept `filters=` JSON, e.g.
`?filters={"label":["env=prod","tier=web"]}`.  Same shape from the
user's perspective, different wire format.  Add per-backend
encoding in the same `:label-selector` keyword and let
`docker-list-containers` / `k8s-list-pods` translate.

## 4. UX details

- The filter is **buffer-local** — namespace+label filter pair is
  per view buffer, not global.  `g` (refresh) preserves it; `q`
  destroys it.
- The header line shows the active filter:
  ```
  K8s:Pods  bookstore  label:tier=frontend
  ```
- `F c` clears.  `F F` echoes the current value (useful for the
  "wait, what am I filtering on?" moment).
- The transient (`F`) closes itself after the user picks a sub-key,
  so the experience is "press `F l`, type selector, RET".

## 5. Module layout

One new file: `eltainer-filter.el` (top-level shared, like
`eltainer-fs.el` / `eltainer-dired.el`):

- `eltainer-filter` struct: `(namespace label-selector name-regex)`.
- `eltainer-filter-format` for the header-line summary.
- `eltainer-filter-prompt` — `completing-read` with history; for
  labels, completion candidates pulled from the most-recent
  successful list call (we already have the resources in memory).
- The transient.

Per-view changes (k8s-pods.el, k8s-services.el, …):

- New buffer-local `k8s-pods--filter` (etc.) of type
  `eltainer-filter`.
- `(k8s--pods-refresh)` threads the filter into `k8s-list-pods`.
- Refresh / watch reconnection re-applies it.

Docker side:

- `docker/docker-filter.el` translates `eltainer-filter` →
  `?filters=` JSON for the engine API.
- `docker-list-containers` etc. accept `:label` already? — if not,
  add.

## 6. Order of work

1. **`eltainer-filter.el`** — struct, prompt, transient.
2. **K8s wiring** — `k8s-list-pods` accepts `:label-selector`,
   `k8s-pods` buffer-local filter, refresh path threads it.  Bind
   `F` in `k8s-common-map`.
3. **Header-line summary** — small, polish.
4. **Other k8s views** — services, deployments, etc., copy the
   pattern.
5. **Docker side** — engine-API filter translation, `F` in
   `docker-containers-mode-map`.
6. **Tests** — selector serialiser (label/key/!key/comma-AND),
   filter-prompt completion candidates, integration test with a
   live cluster (drop a pod with a label, filter, assert it's the
   only one shown).

## 7. Risks / open questions

- **Watch streams + filters.**  When we re-list with a filter, the
  next watch stream must also be opened with the filter applied
  (otherwise we'd start getting events for unrelated resources).
  `k8s-watch.el` takes a `path` already; threading the query string
  in is mechanical but needs explicit handling.
- **`F c` clearing vs `g`** — does `g` clear or preserve the filter?
  Decision: preserve.  `g` is "refresh, same view"; `F c` is "ditch
  the narrowing".
- **Field selectors** — k8s also supports `fieldSelector` (e.g.
  `status.phase=Running`).  Same shape but mostly useful for pods.
  Defer to a follow-up (`F p` for phase?) — don't bloat v1.
