# Keymap audit

Status: **survey + recommendations** (2026-05-29).

The audit tool is `test/keymap-audit.el`, runnable from the repl
(`M-x keymap-audit`) or batch (`make audit-keys`).  It walks every
`*-mode-map` / `*-map` symbol with our prefixes, resolves each
key's *effective* binding (local-overrides-parent), and produces
three sections:

1. **Construction-pattern survey** — per-file counts of which
   binding idioms are in use (`defvar-keymap`, defvar+let,
   `define-key`, `keymap-set`, `set-keymap-parent`).
2. **Mode-map listings** — every single-key binding visible on
   each map.
3. **Cross-mode inconsistencies** — every KEY bound to two or
   more *different* commands across the surveyed maps, with the
   per-map command listed.

The tool is a diagnostic, not a linter.  Most of what it flags
is intentional; the developer reads the report and decides.  This
document is the curated read from 2026-05-29.

## 1. Construction patterns

The codebase mixes **five idioms** for building a mode-map:

| Idiom                                                  | Where                                                                                                                              |
| ---                                                    | ---                                                                                                                                |
| `(defvar-keymap NAME :parent P "k" 'cmd ...)`          | `docker.el` (common, containers, images, networks), `docker-logs`, `docker-metrics`, `k8s.el`, `k8s-pods`, `k8s-metrics`, `k8s-multilog`, `k8s-traffic` |
| `(defvar NAME (let ((m (make-sparse-keymap))) ... m))` | `docker-create`, `docker-df`, `docker-volumes`, `eltainer-dired`                                                                   |
| `(defvar NAME (make-sparse-keymap))` + `set-keymap-parent` + `keymap-set` lines | `docker-pulse`, `docker-stacks`, `k8s-crds`, `k8s-helm`, `k8s-marks`, `k8s-pulse`, `k8s-scan`, every k8s resource view              |
| `(set-keymap-parent NAME ...)` alone (other defvars implicit) | `k8s-events`, `k8s-xray`                                                                                                           |
| `(define-key NAME ...)` calls without a `defvar-keymap` | `k8s-portforward`                                                                                                                  |

**Recommendation:** standardise on `defvar-keymap` with `:parent`
everywhere.  It is the modern Emacs idiom (29+), declarative,
inlines the parent relation, and removes the
"defvar-then-mutate-it-later" footgun that keeps biting us with
byte-compiler "reference to free variable" warnings (the reason
`docker-pulse.el` etc. have to add a `(defvar docker-common-map)`
forward-declaration).

The consolidation is mechanical but touches roughly a dozen
files, so it should be a single dedicated PR rather than smuggled
into a feature change.  Track it as `docs/keymap-consolidation-plan.md`
when promoted.

## 2. The common code is already there

The audit confirms that **shared bindings DO already live in one
place per platform**:

- `docker-common-map` (in `docker/docker.el`) holds the universal
  docker keys: `d` delete, `i` inspect, `l` logs, `g` revert, `q`
  quit, `RET` dwim, `?` dispatch, `F` filter.  Every docker view
  map (`-containers`, `-images`, `-networks`, `-pulse`, `-stacks`,
  `-volumes`, `-df`) inherits from it.
- `k8s-common-map` (in `k8s/k8s.el`) holds the universal k8s
  keys: `d/i/RET/?/D/K/M/N/P/R/S/T/U/Y/W/c/m/t/u/w` — see the
  audit report for the full list.  Every k8s resource view map
  inherits from it.

So the user-asked-for "common code" exists and is followed.  The
inconsistencies in section 3 are not for lack of a shared parent
— they are deliberate per-view specialisations of those parents.

## 3. Cross-mode "drift" — categorised

The audit flagged 60 keys with cross-mode drift.  Most fall into
known intentional patterns; a few are real and worth a follow-up.

### 3a. Dashboard letter = resource view, same letter elsewhere = verb
*(intentional, no action)*

