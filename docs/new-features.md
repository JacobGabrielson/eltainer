# Backlog: unimplemented features + small bugs

This file is the lightweight queue for not-yet-shipped work.  Big
features that deserve their own design doc live in
`docs/<feature>-plan.md` — this index links to those.  Small items
keep their plan inline.

Convention:
- **Status**: `idea`, `proposal`, `drafted`, `in-progress`, `shipped`
- Move shipped items out (link from the relevant PR / commit
  message instead).
- When an item grows past ~30 lines of plan, lift it into its own
  `docs/<slug>-plan.md` and replace the body here with a one-line
  pointer.

---

## Age column color tiers  *(status: drafted)*

`eltainer-ui-age-string` returns `"5d"` / `"2h"` / `"30m"` / `"15s"`
but every caller propertises the result with `eltainer-dim`
unconditionally — old and young pods look identical.

Plan:
- Add five faces in `eltainer-ui.el`: `eltainer-age-very-new` (< 1h),
  `eltainer-age-new` (< 1d), `eltainer-age-medium` (< 1w),
  `eltainer-age-old` (< 1mo), `eltainer-age-ancient` (≥ 1mo).
  Defaults: blue / green / default / yellow / shadow (or similar —
  one of each in the standard term palette so it works on dark and
  light themes).
- Add `eltainer-ui-age-face TIMESTAMP` companion that returns the
  right face for the same timestamp.  Tier boundaries: 3600 / 86400
  / 604800 / 2592000 seconds (1h / 1d / 1w / 30d).
- Sweep every age-render site (`grep '-age-string'` lists them) to
  propertise with the face the helper returns instead of
  `eltainer-dim`.  ~15 call sites; one-line change each.
- Test: faces returned for synthetic ISO-8601 timestamps at each
  tier boundary.

---

## Ingress: `RET` on a backend line jumps to the Service / Pods  *(status: drafted)*

Under each Ingress (k8s.el §Ingresses, `k8s--insert-ingress-line`)
we render lines like `bookstore.local/api → bookstore-api:80`.  `RET`
there does nothing today; it should jump to the Service (or, if no
Services view is open, the Pods filtered to that Service's
selector).

Plan:
- In `k8s--insert-ingress-line` (`k8s/k8s.el:1339`), put a
  `(k8s-jump-target (service NAMESPACE NAME))` text property on
  each backend line.  Use the ingress's own namespace (rules don't
  carry one).
- Add `k8s-dwim-ret` that reads the property and dispatches: open
  the services view, search for `NAME` in `NAMESPACE`, position
  point there.  Fall back: if Services view's macro doesn't make
  jumping easy, open a pods-view filtered by the Service's
  `selector` (which means another API call to `GET /services/NAME`
  first).
- Bind in `k8s-ingresses-mode-map` (and any other view that grows
  jump-targets) — keep `RET` as DWIM via the existing
  `k8s--define-view` macro.
- Tests: fixture-based once test-fixtures-plan lands; for now a
  smoke test with `(k8s-ingresses)` against a live cluster.

Generalisation note: the same `k8s-jump-target` property is the
mechanism for **all** future cross-resource jumps (Deployment →
Pods, Pod → Node, Service → Endpoints, etc.).  Designing the
property now pays off later.

---

## DNS-lookup view from a container's perspective  *(status: drafted)*

When debugging Service / Ingress / NetworkPolicy issues you often
want to resolve a hostname *from inside a specific pod*
(`nslookup bookstore-api.bookstore.svc.cluster.local`).  Today the
only way is `e` → shell → type the command — too many steps.

Plan:
- New command `k8s-pod-dns-lookup-at-point` (bound to `D` in pods,
  or `?` dispatch entry "DNS lookup").  Prompts for a hostname (or
  picks one from a recent-Services history).
- Implementation tries, in order:
  1. `getent hosts <host>` — works on glibc/musl images.
  2. `nslookup <host>` — works on busybox / alpine.
  3. `cat /etc/resolv.conf; cat /etc/hosts` — fallback "tell me what
     the pod thinks DNS even *is*".
  Picks the first one with `exit=0` and shows the output in a small
  popup buffer.
- Distroless: friendly error pointing the user to the
  ephemeral-debug-container path (`docs/container-dired-plan.md`
  §10) once that lands.  For now: "this image has no DNS tools".
- Same plumbing as `k8s-exec` (already sync, captures stdout/stderr).
  ~50 lines plus the buffer.
- Docker analogue: `docker-container-dns-lookup-at-point` bound to
  `D` in `docker-containers-mode-map`.  Same shape, different
  backend.
- Tests: unit-test the response parser; integration test against a
  live pod with `getent`.

---

## Filter / narrow views by label  *(status: proposal — see [docs/label-filter-plan.md](label-filter-plan.md))*

User wants a magit-style way to narrow a view to resources matching
a label selector.  Open questions: keystroke (`/` is the ibuffer
convention but conflicts with isearch in some setups; `f` is taken
by filesystem-browse; `L` is a possibility), composition with
existing namespace filter, server-side vs client-side filtering.

See the linked plan for the design.

---

## Helm chart support  *(status: proposal — see [docs/helm-plan.md](helm-plan.md))*

Read-only listing of Helm 3 releases, decoded straight from the
release secrets the API server already exposes (`type=helm.sh/release.v1`,
`owner=helm`).  No `helm` CLI shelled out — keeps the "no CLI"
invariant.  v1 is list + describe + view values; v2 might add
upgrade once we figure out how to do that without a CLI (probably
shipping the rendered manifests to `kubectl apply`-equivalent via
the API).

See the linked plan for the design.

---

## Out-of-scope / open

- **Most popular ingress controllers** — ingressClass discovery is
  not bad today.  The interesting follow-up is per-controller-class
  jump-to-pods (a Traefik IngressRoute resource isn't a stock
  Ingress).  Defer until someone asks.
