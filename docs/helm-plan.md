# Plan: Helm chart support (read-only first)

Status: **proposal** — review before coding.

## Goal

A view of Helm 3 releases installed in the cluster, with describe
+ view-values affordances.  Read-only in v1; writable (`upgrade`,
`rollback`, `uninstall`) is a separate v2 once we figure out how
to do it without shelling to the `helm` CLI.

This stays inside the project's no-CLI invariant: Helm 3 stores
release state as Secrets on the API server, so we can do everything
read-side with the existing `k8s-api.el` machinery.

## 1. How Helm stores releases (relevant background)

Helm 3 (the only version in scope; v2 with Tiller is dead) writes
each release **revision** as a Kubernetes Secret in the namespace
the release is installed into:

```
apiVersion: v1
kind: Secret
metadata:
  name: sh.helm.release.v1.<release-name>.v<revision-number>
  namespace: <ns>
  labels:
    owner: helm
    name:  <release-name>
    status: <deployed|superseded|failed|...>
    version: <revision-number>
type: helm.sh/release.v1
data:
  release: <base64 of gzipped JSON>
```

Decoded `data.release` is gzipped JSON shaped like:

```json
{
  "name": "...",
  "info": { "status": "deployed", "first_deployed": "...", "notes": "..." },
  "chart": { "metadata": { "name": "...", "version": "...", "appVersion": "..." } },
  "config": { ... user-supplied values.yaml content ... },
  "manifest": "...rendered manifests yaml..."
}
```

Everything we need is in there.  No `helm` binary required.

## 2. v1 scope (read-only)

A new view `k8s-helm` (top-level binding alongside pods / nodes /
ingresses), showing one row per release with:

| Column | Source |
|--------|--------|
| `NAME` | `metadata.labels.name` |
| `REV`  | `metadata.labels.version` (highest only — the active revision) |
| `STATUS` | `metadata.labels.status` |
| `CHART` | `info.chart.metadata.name`-`info.chart.metadata.version` |
| `APP`   | `info.chart.metadata.appVersion` |
| `NAMESPACE` | release ns (= secret ns) |
| `AGE` | `metadata.creationTimestamp` of the active-revision secret |

Per-row affordances:

- `RET` / `TAB` — expand the row, show:
  - The full `info.notes` (NOTES.txt rendered at install time).
  - A summary line per resource in the rendered manifest (parsed
    yaml header `kind: Name`).
- `v` — pop a read-only buffer with `config` (current values) as
  yaml.
- `m` — pop a read-only buffer with the full rendered manifest.
- `h` — revision history: list every secret for this release name,
  newest first, with `STATUS` + `AGE` per revision.
- `i` — describe (uses the standard `k8s-describe` flow on the
  selected secret).
- `d` — *not bound* in v1 (deleting a release is a v2 op).

## 3. Module layout

```
k8s/
  k8s-helm.el         the view + commands + the secret-decoder
```

Just one new file.  Helpers it uses:

- `k8s-list-secrets` (already exists in `k8s-api.el`) with the
  label selector `owner=helm,status!=superseded` to get only the
  active revision of each release (one per release).
- A new private decoder:
  - `k8s-helm--decode-secret SECRET` — base64-decode `data.release`,
    gunzip via `zlib-decompress-region` (built into Emacs 28+), then
    `json-parse-string`.  Returns the release alist.
- `k8s-helm--list-releases CONN [NS]` — list secrets, decode each,
  return list of release alists.  Errors decoding one entry: skip
  it (log a warning), don't fail the whole view.

## 4. Cross-cutting integration

- **Dashboard** — add a `("h" "Helm releases" k8s-helm)` entry under
  the Kubernetes group in `eltainer-views`.
- **`?` dispatch** — add a Helm entry; on a release row, the
  context-aware first group is "Release at point".
- **Watch** — Helm-release secrets don't change often, so initial
  v1 doesn't need a watch stream.  Manual `g` is enough.
- **Filter** — once `label-filter-plan.md` lands, `F` works the same
  way: server-side label selector composed on top of our
  `owner=helm` baseline.

## 5. v2 sketch (writable, deferred)

The interesting question: can we do `helm upgrade` without the CLI?

Helm 3's algorithm, distilled:

1. Render the chart's templates against the new `values.yaml` — that
   needs Go's text/template engine + sprig functions.  We can't
   easily reproduce this in Elisp.
2. Diff against the current `manifest`.
3. `kubectl apply` the diff.
4. Write a new revision Secret.

Step 1 is the blocker.  Realistic options:

- **Ship pre-rendered manifests** — user runs `helm template` once
  externally, we apply the result.  Not really "upgrade".
- **`helm` CLI as an explicit exception** — would need user
  approval per the no-CLI rule.  Maintains the full UX but breaks
  the invariant.
- **Defer indefinitely**.

For now: v2 is out of scope.  Document the option in the README
("read-only").

## 6. Order of work

1. **Secret decoder** — `k8s-helm--decode-secret` against
   hand-recorded test fixtures (helm install on a kind cluster,
   `kubectl get secret -o yaml`, redact, check in).
2. **List view** — `k8s-helm` major mode, `k8s-helm--insert-line`,
   row-per-release rendering.
3. **Expand + commands** — `v`, `m`, `h`, `i` on release rows.
4. **Dashboard wiring** — `eltainer-views` entry, `?`-dispatch.
5. **Tests** — secret-decoder round-trip on fixtures; integration
   test if a helm install can be scripted in CI.
6. **README** — Helm section in the K8s key table.

## 7. Risks / open questions

- **Old releases that used ConfigMaps not Secrets** — Helm 3 still
  supports `--driver=configmap`.  Rare; defer.  If asked, the same
  decoder works on the `release` configmap data.
- **Releases with very long manifests** — `info.manifest` can be
  100K+ for big charts.  Lazy-load (parse only on expand) to keep
  the list-render fast.
- **Multi-tenant clusters** — listing secrets cluster-wide needs
  permissions we may not have.  Fall back to current-namespace
  listing if `forbidden` comes back.
- **Watch on secrets is noisy** — secrets churn for credentials,
  TLS, etc.; not all are Helm.  When we wire watch later, filter
  server-side via the label selector.
