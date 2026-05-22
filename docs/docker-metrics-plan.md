# Plan: docker container metrics

Status: **proposal** — review before coding.  Sibling of
`docs/metrics-plan.md` (the k8s metrics feature, now shipped).

## Goal

Show live resource usage for running Docker containers in the
containers view — CPU, memory, block-I/O, network, PIDs — as the same
text gauges and sparklines the k8s side already uses.  No new package
dependencies.  Where it can, the Docker side goes *beyond* the k8s
gauges, because the daemon reports things metrics-server doesn't:
CPU throttling, block-I/O throughput, per-interface net errors/drops,
process counts.

## 1. Data source — `/containers/{id}/stats`

`GET /containers/{id}/stats?stream=false` returns one JSON stats
object for a container.  Unlike k8s (one `metrics.k8s.io` call covers
every pod) this is **one call per container** — see §6.

`?stream=false` returns a single sample; the daemon populates
`precpu_stats` so CPU% is computable from that one call.  Block-I/O
and network are cumulative counters with no "pre" — their *rates*
need two consecutive polls, exactly like the k8s network sparkline.

## 2. What the daemon reports

| Field | Meaning | UI |
|-------|---------|-----|
| `cpu_stats` + `precpu_stats` | CPU-ns used, host total, online CPUs | CPU % gauge |
| `cpu_stats.throttling_data` | `throttled_periods` / `periods`, `throttled_time` | **throttle note** — flags a too-low CPU limit |
| `memory_stats.usage` / `.limit` | memory; `stats.cache`/`inactive_file` for the real working set | memory gauge |
| `blkio_stats.io_service_bytes_recursive` | bytes read/written to block devices | disk-I/O rate sparkline |
| `networks.{iface}.{rx,tx}_bytes` | per-interface network counters | net rx/tx sparkline |
| `networks.{iface}.{rx,tx}_{errors,dropped}` | packet errors / drops | health note when non-zero |
| `pids_stats.current` / `.limit` | process/thread count vs the pids cgroup cap | PIDs gauge |

The "whizzy" extras over the k8s gauges: **CPU throttling**,
**block-I/O throughput** (k8s only gave us rootfs *size*), **PID
count**, and **net drops**.

## 3. Computing the numbers

- **CPU %** — the `docker stats` formula:
  `cpu_delta = cpu_usage.total_usage - precpu.cpu_usage.total_usage`,
  `sys_delta = system_cpu_usage - precpu.system_cpu_usage`,
  `pct = cpu_delta / sys_delta * online_cpus * 100`.
  100% = one full core; can exceed 100 on multi-core.  Gauge
  denominator: `online_cpus * 100` (so the bar is "% of all cores"),
  with the raw per-core % in the label.
- **Memory** — working set = `usage - (stats.cache or
  stats.inactive_file)`; denominator = `limit` (often the host total
  when the container is unlimited — note that in the label).
- **Block-I/O / network** — cumulative; rate = delta / delta-t
  between polls.  Reuse the k8s `*-net-sample` ring-buffer pattern.
- **PIDs** — `current` / `limit` (no limit ⇒ raw count, no gauge —
  same fallback as cpu/mem without a limit).
- **Throttling** — `throttled_periods / periods` as a %; shown as a
  trailing note on the CPU line only when non-zero.

## 4. Sharing the gauge code — extraction

The gauge/sparkline rendering in `k8s/k8s-metrics.el` is entirely
generic — it must not be duplicated, and `docker-metrics.el` must not
`require` a k8s module.  Extract the generic primitives into a new
top-level **`eltainer-gauge.el`**:

| Moved out of `k8s-metrics.el` → `eltainer-gauge.el` | Renamed |
|---|---|
| faces `k8s-gauge-{low,mid,high,empty}` | `eltainer-gauge-{low,…}` |
| `k8s-metrics-gauge-width` / `-gauge-style` | `eltainer-gauge-width` / `-style` |
| `k8s-metrics-history-length` | `eltainer-gauge-history-length` |
| `--gauge-face`, `--bar`, `k8s-metrics-gauge` | `eltainer-gauge` |
| `k8s-metrics--sparkline` | `eltainer-sparkline` |
| `k8s-metrics--line` | `eltainer-gauge-line` |
| `k8s-metrics--human-bytes` | `eltainer-human-bytes` |
| ring-append helper (from `*-sample`) | `eltainer-ring-add` |

`k8s-metrics.el` keeps the k8s-specific bits (quantity parsers,
`--human-cpu` in millicores, the `collect*` API calls, container/pod
renderers, the buffers/views) and `(require 'eltainer-gauge)`.
This is a mechanical refactor of a tested file — re-verify the k8s
views render unchanged afterward, then build on top.

