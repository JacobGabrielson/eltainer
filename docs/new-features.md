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

## Cross-resource jumps — extending `k8s-jump-target`  *(status: shipped Ingress -> Service; more to come)*

The `k8s-jump-target` text property is the mechanism for every
cross-resource RET.  `k8s-dwim-ret` reads the property under point
and dispatches via `k8s--jump-to-target`'s `pcase` arms.

Today: `(service NS NAME)` works (Ingress backend rows → Services
view, scrolls to that row).

Future arms to add when needed:
- `(pod NS NAME)` from places that mention a pod (Job → its pod;
  Endpoint → backing pod).
- `(node NAME)` from a pod's `Node:` field (already on the inspect
  buffer; add a property there).
- `(deployment NS NAME)` from a Service's owner annotation (when we
  add owner-reference rendering).
- `(endpoints NS NAME)` from a Service row.

Each new arm is ~5 lines plus the property at the render site.

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
