# Plan: performance improvements

Status: **proposal** — review before coding.  Findings from a
codebase-wide audit (every `.el` file in `docker/`, `k8s/`, and the
top-level shared modules) of CPU, memory, and caching opportunities.

The recurring themes are four:

1. **Synchronous serial HTTP** — the biggest visible-stall culprit.
2. **Stream-filter byte accumulation** — quietly O(n²) on long streams.
3. **Missed caches** — kubeconfig re-parse, no TLS / keep-alive reuse.
4. **Hot-path micro-fixes** — alist scans in inserters, full-buffer
   walks in point-context save, vector↔list coercion.

Findings are tiered by impact.  Each item is independent; PRs of 1–3
items at a time.  No architectural rewrite required.

---

## Tier 1 — Visible UI stalls (big wins)

### 1. Parallelize per-node kubelet Summary calls

**Files:** `k8s/k8s-metrics.el` (`k8s-metrics-collect-nodes`,
`k8s-metrics-collect-summary`).

Today both helpers loop nodes with `seq-doseq` and call
`k8s-stats-summary conn nname` synchronously.  Each is one HTTPS
round-trip through the API-server node-proxy; on a 10-node cluster
the refresh blocks Emacs for 1–3 s, on 100 nodes it's unusable.

**Fix shape:** fire all N stats requests in parallel via
`docker-http-stream` (async, on-close callback), collect into a hash,
re-render when the last one lands.  The pods-view metrics path
already uses this pattern for `/stats`; lift it to the multi-node
case.

### 2. Parallelize the Nodes view's API chain

**File:** `k8s/k8s.el` (`k8s--nodes-refresh`).

Today the refresh is `list-nodes` → `collect-nodes` (which serially
calls Summary per node) → `list-pods` → 5 Prometheus queries — all
sequential on the 30 s timer.

