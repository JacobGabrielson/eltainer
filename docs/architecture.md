# Architecture

eltainer is two backends — Docker daemon and Kubernetes API server —
fronted by a single magit-style UI and **one** transport stack.  No
`docker` CLI and no `kubectl`; the rare CLI fallbacks are documented
exceptions for things the daemon APIs genuinely can't do.

This document started life as the plan for dropping the Docker CLI
(shipped 2026-05-15, all six phases landed) and was extended later
(2026-05-18) to cover the Kubernetes half.  The rest of the doc is
the same plan-as-it-shipped record; the requirements / constraints /
"what we deliberately keep" sections apply to both backends now.

## Stack at a glance

```
  eltainer-ui          shared faces, age-string, describe-value
  eltainer-terminal    eat / vterm / term backend selector
  eltainer-shell-helper invoke external helper binaries (cred / exec
                       plugins)
  docker-http          HTTP/1.1 over unix / TCP / TCP+TLS (GnuTLS);
                       sync + streaming.  k8s + docker both use this.
  docker-stream        chunked decoder, ndjson splitter, mux demux

      ↑
      │ shared
  ────┴────                     ────┴────
  docker/  domain modules       k8s/    domain modules
   - docker-config, -api, -ps    - k8s-config, -api, -watch,
   - -images, -networks,           -pods, -fs, -fs-ui, -exec
   - -events, -logs, -exec,        - k8s.el (views + transient)
   - -auth, -pull, docker.el
```

Both halves use `docker-config` as the connection-params struct; the
Kubernetes side builds one out of its kubeconfig and threads it
through `docker-http-request` / `docker-http-stream` exactly like the
Docker side does.

The remainder of this document is the original Docker-CLI-removal
plan; it's the most detailed living record of what the transport
does and doesn't do.

## Requirements (Emacs 30+)

The rewrite assumes a modern Emacs and uses its built-in facilities
rather than pulling in elisp libraries that reimplement them.

- **Native JSON.** Use `json-parse-string` / `json-parse-buffer` (the
  C-implemented parsers shipping since Emacs 27) for *all* decoding,
  and `json-serialize` for request bodies. Do not require `json.el`.
  At load time:

  ```elisp
  (unless (fboundp 'json-parse-string)
    (error "eltainer requires native JSON support (Emacs built with
            --with-json or Emacs 27+ with libjansson)"))
  ```

  Native JSON returns hash-tables by default; we pass
  `:object-type 'alist :array-type 'list :null-object nil
  :false-object :false` so the rest of the code (which already speaks
  alists today) doesn't need to change.

- **GnuTLS.** Use Emacs' built-in gnutls integration for `tcp+tls://`
  daemons via `make-network-process :tls-parameters …`. Do not fall
  back to a Lisp TLS library, do not shell out to `openssl s_client`.
  At load time, when a TLS-requiring `docker-config` is detected:

  ```elisp
  (unless (gnutls-available-p)
    (error "eltainer requires GnuTLS support to talk to %s — rebuild
            Emacs --with-gnutls" host))
  ```

  Unix-socket and plain TCP daemons still work without GnuTLS; only
  the TLS path refuses.

Both checks live in `docker-http.el` so the rewrite fails loudly and
early on environments that can't actually run it.

## Why

Today every read and every action is a `call-process` to `docker`. That
buys us free TLS, free auth, free `--context` resolution, and a CLI that
knows how to talk to all daemon versions. It also costs us:

- A fork+exec per call. Listing 100 containers means 100 processes.
- No real async. `start-process` for logs streams docker's *parsed*
  output rather than the raw stream. Things like the events API are
  invisible to us.
- Output is line-oriented. Multiplexed stdout/stderr (the 8-byte STREAM
  frames the daemon emits for non-TTY containers) is flattened into one
  text blob.
- The CLI prints chatty Docker-Desktop hints to stderr (which we papered
  over with `DOCKER_CLI_HINTS=false`), and uses platform-specific exit
  codes.

The Phase 4 spike (`docker-daemon.el`) already proves the wire works:
one `GET /containers/json` over the Unix socket, ~120 lines, no
dependencies beyond `json.el`. The rewrite is "do that, but for every
endpoint."

## What we gain

