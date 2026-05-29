# Plan: always-visible "what can I do here" key hints

Status: **proposal** — review before coding.

## Goal

Surface, at all times, the keys available at point — like having
`?` permanently pressed, but fast and unobtrusive.  Universal:
works in any buffer with a major mode, not just eltainer's
views.  Eltainer's views get a richer, curated rendering; every
other mode gets a sensible auto-extracted fallback.

## 1. Where the hint lives

**Decision: user-configurable** between mode-line (default) and a
1-line side window at the bottom of the frame.  The defcustom
`key-hints-position` (see §3) picks between the two.  The two
backends share the same string-builder; only the renderer
changes:

- **`'mode-line` (default)** — extend `mode-line-format` with an
  `:eval` segment that renders the current context's hints
  inline.  Zero new pixels.  Mode-line `:eval` re-runs on every
  redisplay — fast, no flicker, no extra repaint mechanism to
  invent.
- **`'side-window`** — a 1-line side window pinned to the bottom
  of the frame via `display-buffer-in-side-window` with
  `:window-height 1`.  Roomier (no competition with the
  mode-line's filter / watch indicators) at the cost of one
  vertical line.  Same content; updated by a small
  `post-command-hook` that re-renders the buffer when the
  cache key changes.

Why not a posframe / child frame:
- External-dep adjacent (posframe is not in core); child-frame
  primitives flicker on some toolkits.

Why not the echo area:
- Mode-line / side-window are *persistent* status strips; echo
  area is for *transient* messages.  Hijacking it would clobber
  things like `message`.

Format (same for both backends), fitting in ~50 chars in
mode-line, wider in the side-window:

```
  l logs  e exec  f browse  M metrics  K kill  +5
```

The trailing `+5` is a hint that more keys exist; press `?`
(eltainer views) or `C-h m` (anywhere) for the full menu.

## 2. Sources of truth

### (a) Curated — per major-mode registry

`key-hints-register MODE ITEMS` populates the registry.  Items are
`(KEY LABEL [PRIORITY])` lists.  **The strip is "most important
first"**: items are rendered in `PRIORITY`-desc order (default
priority `5`; higher = more important), with `(KEY . LABEL)`
order tie-breaking by registration order.

When the strip overflows the budget (`key-hints-max-items`),
the rightmost items drop first.  The trailing `+N` indicator
makes it obvious that something was hidden.

Eltainer's views register their own.  A pod row's keys
(`l logs e exec f browse M metrics K kill`) come from the
existing `?`-dispatch's data table — refactor to read from the
same registry so cheats + transient stay in sync.

Concrete priority guidance for eltainer views:

| Priority | Bucket                                             |
|----------|----------------------------------------------------|
| 10       | The single action users open the view to do (`l` logs on Pods, `c` exec on Containers) |
| 7        | Common context-aware actions (`e`, `f`, `K`)       |
| 5        | Mode-wide helpers (`g`, `N`, `F`)                  |
| 3        | Rare-but-useful (`T` xray, `Y` edit YAML)          |
| 1        | Anything kept "just in case" (mostly invisible)    |

### (b) Auto-extracted — fallback for everything else

When the current mode has no registry entry, walk the major
mode's keymap:

- Single-key bindings only (skip prefixes; `C-x`-class is too
  noisy for this strip).
- Filter out global no-ops (`self-insert-command`,
  `digit-argument`, navigation that's universal:
  `next-line`/`previous-line` etc.).
- Annotate each command's name with the first line of its
  docstring (truncated).  Cache the lookup.

Quality won't match the curated rendering — but it's something,
and good enough for the bulk of "what's `R` for in this `mu4e`
buffer?" moments.

### (c) Context-aware override

Buffer-local hook `key-hints-context-function` returns a list of
items, taking precedence over (a) and (b).  Eltainer's pods view
sets it to "look at the section at point, choose pod-keys vs
container-keys" — mirrors the `?`-transient's `:if` predicates.

When point moves between sections of different types, the
mode-line refresh re-runs the function and the strip updates
naturally.

## 3. Customization surface (standard `defcustom`s)

```elisp
(define-minor-mode key-hints-mode
  "Show a compact key-hint strip contextualised to the buffer /
section at point.

Renders into either the mode-line or a 1-line side window
depending on `key-hints-position'."
  :global t
  :init-value t                         ; on by default --
                                        ; new feature; users
                                        ; need to learn it
  :group 'key-hints)
