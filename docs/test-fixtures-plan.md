# Plan: fixture-capture and replay testing

Status: **proposal** — review before coding.

## Goal

Capture real Kubernetes (and Docker) API responses to disk and replay
them in ERT tests, so we can unit-test eltainer's parsing, rendering,
metrics math, and watch-event handling against *actual* data shapes —
not hand-written stubs that drift from reality.

Concretely: run eltainer interactively against a live cluster for a
minute, end up with a `test/fixtures/<scenario>/` directory, then write
tests like

```elisp
(ert-deftest k8s-pods-render-basic ()
  (with-eltainer-fixture "microk8s-pods-default-ns"
    (with-temp-buffer
      (k8s-pods-mode)
      (setq k8s--connection (eltainer-fixture-connection))
      (k8s--pods-refresh)
      (should (search-forward "kube-prom-stack" nil t))
      (should (search-forward "Running" nil t)))))
```

…that pass deterministically with no Docker daemon or cluster present.

## 1. Mock seam

Every K8s and Docker call funnels through two functions in
`docker/docker-http.el`:

- **`docker-http-request`** — synchronous request/response.
- **`docker-http-stream`** — async streaming process, with
  `:on-headers`, `:on-chunk`, `:on-close` callbacks.

These are the only seams the tests need to control.  No other layer
(kubeconfig, JSON parse, magit-section render) needs mocking — they
operate on the recorded payloads, which is exactly what we want to
exercise.

## 2. Fixture format

One JSON manifest per scenario, hand-curatable:

```json
{
  "name": "microk8s-pods-default-ns",
  "captured_at": "2026-05-23T20:30:00Z",
  "captured_against": "microk8s v1.31.14, 1 node",
  "requests": [
    {
      "method": "GET",
      "path": "/api/v1/namespaces/default/pods",
      "status": 200,
      "headers": { "content-type": "application/json" },
      "body_file": "responses/pods-default.json"
    },
    {
      "method": "GET",
      "path_re": "^/api/v1/nodes/[^/]+/proxy/stats/summary$",
      "status": 200,
      "body_file": "responses/stats-summary.json"
    }
  ],
  "streams": [
    {
      "method": "GET",
      "path": "/api/v1/pods?watch=true&resourceVersion=12345",
      "chunks": [
        { "delay_ms": 0,    "body_file": "streams/watch/added-1.ndjson" },
        { "delay_ms": 200,  "body_file": "streams/watch/modified-1.ndjson" },
        { "delay_ms": 1000, "close": true }
      ]
    }
  ]
}
```

Why this shape:

- **One manifest + body files** rather than one big JSON: bodies stay
  diffable, redactable, version-controllable, and aren't drowned in
  escaping.
- **`path` vs `path_re`**: exact match for known URLs, regex for
  per-node / per-pod URLs whose names vary across captures.
- **Streams as chunk timelines**: replaying the original chunk
  boundaries + delays exercises the real process-filter / debouncer /
  ndjson-splitter code paths — not just the parse.

## 3. Capture mode

New module `test/eltainer-http-record.el`.

- `eltainer-http-recording-dir` — when bound to a directory, every
  `docker-http-request` and `docker-http-stream` call is *also*
  written there.
- A small `advice-add` on the two seam functions: post-call, append
  to the manifest JSON and write the body file.
- Stream advice wraps `:on-chunk` and `:on-close` to record bytes +
  monotonic timestamps.

Workflow:

```
M-x eltainer-start-recording RET test/fixtures/microk8s-pods-default RET
…drive eltainer interactively against a real cluster for a minute…
M-x eltainer-stop-recording
```

The directory now holds a complete scenario.

### Redaction

A post-capture pass — `M-x eltainer-redact-fixture RET <dir>` — that:

- Strips `Authorization` headers from request/response logs.
- Replaces `Secret` resource `data` fields with `"<redacted>"`.
- Removes any TLS cert PEM that snuck into a response body.
- Lets the user spot-check before committing.

## 4. Replay mode

New module `test/eltainer-http-replay.el`.

- `(with-eltainer-fixture FIXTURE-NAME BODY...)` macro:
  1. Loads the manifest for `FIXTURE-NAME`.
  2. `cl-letf`s `docker-http-request` and `docker-http-stream` to
     intercept calls.
  3. Runs BODY.
  4. Unwinds the letf.

- **Sync replays** return the canned `docker-http-response` struct
  synchronously — same shape callers expect.
