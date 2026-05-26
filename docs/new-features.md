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

## Filter / narrow views by label  *(status: shipped — see [docs/label-filter-plan.md](label-filter-plan.md))*

`F` is the filter prefix in every k8s view and the docker
containers view.  `F l` / `F n` set the label selector / name
regex; `F c` clears; `F F` echoes the current state.  Labels go
server-side (`?labelSelector=` on k8s, `?filters=` JSON on docker —
docker is equality-only); name-regex is client-side.

Mode-line shows `[label:KEY=VAL name:REGEX]` in the warning face
when a filter is active.

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