## 5. Where it surfaces

Mirror the k8s side:

- **Inline** — the containers view already renders each container as
  a magit section (`docker--container-insert-line`, `magit-insert-
  section (container …)`).  Expanded, a container gains gauge lines:
  ```
  sandboxes-cloud-db-1     running  postgres:17-alpine  …
      cpu  ▏███▍░░░░░░░░░░░░▕  38%  / 800%   throttled 4%   ▁▂▅█▆▃
      mem  ▏██████▏░░░░░░░░░▕  214Mi / 512Mi  42%           ▁▂▃▄▅
      io   rd ▁▂▁▁▅█▃▁  1.2 MiB/s   wr ▁▁▂▁▁▁▁  64 KiB/s
      net  rx ▁▂▅█▆▃▂▁  0.4 MiB/s   tx ▁▁▂▃▂▁▁  88 KiB/s
      pids ▏██░░░░░░░░░░░░░░▕  37 / 4096
  ```
- **`M`** in the containers view → `*docker:metrics:NAME*`, a
  focused self-refreshing buffer (mirrors `k8s-pod-metrics-at-point`
  / the `*k8s:metrics:…*` buffer).
- The container's transient menu (`docker-dispatch`) gains a Metrics
  entry.

## 6. Polling strategy — the one-call-per-container problem

k8s gets every pod's metrics in a single call; Docker needs one
`/stats` call per container.  Approach:

- Poll one-shot (`?stream=false`) for **running** containers only, on
  a timer (`docker-metrics-refresh-interval`, default 15s) — off the
  `/events` hot path, exactly like the k8s metrics timer.
- The `docker-http` transport is synchronous, so the calls are
  sequential.  On a local socket each is a few ms; ~tens of
  containers ⇒ well under a second per poll.  Acceptable.
- Guard huge hosts with `docker-metrics-max-containers` (default 40):
  beyond that, skip the poll and show a note rather than hammering
  the daemon.
- Cache results buffer-locally keyed by container id; the view
  render reads the cache, the timer refills it — same shape as
  `k8s--metrics-cache` + `k8s--net-history`.
- Streaming a persistent `/stats` per container was considered and
  rejected for phase 1: N long-lived connections, more moving parts,
  no real benefit at a 15s cadence.

## 7. New / changed files

| File | Change |
|------|--------|
| `eltainer-gauge.el` | **new** — extracted shared gauge / sparkline / humanizer / ring primitives |
| `k8s/k8s-metrics.el` | drop the extracted bits; `(require 'eltainer-gauge)`; rename to the `eltainer-*` helpers |
| `docker/docker-metrics.el` | **new** — `/stats` fetch, CPU%/mem/io/net/pids compute, per-container render, metrics buffer |
| `docker/docker-api.el` | add `docker-container-stats' request helper |
| `docker/docker.el` | inline gauge lines in the expanded container section; metrics poll timer; `M` + dispatch entry |
| `reload.el` | add `eltainer-gauge`, `docker-metrics` to the module lists |
| `README.md` | document container metrics |

## 8. Phasing

1. **Phase A** ✅ *(shipped)* — extracted `eltainer-gauge.el`, rewired
   `k8s-metrics.el`; k8s views unchanged.
2. **Phase B** ✅ *(shipped)* — `docker-metrics.el`: `/stats` fetch,
   CPU/memory compute, inline gauges in the container section, poll
   timer.
3. **Phase C** ✅ *(shipped)* — block-I/O + network rate sparklines;
   PID count; CPU-throttling and net-drop notes.  (Block-I/O is
   absent on rootless cgroup-v2 daemons — degrades gracefully.)
4. **Phase D** ✅ *(shipped)* — `M` per-container metrics buffer;
   `docker-dispatch` entry.

Open question §9 resolved during Phase B: `?stream=false` does
*not* give a usable `precpu_stats` (its window is ~milliseconds), so
CPU% is computed across consecutive eltainer polls — first rate
appears on the 2nd poll, like the network sparkline.

## 9. Open questions

- Does `?stream=false` reliably populate `precpu_stats`?  If not,
  phase B computes CPU% only from the 2nd poll onward (same warm-up
  as the network sparkline — fine).
- Memory denominator when the container is unlimited: **resolved** —
  gauge against host RAM (basis `host'), since an unlimited container
  genuinely could use the whole box.  Only when host RAM is also
  unknown does it fall back to the raw number.
- One `*docker:metrics:NAME*` buffer keyed by container name — names
  are unique per host, so that's safe (unlike image tags).
