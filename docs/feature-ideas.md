# Feature ideas: derived from the broader Kubernetes-UI landscape

A scan of mainstream Kubernetes UIs (GUI + TUI) surfaces a long
list of things eltainer could plausibly grow.  This doc is the
filtered candidate pool — features that survive the filter "fits
eltainer's design (magit-section, no-CLI, dired-style, pure
Elisp)" — grouped by area, with a rough effort tag and a note on
whether it pulls its weight.

Already shipped, for the avoidance of doubt: Pods / Deployments /
StatefulSets / DaemonSets / Jobs / CronJobs / Services / Ingresses
/ ConfigMaps / Secrets / Nodes / Sandboxes views; namespace +
label + name-regex filtering; multi-cluster kubeconfig switch;
log streaming (single + multi-pod, ANSI colour); TTY exec;
container-dired filesystem browser (read+write); per-pod /
per-container / per-Service metrics with sparklines; Helm 3
read-only releases view; watch streams; cross-resource jumps;
dired-style marks; describe; delete with confirm; DNS lookup
from inside a container; the `F`-prefix filter UX.

Status of each below: **idea** = not planned yet; **proposal** =
has a `docs/<feature>-plan.md`.  Move items into
`docs/new-features.md` (with the plan-doc convention) when they
graduate from idea to drafted.

---

## Resource coverage (mechanical, mostly cheap)

These extend `k8s--define-view` with one more line per resource —
the macro already handles refresh, watch, mode-line, the `?`
dispatch transient, and the column header.  Each is roughly an
afternoon.

- **HPA view** (`HorizontalPodAutoscaler`) — current / target /
  min / max replicas; very useful when debugging "why isn't this
  pod scaling".  *(idea)*
- **PDB view** (`PodDisruptionBudget`) — allowed disruptions vs
  desired.  *(idea)*
- **PV / PVC / StorageClass views** — storage objects.  PVC's
  row should jump (via the existing `k8s-jump-target` mechanism)
  to its bound PV.  *(idea)*
- **NetworkPolicy view** — read-only render of the selector +
  ingress/egress rules.  Visualising flows is out of scope; a
  textual table is enough.  *(idea)*
- **ResourceQuota / LimitRange views** — easy to render, often
  needed when a cluster "mysteriously" rejects creates.  *(idea)*
- **RBAC views** — Roles, RoleBindings, ClusterRoles,
  ClusterRoleBindings, ServiceAccounts.  Five views; share a
  rule-rendering helper.  *(idea)*
- **Endpoints view** — what backs each Service.  RET on a row
  should jump to the pod for ip-by-pod resolution.  *(idea)*
- **Events view** — the live `/api/v1/events?watch=true` stream
  sorted by `lastTimestamp` descending; Warning rows in
  `eltainer-status-error` face.  Watch handling is already in
  the toolbox.  *(idea)*

## Generic CRD support (medium)

Today every CRD that's interesting needs hand-written rendering
(see the Sandboxes view).  A generic auto-discovery path is the
single biggest leverage:

- **CRD discovery + table view** — list
  `/apis/apiextensions.k8s.io/v1/customresourcedefinitions`, build
  a per-CRD view that renders `additionalPrinterColumns` from the
  CRD spec into a magit-section table.  *(shipped 2026-05-27)*

## Actions on existing views (small to medium)

Today eltainer is mostly read-only modulo `D` delete and the
container-dired write ops.  The mainstream UIs offer:

- **Scale workload** — `S` on a Deployment / STS / RS prompts for
  a new replica count, PATCHes `.spec.replicas`.  Trivial.  *(idea)*
- **Rollout restart** — `R` patches the `spec.template.metadata.
  annotations` with `kubectl.kubernetes.io/restartedAt=<now>`,
  which is exactly what `kubectl rollout restart` does.  Trivial.
  *(idea)*
- **Cordon / uncordon / drain nodes** — `C` cordons, `U` uncordons
  (PATCH the Node's `.spec.unschedulable`), `D` drains (cordon
  + iterate evictions via the eviction subresource).  Already
  have the Nodes view.  *(idea)*
- **Force-restart pod** — `K` (kill) — delete the pod (the
  controller recreates it).  Distinct from `d` which is the
  "remove this resource" semantic.  *(idea)*
- **Edit YAML inline** — `Y` fetches the resource, drops it into
  a yaml-mode buffer with a header, `C-c C-c' PUTs it back.
  Server does the YAML round-trip via content-type negotiation;
  `resourceVersion' provides optimistic concurrency.
  *(shipped 2026-05-27)*
- **Previous container logs** — `L` while on a CrashLoopBackOff
  pod fetches with `?previous=true` so you see the LAST run, not
  the current empty one.  One-line change to `k8s--log-start`.
  *(idea)*

## Navigation + workflow (medium, high impact)

- **Cluster pulse dashboard** — `*k8s:pulse*` showing aggregate
  health: total Pods by phase, Nodes Ready/NotReady, recent
  Warning events count, top CPU/mem pods.  *(shipped 2026-05-27)*
- **xray / resource tree** — `T` on a workload row recursively
  expands: Deployment → ReplicaSets → Pods → Containers → mounted
  Volumes → referenced ConfigMaps / Secrets / PVCs.
  *(shipped 2026-05-27)*
- **Quick-jump fuzzy switcher** — `M-x k8s-jump` opens a
  `completing-read` (vertico-friendly) listing every resource in
  the active namespace + the cluster-scoped ones.  Selecting one
  opens the right view scrolled to that row.  *(idea)*
- **Bookmarks** — wire each resource row's `section-value` into
  `bookmark-make-record-function` so `M-x bookmark-set` saves a
  cross-cluster pointer to "this pod" — `bookmark-jump` later
  reopens the buffer and scrolls there.  Standard Emacs UX, zero
  new vocabulary.  *(idea)*