**Fix shape:** nodes, pods, and Prometheus queries have no data
dependency on each other; fire them concurrently and render when the
last completes.  Sequence only the dependent steps (per-node summary,
which is fixed by Tier-1 #1 above).

### 3. Parallelize `docker-inspect-networks`

**File:** `docker/docker-networks.el` (called from `docker.el`
networks refresh).

The networks view does one synchronous `/networks/{id}` per network
to fold in connected-containers detail.  50 networks ⇒ 50-call serial
chain that blocks the UI on every refresh.

**Fix shape:** concurrent async inspects.  Pair with a per-network
detail cache invalidated by `network` events on the daemon's
`/events` stream — the inspect output rarely changes.

### 4. Stream-filter buffering — kill the O(n²)

**Files:** `docker/docker-http.el` (chunked decoder),
`docker/docker-stream.el` (multiplex demux + NDJSON splitter).

Both modules do `(setq buf (concat buf chunk))` inside the process
filter on every chunk.  For a multi-MB log tail or a busy `/events`
stream that's quadratic in the accumulated size.

**Fix shape:** two viable patterns —
- **Chunks-list:** keep a list of chunk strings; `concat` only when a
  complete frame/line is found, then drop consumed prefix.
- **Scratch buffer:** per-process hidden buffer, `insert` chunks,
  slice with `buffer-substring`.

`docker-http--stream-pump-body` already uses pattern (b); carry the
same approach through the demux + NDJSON layers.

---

## Tier 2 — Cache and reuse

### 5. Memoize kubeconfig parsing

**Files:** `eltainer.el` (`eltainer--discover-kubeconfig*`),
`k8s/k8s-config.el` (`k8s-config-load`).

Dashboard `g` re-globs `~/.kube` and re-parses every YAML file from
scratch.  `k8s-connection-open` also re-parses on every open.

**Fix shape:** module-level cache keyed by `(path . mtime)`.
Invalidate on mtime change.  Saves ~50–200 ms per dashboard refresh
when several kubeconfigs are discovered.

### 6. HTTP connection pool / keep-alive

**File:** `docker/docker-http.el`.

Every sync request opens a fresh socket and tears it down on
completion.  TLS handshake ~100 ms; bursts (list → describe →
events) compound.  The K8s API server happily speaks HTTP/1.1
keep-alive.

**Fix shape:** small per-config pool (2–4 idle keep-alive sockets),
checked out by `docker-http-request`, returned on completion, evicted
after an idle timeout.  Side benefit: a single long-lived socket for
the `/events` stream + view refreshes against the same daemon.

### 7. Audit the Prometheus discovery cache

**File:** `k8s/k8s-prom.el`.

Already memoizes discovery per cluster including a `:none` sentinel,
so absent-Prometheus clusters don't rescan.  Two follow-ups:

- Document `M-x k8s-prom-reset` next to the `eltainer-prometheus-service`
  defcustom so users find it when they install Prom mid-session.
- Surface the cache hit/miss in the Nodes-view header ("Prometheus:
  …") line — already in place, just verify it survives a context
  switch.

---

## Tier 3 — Hot-path micro-fixes

### 8. Pre-hash nodes for Prometheus matching

**File:** `k8s/k8s-prom.el` (`k8s-prom--match-node`).

Per series, dolist over nodes × dolist over labels — O(n × m) per
sample × 5 queries.  Cheap fix.

**Fix shape:** build `name→node` and `ip→node` hashes once per
`k8s-prom-node-metrics` call; lookup in O(1).

### 9. Incremental expanded-section tracking

**File:** `k8s/k8s.el` (`k8s--collect-expanded-section-ids`).

The recent cursor-preservation fix walks the whole buffer on every
save-context call.  Fine for the Nodes view (few sections); on a
large pods buffer with the watch-driven refresh it's measurable.

**Fix shape:** maintain a buffer-local hash of expanded section
stable-IDs.  Update via advice on `magit-section-toggle`.  Fall back
to the full walk if the cache is empty (first save after open).

### 10. Reap the dead-container metrics hash

**File:** `docker/docker.el` (`docker--metrics`).

Per-container metrics history is never pruned.  Long-running Emacs +
container churn slowly leaks (~1 KB per dead container).

**Fix shape:** in each refresh, drop hash keys not present in the
live container list.  One-liner inside the existing tick.

### 11. Index the K8s path alists

**File:** `k8s/k8s-api.el` (`k8s--list-api-paths`,
`k8s--resource-api-paths`).

Linear `assq` over ~12 entries per render — small constant but
called per resource per row.

**Fix shape:** convert both alists to hash tables at module load.
Same surface, faster lookups.

### 12. Pre-index pod-render metrics by container name

**File:** `k8s/k8s-pods.el:142` (in `k8s--insert-pod-details`).

`(cdr (assoc cname usage))` per container per render is O(n).

**Fix shape:** build `cname → usage` hash once in the refresh; index
into it per container.

---

## Tier 4 — Worth it later

- Reduce `propertize` calls in tight inserters (style + small win for
  very large lists).
- Drop `(append vec nil)` coercions where `seq-doseq` would work
  directly on the vector.
- Pre-compile the per-layer-progress regex in `docker-pull.el`.
- `k8s-fs.el`: incremental line-by-line directory parsing instead of
  full-payload decode (only matters for >500-entry directories).
- `k8s-exec.el`: `seq-find` instead of manual `dolist` for ExitCode
  hunt in the error JSON — cosmetic.

---

## Rollout strategy

1. Land **Tier 1** first — biggest UX win, all I/O-bound, no
   data-structure changes.  Each item is one PR.
2. Land **Tier 2** next — foundational; #5 + #6 unlock simpler code
   in several places.
3. Sprinkle **Tier 3** opportunistically.
4. **Tier 4** lives in cleanup PRs.

Each item ships independently behind no flags — they are bug-fixes
or pure optimizations.  Existing tests (see
`docs/test-fixtures-plan.md`) cover render-shape regressions.