- **Stream replays** return a fake process object whose `:on-chunk`
  fires via `run-at-time` at the recorded delays.  This is what makes
  watch-event tests meaningful: the debounce, the ndjson splitter, the
  retry-on-close logic all run for real.

- **Unmatched requests** signal `eltainer-fixture-miss`:
  ```
  (eltainer-fixture-miss "GET" "/api/v1/namespaces/foo/pods")
  ```
  Tests fail loudly when scenarios drift, with a clear message.

## 5. ERT integration

Files under `test/`:

```
test/
  eltainer-http-record.el      ; capture machinery (loaded for recording)
  eltainer-http-replay.el      ; replay machinery (loaded for tests)
  eltainer-tests.el            ; cross-cutting smoke tests
  k8s-pods-tests.el            ; per-feature
  k8s-nodes-tests.el
  k8s-metrics-tests.el
  k8s-watch-tests.el           ; uses streams from fixtures
  k8s-prom-tests.el
  docker-events-tests.el       ; uses streams
  fixtures/
    microk8s-pods-default-ns/
      manifest.json
      responses/
        pods-default.json
        stats-summary.json
      streams/
        watch/
          added-1.ndjson
          modified-1.ndjson
    kind-no-prometheus/
    docker-containers-mixed/
```

A small `eltainer-fixture-connection` helper builds a `k8s-connection`
whose `docker-cfg` is a sentinel value the replay layer keys on.  No
real socket needed.  No real kubeconfig parsed (the fixture stands in).

## 6. Minimal Viable Corpus

Capture these first — enough to lock in regression coverage for the
day-to-day surface:

1. **`microk8s-pods-default-ns`** — pods list, watch stream, metrics,
   summary.  Exercises the pod render hot path + container subsections.
2. **`microk8s-nodes`** — nodes list, metrics-server `/nodes`, Prom
   load averages + range queries.  Exercises the cursor-preservation
   + expansion-stickiness fixes.
3. **`microk8s-deployments-and-rs`** — deployments + replicasets.
   Covers the macro-generated views.
4. **`kind-no-prometheus`** — same shape, no Prometheus Service.
   Locks in graceful-degradation: Prometheus rows must not appear.
5. **`microk8s-cronjob-with-runs`** — CronJob → Job → Pod chain + the
   completed pod's log stream.  Covers `k8s--cronjob-latest-pod` and
   the streaming log path.
6. **`docker-containers-mixed`** — containers / networks / images
   list, `/events` stream replay.  Covers the docker events
   debouncer + metrics ticking.

## 7. CI

`Makefile`:

```make
test:
	emacs -batch \
	  -L . -L docker -L k8s -L test \
	  -l ert -l test/eltainer-tests.el \
	  -f ert-run-tests-batch-and-exit
```

GitHub Actions matrix: Emacs 30 + 31, Linux + macOS.  Tests run with
no Docker daemon and no `~/.kube/config` present — the replay layer
satisfies every dependency.

## 8. Self-test of the harness

A meta-test:

- Capture a fixture.
- Replay the same fixture into a fresh buffer.
- Assert the rendered output matches a golden snapshot.

This catches drift in the recorder/replayer itself — if a future
change to either stops producing byte-identical replays, the snapshot
test fails.

## 9. What this *won't* cover

The mock seam is at HTTP.  Everything from JSON parse upward is
covered.  Out of scope (stays on manual smoke-test):

- Real socket lifecycle bugs (`delete-process` races, keep-alive
  teardown — see `docs/perf-plan.md` Tier-2 #6).
- TLS handshake edge cases (cert validation, expired CAs).
- `eat`-backed terminal rendering for interactive exec sessions.
- Real auth-plugin invocation (`aws eks get-token`, etc.) — those
  funnel through `eltainer-shell-helper`, easier to test there
  directly.

The big productivity win — parsing, rendering, metrics math, and
watch-event handling against real data — comes free.

## 10. Order of work

1. **`eltainer-http-replay.el`** — replay first, even before recording.
   Hand-author one tiny fixture (`microk8s-pods-default-ns`) by copying
   `kubectl get … -o json` output.  Get one passing ERT test.  Proves
   the seam.
2. **`eltainer-http-record.el`** — recording mode.  Capture the same
   scenario from a real cluster; diff against the hand-authored one.
3. **Redaction pass.**
4. **Capture the Minimal Viable Corpus** (§6).
5. **Per-feature test files** filling in until coverage feels honest.
6. **CI hookup** + the meta-self-test.

Each step ships independently and provides value on its own.
