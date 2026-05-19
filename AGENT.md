# AGENT.md — Project rules for eltainer

## What this project is

A pure Emacs Lisp client and magit-style browser for Docker and
Kubernetes.  No external dependencies — all parsing, UI rendering, and
business logic is pure Elisp.

## UI conventions — magit by default

**The UI must behave like magit.**  Section-based buffers, transient
dispatch menus, single-letter actions, `n`/`p`/`TAB` navigation, `g` to
refresh, `q` to quit, `b` for switch-like actions, and so on.  When in
doubt, do what magit does.

Deviations are allowed only when the underlying domain (Docker /
Kubernetes) has no magit-equivalent concept — and any such deviation
must be a deliberate choice, called out in the diff and (if it'll
surprise a contributor) noted here.

## Implementation plan (2026-05-13)

### Phase 1 — Core infrastructure

1. **docker-config.el** — Docker socket path detection, environment config
   - Detect DOCKER_HOST, default socket path, TLS settings
   - Config struct for connection parameters

2. **docker-api.el** — Docker CLI wrapper
   - Pure Elisp wrapper around `call-process` / `start-process` for docker CLI
   - JSON output parsing with Emacs built-in `json.el`
   - Error handling, exit code checking, retry logic
   - Functions: docker-command (synchronous), docker-command-async

3. **docker-ps.el** — Container listing (docker ps)
   - List containers (running/all), format columns
   - Start, stop, restart, rm, kill containers
   - Inspect containers (docker inspect)

4. **docker-images.el** — Image management
   - List images (docker images)
   - Pull, push, build, rmi images
   - Tag, inspect images

5. **docker.el** — Shared magit-section UI infrastructure
   - Magit-section based buffer for container/image views
   - Transient menus for actions
   - Keybinding conventions matching magit-style flows

### Phase 2 — Advanced features

6. **docker-logs.el** — Log viewing and tailing
   - Follow/tail container logs (docker logs -f)
   - Timestamps, latest N lines, streaming via async process

7. **docker-exec.el** — Container exec
   - Run commands in containers interactively
   - Attach to container stdin/stdout

8. **docker-compose.el** — Docker Compose support
   - Compose up/down, ps, logs, exec
   - Service filtering, project-scoped views

### Phase 3 — Polish

9. **reload.el** — Dev helper: byte-compiles + reloads all modules
10. **test/** — ERT tests using a local Docker daemon
    - test-docker-api.el — CLI wrapper tests
    - test-docker-ps.el — Container listing tests
    - test-docker-images.el — Image listing tests
    - test-docker-compose.el — Compose tests

### Phase 4 — Direct-daemon spike (exploratory)

11. **docker-daemon.el** — Trial: bypass the docker CLI entirely and
    speak HTTP directly to the daemon over the Unix socket.
    Intentionally tiny — implement only
    `GET /containers/json` so we can compare ergonomics with the
    CLI-backed code paths. Not wired into the magit view; just an
    interactive `docker-daemon-ps` that prints container names.

    Constraint relaxation note: this phase deliberately violates the
    "shell out only to docker products" rule for one file, to see how
    pure-daemon code feels. If we like it, later phases can graduate
    more of the surface area onto it.

### File layout (final)

```
docker-config.el   — Docker socket/env config, structs
docker-api.el      — Docker CLI wrapper (sync/async JSON parsing)
docker-ps.el       — Container listing, start/stop/rm
docker-images.el   — Image listing, pull/push/build/rmi
docker-logs.el     — Log tailing (follow, timestamps, streaming)
docker-exec.el     — Container exec (interactive commands)
docker-compose.el  — Docker Compose operations
docker.el          — Shared UI infrastructure, all views
reload.el          — Dev helper: compile + reload all modules
test/              — ERT tests against local Docker daemon
```

### Key dependencies (Emacs packages)

- `magit-section` — section-based UI (collapsible, navigable)
- `transient` — popup menus (action dispatch, ? key)
- `json.el` — ships with Emacs (JSON parsing from docker CLI output)
- `cl-lib` — ships with Emacs (cl-defstruct, etc.)

## Core constraints

- **Pure Elisp only.** Every line of code must be Emacs Lisp.
- **Talk to the daemon directly over its HTTP API.**  Both the Docker
  daemon and the Kubernetes API server are reached via `docker-http`
  (Unix socket / TCP / TCP+TLS via built-in GnuTLS).  No `docker` CLI
  and no `kubectl` in production code paths.  See
  `docs/architecture.md`.
- **Native JSON only.** Use `json-parse-string`/`json-parse-buffer`
  and `json-serialize`; refuse to load on Emacs without them.
- **The narrowly-scoped exceptions** (each in a clearly-named helper):
  - Docker: build / buildx (BuildKit gRPC), `docker compose`, CLI
    plugins, `docker login` config writes, `DOCKER_HOST=ssh://…`
    transport, `docker-credential-*` helper invocations.
  - K8s: `users.exec` plugins (`aws eks get-token`,
    `gke-gcloud-auth-plugin`, …) for kubeconfig credentials.
  Test scaffolding may shell out for sentinel containers — production
  code never does.
- **Target Emacs 30+.**

## Code style

- Always use `lexical-binding: t` in file headers.
- Use `cl-lib` (cl-defstruct, cl-loop, etc.) — ships with Emacs.
- Prefix all public symbols with `docker-` (e.g., `docker-list-containers`).
- Prefix internal/private symbols with `docker--`.
- Use `defcustom` for user-facing configuration, `defvar` for state.

## UI conventions

- Follow magit's UI patterns: collapsible sections, single-key navigation, transient menus.
- All views derive from `magit-section-mode`.
- Buffer names: `*docker:<view>*` (e.g., `*docker:containers*`, `*docker:images*`).
- Log buffers: `*docker:logs:<container>*`.

### Keybinding conventions

| Key | Action | Scope |
|-----|--------|-------|
| `g` | Refresh (fresh docker CLI call) | All views |
| `q` | Quit | All views |
| `d` | Delete/remove resource | All views |
| `i` | Inspect resource | All views |
| `s` | Start container | Containers view |
| `S` | Stop container | Containers view |
| `r` | Restart container | Containers view |
| `l` | View logs | Containers view |
| `e` | Exec command | Containers view |
| `?` | Transient dispatch menu | All views |
| `TAB` | Expand/collapse section | All views |
| `RET` | Smart action or inspect | All views |
| `n/p` | Next/prev section (magit) | All views |

## Testing

- Use `emacs --script` to run tests.
- Tests are ERT, in `test/` directory, named `test-<module>.el`.
- Tests hit a local Docker daemon (docker CLI must be available).
- A running Docker daemon is required — that is the whole point.

```bash
emacs --script test/test-docker-api.el
emacs --script test/test-docker-ps.el
emacs --script test/test-docker-images.el
```

## Demo recording

Record demos using `asciinema` (install with `brew install asciinema`).
Use `asciinema rec` to record terminal sessions showing eltainer in
action. Store recordings in a `demos/` directory (not committed to git).

## User preferences

- Keep responses concise — the user is an expert Elisp developer.
- Use `completing-read` for container/image selection.
- Use `transient` for action menus.