- One persistent transport (or one short-lived connection per request)
  instead of a process per call. Listing is faster; refreshes are
  cheaper; nothing needs PATH-resolution.
- **Real streaming**. `/containers/{id}/logs?follow=1` arrives as 8-byte
  framed bytes we can split into stdout vs stderr properly, with
  per-frame colorization.
- **The `/events` endpoint**. The daemon will tell us when a container
  starts, dies, gets connected to a network, etc. We can use this to
  auto-refresh magit-section views in the background — no `g`-press
  needed. This is the single highest-value endpoint and the CLI doesn't
  give us a comfortable way to consume it.
- Direct error paths: a 404 from the daemon stays a 404. No grepping
  CLI stderr to figure out "did this fail because the container was
  missing or because docker itself was missing?"
- Bidirectional `/exec` and `/attach` become tractable. Today
  implementing exec via the CLI is "spawn `docker exec -it`, pipe a
  pty," which Emacs barely supports. Directly: we open a hijacked TCP
  connection and pump bytes both ways via process filters.

## What "drop the CLI" actually means

We replace **the engine-API calls** (read, mutate, stream, exec) with
direct HTTP/JSON. We do **not** replace everything that ships with the
docker distribution. Several features are CLI plugins or other-process
RPCs that have no engine endpoint, and we keep the CLI as the
implementation for those. The rule is "we never shell out for
something the engine API can do," not "we never shell out at all."

### Aside: what *is* a docker context?

A context is a named bundle of "where to talk to a daemon" — endpoint
(unix socket / TCP+TLS / SSH), TLS material, optional Kubernetes config.
`docker context ls` shows them; the active one is recorded as
`currentContext` in `~/.docker/config.json`. Each context's details live
in `~/.docker/contexts/meta/<sha256-of-name>/meta.json` (a small JSON
file with the endpoint and TLS paths). The CLI consults this on every
invocation so that you can do `docker context use staging` once and
`docker ps` is automatically pointed at the staging daemon.

For us this means: instead of only honoring `DOCKER_HOST`, we should
also read `currentContext` from `~/.docker/config.json` and dereference
it through the contexts-meta directory. That covers users who set up
contexts (the recommended workflow) without ever exporting
`DOCKER_HOST`. Parsing the JSON is trivial; *creating or switching*
contexts we leave to the CLI.

### Where we deliberately keep `call-process`

These are explicit, isolated CLI shell-outs — each is a clearly-named
function in a single module, marked with a comment that says "engine
API can't do this; CLI fallback is intentional."

| Feature | Fallback | Reason |
|---------|----------|--------|
| `DOCKER_HOST=ssh://…` | `docker --host ssh://…` | The engine speaks HTTP; the CLI knows how to tunnel through SSH. Reimplementing SSH transport in Elisp is a separate project. |
| `docker build` | `docker build` (CLI invokes BuildKit) | Modern build is BuildKit gRPC — see "Why not BuildKit gRPC in Elisp?" below. |
| `docker buildx …` | `docker buildx …` | Same reason as build. |
| `docker compose …` | `docker compose …` | Compose is a project-level orchestrator; the daemon doesn't model "compose projects." |
| CLI plugins (`scan`, `scout`, `init`, `debug`, `dev`, `extension`, `sbom`, …) | the plugin binary | Each is its own product; no engine endpoint exists. |
| Credential helpers (`docker-credential-osxkeychain`, `-pass`, `-secretservice`) | the helper binary | These are designed for exactly this: stdin a hostname, stdout JSON with the secret. We invoke them directly (not via `docker`). |
| `docker login` / `logout` config writes | `docker login` | Credentials setup remains a CLI concern. We *read* the config after login. |

The exec path is special: non-TTY exec uses the engine API directly,
but **interactive TTY exec** is rendered into a screen-oriented terminal
emulator inside Emacs (see "Terminal backend" below). We don't shell
out to `docker exec -it` for this — we open the hijacked connection
ourselves and pipe bytes into the terminal emulator. The CLI fallback
for SSH already implies people get a screen-oriented terminal anyway
when they `ssh` from inside Emacs.

### Why not BuildKit gRPC in Elisp?

I said "infeasible" before — that was overstated. It's **feasible but
disproportionate**. To build images without invoking the CLI we'd
need, from scratch:

- An HTTP/2 framing implementation (RFC 7540): binary frames,
  multiplexed streams, flow control, settings, GOAWAY. Roughly
  500–1500 lines.
- HPACK header compression (RFC 7541): stateful, with a custom
  Huffman code and a dynamic index table. Another 300–600 lines.
- ALPN negotiation through `gnutls-boot-parameters` (needed for any
  HTTPS-side BuildKit; for the local Unix socket we'd skip TLS).
- A protocol-buffers encoder/decoder, by hand or generated from
  BuildKit's `.proto` files (control.proto, solver.proto, …). The
  wire format is well-documented (varints, length-delimited fields),
  but the BuildKit message catalog runs to dozens of types.
- The actual build-context tarball: walk the directory honoring
  `.dockerignore`, stream it into a tar over the gRPC channel.
- Tracking the progress-event stream that drives any kind of
  build-progress UI.

Order-of-magnitude guess: 3000–6000 careful lines, much of it
reimplementing what `protoc`/`grpc-go` already give the docker CLI for
free. And BuildKit's API moves; we'd be on the hook for keeping up.

Compared to `(apply #'call-process "docker" "build" args)`, which is
five lines. So "feasible but the value is somewhere else."

### Things we genuinely just don't do (even with the CLI)

- **`docker stats` fleet-wide synthesis.** Per-container streaming
  stats (`GET /containers/{id}/stats?stream=1`) is easy to surface;
  the CLI's "live table of all containers" is a layer above we'd have
  to reinvent. Per-container yes, fleet table later.
- **In-place layered progress bars during pulls.** The engine
  streams JSON progress events; the CLI redraws-in-place rendering of
  per-layer bars is a UI we'd design ourselves. Same data, different
  presentation.
- **Logging drivers that aren't `json-file`/`journald`.** If a
  container uses `syslog`/`gelf`/etc., `/logs` returns nothing. Same
  limitation the CLI has — but worth knowing.

### Terminal backend (for TTY exec / attach)

Interactive `exec -it` / `attach` needs a screen-oriented terminal
emulator inside Emacs — something that renders cursor motion, the
alt-screen, true colors, and modern xterm escape sequences well
enough that running `vim` or `htop` inside a container is pleasant.
We need this regardless of docker: the SSH-CLI fallback (above) also
drops users into a remote shell that wants a real terminal.

Survey of what's available in modern Emacs:

| Backend | What it is | Fidelity | Setup cost | Good fit? |
|---------|------------|----------|------------|-----------|
| `term` / `ansi-term` | Built-in. comint+terminfo emulator going back to the 90s. | VT100-ish; struggles with modern alt-screen TUIs and 256-color. | None — always present. | Floor only. |
| `eat` | Pure-Elisp xterm emulator (Akib Azmain Turja, on GNU ELPA / MELPA). | Strong xterm-256color coverage, smooth cursor motion, sixel-ish bits. Performance is genuinely good. | `package-install eat`. No native module. | **Default.** Best "zero-setup" option in 2026. |
| `vterm` (`emacs-libvterm`) | Dynamic module wrapping the same `libvterm` library `tmux` uses. | Best in class — anything that runs in `xterm` runs here. | Requires `cmake`, `libvterm`, and a compile step at install. | **Opt-in.** Power users will already have it. |
| `mistty` | New-ish package layering line-editing, history, and a virtual cursor on top of `term-mode`. | Same emulation as term — improvements are UX, not fidelity. | `package-install mistty`. | Not a fit — we want better emulation, not a smarter prompt. |
| `coterm` | Adds a subset of terminal escape parsing to plain `comint`/`shell-mode`. | Partial — meant to make `M-x shell` survive ANSI codes, not host vim. | `package-install coterm`. | Not a fit — not screen-oriented. |
| `eshell` (with `eshell-visual-commands`) | Elisp shell that delegates known TUI commands to a child term. | Whatever the delegate is (term, vterm, eat). | Configured per-command. | Not a fit — we're not running a shell, we're hosting one process. |
| `vterminal`, `emamux`, `multi-term`, etc. | Wrappers around `term-mode` with niceties. | Same as `term`. | Varies. | Not a fit. |

That gives us three real choices: `term`, `eat`, `vterm`. Plan:

- `defcustom docker-terminal-backend` of type
  `(choice (const :tag "Auto-detect" auto) (const eat) (const vterm) (const term))`,
  default `auto`. The `auto` value probes in order `eat` → `vterm` →
  `term` (first one that `featurep` / `fboundp` claims) and silently
  picks. Users who care can pin it.
- A tiny `docker-terminal--open BUFFER PROC` adapter with one function
  per backend (about 20 lines each). Each adapter does three things:
  open a buffer in the appropriate major mode, hand it the existing
  network process from the hijacked `/exec/{id}/start` connection,
  and arrange a resize hook that POSTs `/exec/{id}/resize?h=…&w=…`
  when the Emacs window size changes (this is what SIGWINCH does in a
  normal terminal).
- Hard-require nothing beyond `term`. `eat` and `vterm` are
  `(require '… nil 'noerror)` and only used if present.
- The same adapter hosts the SSH-CLI fallback's `ssh -t` shell, so
  one terminal abstraction serves both code paths.

Worth keeping a note that this exact abstraction (a "let me host a
PTY-ish process in a screen-oriented buffer") is a recurring need in
Emacs and there's no canonical answer; we're just choosing among the
imperfect ones.

## Reference

The Docker Engine HTTP API spec lives at
<https://docs.docker.com/engine/api/>. The current stable version is
`v1.45` (Docker 25.x+); the daemon will accept a versioned prefix
(`/v1.45/containers/json`) or an unversioned one. We negotiate by
hitting `/version` first and pinning to the major version we read back.

Endpoints relevant to the existing surface area:

| Today | Endpoint |
|-------|----------|
| `docker ps` | `GET /containers/json[?all=1]` |
| `docker inspect <c>` | `GET /containers/{id}/json` |
| `docker start/stop/restart/kill/rm` | `POST /containers/{id}/{verb}` |
| `docker logs -f` | `GET /containers/{id}/logs?follow=1&stdout=1&stderr=1` |
| `docker images` | `GET /images/json` |
| `docker rmi` | `DELETE /images/{name}` |
| `docker pull` | `POST /images/create?fromImage=…&tag=…` (streams progress) |
| `docker network ls` | `GET /networks` |
| `docker network inspect` | `GET /networks/{id}` |
| `docker network connect/disconnect` | `POST /networks/{id}/{verb}` |
| `docker network rm` | `DELETE /networks/{id}` |
| `docker exec` | `POST /containers/{id}/exec` → `POST /exec/{id}/start` (hijacked) |
| events | `GET /events` (streaming JSON-per-line) |

## Architecture

Three new files, every existing module rewritten on top of them.

### `docker-http.el` — transport

Minimal HTTP/1.1 client tailored to docker's daemon. Lives on top of
`make-network-process` with `:family 'local` (Unix socket) or
`'ipv4`/`'ipv6` (TCP, optionally TLS via `:tls-parameters`).

Public surface:

```
(docker-http-request CFG METHOD PATH &key headers body query)
  → (status headers body)   ; sync, body fully buffered

(docker-http-stream  CFG METHOD PATH &key headers query
                                          on-headers on-chunk on-close)
  → process                 ; async, body delivered via on-chunk
```

Responsibilities of this module:

- Run the load-time capability checks (native `json-parse-*` always;
  `gnutls-available-p` only if the active config requires TLS).
- Build the request line + headers (`Host`, `User-Agent`,
  `Connection`, `Content-Type`, optional `X-Registry-Auth`). Encode
  request bodies with `json-serialize`.
- Read the response status line + headers, then parse the body
  according to `Transfer-Encoding` (chunked decoder is already in the
  spike) or `Content-Length`. Connection-close framing for the stream
  case. Decode JSON responses with `json-parse-string`/`json-parse-buffer`
  passing `:object-type 'alist :array-type 'list :null-object nil
  :false-object :false`.
- For the stream case, install a process filter that buffers partial
  HTTP chunks and emits whole chunks/frames to `on-chunk`.
- TLS for `tcp://` daemons via GnuTLS:
  `:tls-parameters (cons 'gnutls-x509pki (gnutls-boot-parameters …))`,
  threading `tls-ca-cert` / `tls-cert` / `tls-key` from `docker-config`
  into the boot parameters.

This is the only file that knows about sockets, headers, bytes, JSON
framing, or TLS. Everything else is decoded alists in / encoded alists
out.

### `docker-stream.el` — framing helpers

Two parsers, used by `docker-http.el`'s on-chunk callbacks:

- **`docker-stream-demux`** — Docker's 8-byte multiplex header
  (`stream-type, 0, 0, 0, size32`) splits non-TTY container output into
  stdout / stderr / stdin streams. Used by logs, attach, exec without
  TTY.
- **`docker-stream-ndjson`** — line-oriented `\n`-terminated JSON
  framing. Used by `/events`, image-pull progress, image-build progress.

### `docker-auth.el` — registry credentials

Only needed for `pull` / `push`. Parses `~/.docker/config.json`,
resolves the credential helper for a given registry, runs that helper
(stdin: registry hostname; stdout: JSON with Username/Secret),
base64-encodes the auth blob, and returns the `X-Registry-Auth` value.

Independent of the rest — image-pull/push call this only when needed.

### Rewritten existing modules

`docker-api.el` shrinks dramatically. It becomes:

- `docker-engine-get`, `docker-engine-post`, etc. — thin shims over
  `docker-http-request` that JSON-encode bodies and JSON-decode replies.
- API-version negotiation (`/version` on first call per buffer, cached
  on the config struct).
- Error mapping (`{message: "..."}` → `signal 'docker-api-error`).

`docker-ps.el`, `docker-images.el`, `docker-logs.el`,
`docker-networks.el` each lose their `docker-command` calls and gain a
single endpoint per public function:

```elisp
(defun docker-list-containers (cfg &key all)
  (let ((data (docker-engine-get cfg "/containers/json"
                                 :query `(("all" . ,(if all "1" "0"))))))
    (vconcat (mapcar #'docker--container-from-json data))))
```

No structural changes to the data structures — same `docker-container`,
`docker-image`, `docker-network`, `docker-network-member` structs.
The mapping from JSON keys may shift slightly (the daemon uses
`PascalCase`; the CLI's `--format '{{json .}}'` uses some different
keys), but the structs are an internal abstraction we already own.

`docker-daemon.el` is deleted — the spike is subsumed by `docker-http.el`.

### New: `docker-events.el`

A long-lived `docker-http-stream` connection to `/events` plus a
publish/subscribe layer. Each docker view buffer subscribes to the
event types it cares about; on relevant events, the buffer auto-refreshes
(debounced, so a `docker compose up` doesn't repaint 30 times in 200ms).

This is the killer feature of the rewrite and worth front-loading once
the transport works.

## Phased migration

Each phase is a working, committable, mergeable state. Tests stay green
throughout.

### Phase 0 — transport (1 module, no behavior change)

1. Promote the spike into `docker-http.el` with the public API above.
2. Rewrite `docker-daemon-ps` to use it as a sanity check.
3. Tests: `test-docker-http.el` against a live daemon plus a few unit
   tests for the chunked decoder and header parser.

No production code is touched. The CLI path stays the only consumer of
the real API.

### Phase 1 — reads (containers + images + networks)

1. Add `docker-engine-get` to `docker-api.el`.
2. Convert `docker-list-containers`, `docker-inspect-container`,
   `docker-list-images`, `docker-inspect-image`, `docker-list-networks`,
   `docker-inspect-networks` to the engine API.
3. Adjust the JSON-key mapping in the from-JSON constructors.
4. Existing tests must still pass; add new ones that pin the daemon
   shape (so future API-version drift gets caught).

After this phase, listing/inspecting works without the CLI. Mutating
actions still shell out.

### Phase 2 — lifecycle (container + network mutations)

1. Add `docker-engine-post`, `docker-engine-delete`.
2. Move `docker-start-container`, `…-stop-…`, `…-restart-…`,
   `…-kill-…`, `…-remove-…`, `docker-network-connect`,
   `…-disconnect`, `docker-remove-network`, `docker-remove-image` over.
3. All "act on the resource at point" keybindings keep working.

After this phase the CLI is only used for logs, exec, pull, and build.

### Phase 3 — streaming (logs, then events)

1. Implement `docker-http-stream` (async filter pipeline).
2. Rewrite `docker-logs-start` to use it. Use `docker-stream-demux` to
   colorize stdout vs stderr.
3. Add `docker-events.el` and wire auto-refresh into the containers /
   images / networks views.

This is the visible-payoff phase. Logs gain proper stream separation;
the views stop being stale until you press `g`.

### Phase 4 — interactive (exec, attach)

1. Implement hijacked-connection support in `docker-http.el` (the
   daemon switches the connection to raw byte streaming after a
   `101 Switching Protocols` or after the request completes for
   `/exec/{id}/start`).
2. Add `docker-exec.el` (the container exec view).
3. Add `docker-attach.el` if there's appetite.

### Phase 5 — registry (pull, push)

1. `docker-auth.el` to resolve credentials from `~/.docker/config.json`.
2. Implement `docker-pull-image` on `POST /images/create`; surface the
   JSON progress stream in a buffer like `*docker:pull:nginx*`.
3. Push later.

### Phase 6 — cleanup

1. Delete `docker-command` / `docker-json-command` / `docker-ndjson-command`
   / `docker-async-command` / the TLS-flag helper.
2. Delete `docker-daemon.el` (subsumed long ago).
3. Update CLAUDE.md: remove the "shell out only to docker products" rule
   and document the new "we are a Docker daemon HTTP client" rule. The
   one remaining shell-out is to credential helpers (which we frame
   as an OS-level secrets concern, not a Docker concern).

## Tricky parts to think about up front

**API version pinning.** Hitting `/containers/json` without a version
prefix works against any modern daemon, but the response shape has
shifted across versions. Pin to whatever `/version` reports (or one
minor below) and put the version into the path: `/v1.43/containers/json`.

**Chunked transfer + connection reuse.** HTTP/1.1 keep-alive plus
chunked transfer is fine to implement, but for the streaming endpoints
the daemon doesn't always frame nicely — `/exec/{id}/start` hijacks
the connection mid-response and switches to raw bytes. Once hijacked,
the connection is no longer HTTP. Our filter has to know to stop
parsing chunked encoding at the hijack boundary. The signal is the
`Connection: Upgrade` header or specific status codes.

**Backpressure.** A `docker logs -f` on a noisy container can flood
us. Process filters in Emacs are not throttled; we need to either
trim the buffer (`docker-logs-max-lines`?) or pause reads on a busy
buffer.

**Errors.** The daemon returns `{message: "Error response from daemon: ..."}`
with the right HTTP status code. Translate these into a typed
`docker-api-error` with `:status`, `:message`, `:endpoint` slots so
view code can pattern-match.

**TLS on `tcp://`.** `make-network-process :tls-parameters` works
against Emacs' built-in GnuTLS, but the client cert/key/ca flags from
`docker-config` need to land on the right `gnutls-boot-parameters`
plist. Untested in the spike. The fallback path is "refuse and tell
the user to rebuild Emacs `--with-gnutls`" rather than degrading to a
Lisp-side TLS library.

**`DOCKER_HOST=ssh://…`.** Out of scope for the rewrite. Either keep a
CLI fallback for that one transport, or refuse and tell the user to
set up port-forwarding. Decision: refuse; document.

## Test strategy

- Keep ERT tests against a real local daemon (we have these today).
  They should pass at every phase boundary.
- Add `test-docker-http.el` for unit tests that don't need a daemon:
  chunked decoder, header parser, multiplex-frame splitter, NDJSON
  splitter. These run instantly and catch most parsing regressions.
- Add a `test-docker-events.el` that subscribes to `/events`, runs a
  `docker run --rm hello-world`, asserts the matching `start` and
  `die` events arrive.

## Open questions

- How aggressively do we want to auto-refresh on events? Per-event
  refresh feels twitchy; a 250ms debounce is probably right but worth
  measuring with a noisy daemon (e.g., `docker compose up` of a 20-
  service stack).
- Worth gating the rewrite behind a `docker-engine-backend` custom
  (`'cli` vs `'http`) for a release or two so we can compare side by
  side, or just cut over per phase and revert if it bites?
- Where does the terminal-backend adapter live? `docker-terminal.el`
  feels right (parallel to `docker-http.el`), but it's general enough
  that splitting it into a stand-alone package could be useful — and
  bringing it back in via a hard dependency is a real trade.