`A B C D E H I J K M N O P R S T U V W X Y Z` are bound on
`eltainer-mode-map` to *launchers* (`A` → `k8s-sandboxes`, `D` →
`k8s-daemonsets`, `T` → `docker-stacks`, etc.) and bound on
resource maps to *verbs* (`K` → `k8s-force-kill-pod-at-point`,
`D` → `k8s-drain-at-point`, etc.).

This is forced: the dashboard is a launcher menu where each
resource gets a short letter, while the views need short letters
too.  The dashboard is its own mode, so the bindings never collide
at runtime.  Don't fix.

### 3b. Universal-verb consistency *across* k8s resource views
*(intentional and well-enforced)*

`d / i / D / K / M / N / P / R / S / T / U / Y / W / c / m / t / u / w`
all bind to the same `k8s-*` function in every single k8s-* view
that doesn't deliberately override them.  Audit's "inconsistency"
flag here is just the consequence of these keys being bound to
*different* functions on docker / dired / dashboard — all of which
are different modes from k8s.  The k8s side is internally
consistent.

### 3c. Universal-verb consistency across docker resource views
*(intentional and well-enforced)*

`d / i / l / g / q / ? / RET / F` are bound to the same function
in every docker view (because they come from `docker-common-map`).

### 3d. `eltainer-dired-mode-map` shows mixed `dired-*` and `eltainer-dired-*`
*(intentional override)*

`+` `<` `>` `?` `C` `D` `H` `M` `O` `R` `S` `T` `Z` etc. each show
both the parent `dired-*` command and a local `eltainer-dired-*`
override.  These are deliberate: the eltainer wrapper rebinds
operations that would touch the host filesystem so they go through
the docker archive API instead (or are explicitly not-implemented
with a friendly message).  The audit lists both because both ARE
bound in the visible map; effective binding is the local override.

Worth a small follow-up: add a comment in `eltainer-dired.el`
explaining the override pattern, so a future reader doesn't
think the parent bindings are reachable.

### 3e. `g` per-view-refresh override of parent `revert-buffer`
*(intentional but reducible)*

`g` in `docker-df`, `docker-metrics`, `docker-pulse`, `docker-stacks`,
`docker-volumes`, `k8s-log`, `k8s-metrics`, `k8s-multilog`,
`k8s-pulse`, `k8s-scan`, `k8s-traffic` is rebound from the parent's
`revert-buffer` to a mode-specific refresh function.

**Reducible to common code:** if each mode set a proper
`revert-buffer-function`, the parent's `g` → `revert-buffer` would
Just Work, and the per-view `g` rebindings could be deleted.  See
`docker-containers-mode-map` for the pattern done right (it relies
on the inherited `g`).

This is a small follow-up: ~10 files, each loses one line.

### 3f. Real drift — items to investigate
*(non-zero number, but the count is `0` after the categorisations
above)*

After applying the categorisation above, **no surprising drift
remains.**  Every key currently flagged is either:

- a dashboard launcher vs. a same-letter verb in a resource view
  (3a — by design),
- a verb inherited from `docker-common-map` / `k8s-common-map`
  (3b/3c — by design),
- a deliberate dired override (3d — by design),
- or a per-view refresh of `g` that could be tidied into a
  `revert-buffer-function` (3e — minor cleanup, behaviour
  unchanged).

The audit is now baseline-clean.  Future divergences will appear
in the report and can be triaged the same way.

## 4. Running the audit

From an Emacs session with eltainer loaded:

    M-x keymap-audit RET

From the shell:

    make audit-keys

CI-friendly: `make audit-keys` exits 0 unconditionally (the audit
is informational, not pass/fail).  A future enhancement could
make it fail on *new* drift versus a checked-in snapshot, but the
"every flag has a category" reality of section 3 means a snapshot
file would be ~3000 lines and noisy to review.  We can revisit if
the report grows organically beyond what a human reviewer can
parse.