```

The mode is on by default.  Users who find it noisy can flip it
in `M-x customize-group key-hints` or with a one-liner in their
init file.

Other knobs (all `defcustom`):

- `key-hints-position` — `'mode-line' (default) or `'side-window'.
  See §1.  Both backends share the same string builder; flipping
  this value re-renders without restart.
- `key-hints-max-items` (int, default 6) — how many hints to
  render before showing `+N`.
- `key-hints-truncate-label-width` (int, default 8) — per-label
  max chars.
- `key-hints-show-modes` / `key-hints-hide-modes` — alists
  restricting which major modes the strip activates in.
  Default hide-list: `minibuffer-mode', `Buffer-menu-mode',
  `image-mode' -- anywhere the mode-line is cramped or the
  cursor doesn't choose bindings.
- `key-hints-separator` (string, default `"  "`) — between items.
- `key-hints-side-window-height` (int, default 1) — only
  consulted when `key-hints-position' is `'side-window'.

## 4. Update strategy + perf

`mode-line-format` is re-evaluated on every redisplay.  Compute
cheaply or risk visible lag.

Compute the hint string in `key-hints--current-string`:

1. Build a cache key: `(major-mode . current-section-type . filter-version)`.
2. Look up; cached string returns immediately.
3. Miss → run the chain in §2, build the truncated string, cache,
   return.

Cache key changes pick up the natural redisplay tick — no
post-command-hook needed for the common case.

Section-aware caching: in `magit-section-mode`-derived buffers
the cache key includes the section type under point, refreshed
via `magit-section-set-visibility-hook` or a small
`post-command-hook` that compares `(oref (magit-current-section) type)`.

Worst case: a few hash-table lookups + a string concat per
redisplay.  Cheaper than the metrics polling we already do.

## 5. Module layout

One new file: `key-hints.el` (top-level shared, alongside
`eltainer-ui.el`).

```elisp
;; key-hints.el
;; - Defcustom surface, registry, fallback extractor.
;; - `key-hints-mode' (global minor mode).
;; - `key-hints--current-string' (mode-line :eval target).
```

Eltainer's views register on load (one `key-hints-register` call
per mode) — five-line addition per file, no rewrite.

For non-eltainer users the package is standalone — they can
`(require 'key-hints)` from any init file.  No eltainer
dependency leaks into it.

## 6. Rollout

1. **`key-hints.el` skeleton** — defcustoms, registry, mode-line
   plumbing.  Hard-coded test data renders.
2. **Auto fallback** — major-mode keymap walker + docstring
   annotator.  Demo: enable in `dired-mode`, see hints for `g d
   m u`.
3. **Wire one eltainer view** — register pods-view keys.  Verify
   section-aware re-render across the row navigation.
4. **Refactor `?`-dispatch** — pull pod-row keys from the same
   registry; verify menu + strip stay in sync.
5. **Roll across all eltainer views** — fifteen `register` calls.
6. **Customize group + README** — `M-x customize-group key-hints`
   surfaces everything.

## 7. Risks / open questions

- **Mode-line clutter.**  Some users already pack a lot into the
  mode-line (`battery`, `mu4e-modeline`, etc.).  The strip should
  truncate gracefully (right-most items drop first) and the
  `+N` indicator stays visible so users know there's more.
- **Curated drift.**  Each registered list of keys risks
  diverging from what's actually bound.  Mitigation: when
  `key-hints-mode` is enabled, the auto-extractor runs at
  registration time and warns when a curated key isn't actually
  bound in that mode.
- **Sectionless modes.**  `prog-mode` derivatives have no
  section-at-point, so the auto-extracted set is the same
  buffer-wide.  Fine for v1.
- **Frame-local vs window-local.**  Mode-line is window-local —
  each window in a split shows hints for its own buffer.  That's
  the right behaviour.
- **Performance on giant keymaps.**  Magit's keymap has 200+
  entries.  Walk-once, cache forever per (mode, registry
  generation).

## 8. Out of scope

- **Modal hints (hercules / hydra-style)** — those are different
  affordances (a sequence of strokes).  This is just a passive
  cheat strip.
- **Mouse-clickable hints** — could come later as v2; mouse
  affordances on the mode-line work but add complexity.
- **i18n / hint translation** — defer until anyone needs it.