- **Owner navigation** — on a Pod row, `O` (or RET on a synthetic
  "Owned by:" line) jumps to its owner (ReplicaSet → Deployment,
  Job → CronJob, etc.).  Extends `k8s-jump-target`.  *(idea)*
- **Pin namespaces** — `*` on a namespace mark in `N` (switcher)
  pins it; pinned namespaces appear above unpinned in the picker.
  Stored in `~/.emacs.d/eltainer-namespaces.el`.  *(idea, low
  priority)*
- **Aliases for resources** — `k8s-jump po` ≡ `k8s-pods`.  Tiny
  but matches a common muscle memory.  Just `defalias` entries.
  *(idea)*
- **Read-only safety mode** — `eltainer-read-only` defcustom (or
  toggled per-cluster context); when set, every mutating command
  shows a confirm-and-explain message before running.
  Particularly relevant when the active context is prod.  *(idea)*

## Observability (medium)

- **Port-forward manager** — `P` on a Pod / Service row opens a
  port-forward via the API server's `/pods/.../portforward`
  SPDY/WebSocket endpoint (no CLI shell-out).
  `*k8s:port-forwards*` lists actives; `k` kills.  Substantial:
  the SPDY framing isn't trivial but it's a standard protocol.
  *(idea — bigger ticket)*
- **Cluster sanity scan** — `*k8s:scan*` runs a battery of
  read-only checks: pods without `resources.limits`, pods without
  liveness/readiness probes, missing pdb on multi-replica
  deployments, unused Secrets / ConfigMaps, NetworkPolicies that
  select no pods, nodes near limits, etc.  Each finding has a
  short rationale + the offending resource (RET jumps to it).
  This earned its own ecosystem already (popeye, kube-score,
  kubeaudit) — even a small first pass is useful.  *(idea —
  pleasant scope, well-defined output)*
- **`can-i` / `who-can` reverse RBAC** — `?A` (auth) on a row
  POSTs to `/apis/authorization.k8s.io/v1/selfsubjectaccessreviews`
  for "can I do X on this".  `M-x k8s-who-can <verb> <kind>`
  iterates RoleBindings / ClusterRoleBindings to answer the
  inverse question.  *(idea)*
- **Save logs to disk** — `C-x C-w` already works in any log
  buffer (write-region).  Just document it in the key table.
  *(documentation, not code)*

## Editing + diffing (medium)

- **Diff two resources** — mark two resource rows (existing `m`),
  `=` invokes `ediff-buffers` between their describe outputs.
  Useful for "why is this pod different from its sibling".  *(idea)*
- **Diff with last-applied-configuration** — on a resource that
  was `kubectl apply`'d (annotation
  `kubectl.kubernetes.io/last-applied-configuration` present),
  show the diff between current state and last-applied.  Common
  "what drift do we have" question.  *(idea)*
- **Wdired-style bulk edit** — not for filenames but for
  scale-replica annotations.  Mark several Deployments, `C-x C-q`
  drops into an editable replicas column, `C-c C-c` PATCHes each.
  Cute, lower priority.  *(idea)*

## Customization

- **User-defined hotkeys per resource type** — `eltainer-hotkeys`
  defcustom: alist of `(VIEW-MODE KEY COMMAND)`.  Loaded at
  reload time.  Avoids monkey-patching keymaps.  *(idea)*
- **Per-view column visibility / order** — `eltainer-columns-*`
  defcustoms per view (e.g.
  `k8s-pods-columns '(name status ready restarts age ip)`).  The
  render macro picks columns from a registry.  Touches the macro,
  not trivial.  *(idea, lower priority)*
- **Themes** — Emacs already themes faces.  The existing palette
  (`eltainer-resource-name`, `eltainer-status-*`, `k8s-dim`,
  `eltainer-age-*`, etc.) is themable today.  Just document.
  *(documentation)*

## Definitely out of scope

- **HTTP / TCP benchmarking against a Service** — pure-Elisp `ab`
  is silly.  Recommend `hey`/`vegeta` to users; we're not a load
  generator.
- **kubectl-plugin invocation via shell** — against the no-CLI
  invariant.  If a plugin's job is "list X kind", do it via API.
- **Visual dependency graph** — Emacs lacks a good in-buffer
  vector renderer; SVG output via `dot` would mean either an
  external dep or a launch-graphviz hack.  The xray tree (above)
  gives the same insight in plain text.
- **Cloud-provider integrations** (CloudWatch, GCP Monitoring,
  Azure Insights) — out of scope unless someone shows up with a
  concrete need.

---

## Prioritisation (rough)

If we shipped these in order, the cluster-of-users value curve
looks roughly like:

1. **Generic CRD support** — unlocks every new resource type
   without code per CRD.
2. **Edit YAML + apply** — the single most-asked feature in
   k8s GUIs.
3. **Cluster pulse dashboard** — the "what's broken right now"
   landing page.
4. **xray resource tree** — best magit-section fit; useful daily.
5. **Events view** — high signal-to-noise for debugging.
6. **Resource-level actions: scale, rollout-restart, cordon,
   drain, force-restart, previous-logs** — small individually,
   adds up.
7. **RBAC + storage + HPA/PDB/NetworkPolicy/etc. views** — fill
   in the resource coverage matrix.
8. **Bookmarks** — small, leverages built-in Emacs.
9. **Cluster sanity scan** — coherent feature; pleasant to
   build incrementally.
10. **Port-forward manager** — SPDY/WebSocket is the gnarly bit;
    save for after the core is solid.
11. **Read-only safety mode**, **aliases**, **quick-jump**,
    **owner-jump** — polish.

This list is a menu, not a roadmap.  Pick what looks fun.
