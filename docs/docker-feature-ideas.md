# Feature ideas: derived from the broader Docker-UI landscape

Companion to `docs/feature-ideas.md', this one covers the
*docker* side.  Source field-survey of comparable tools (Portainer,
Docker Desktop, Dockge, lazydocker, Yacht, Dozzle, ctop) — names
omitted in the entries below; each feature is described on its
own merits.

Already shipped on eltainer's docker side, for the avoidance of
doubt: containers list (running + all), images, networks, image
pull with per-layer progress, container logs (streaming, ANSI),
TTY exec, container-dired filesystem browser (read+write +
wdired), per-container metrics gauges (CPU / memory / disk / net
/ pids) with sparklines, DNS lookup from inside a container,
docker engine `/events' stream, network attach / detach.

Status of each below: **idea** = not planned yet; **proposal** =
has a `docs/docker-<feature>-plan.md`.  Promote to
`docs/new-features.md' when graduating from idea to drafted.

---

## Compose-stack management  *(v1 read-only shipped 2026-05-27; v2 writable still idea)*

A first-class view of "stacks" (a stack = a `docker-compose.yml`
file declaring a set of services + networks + volumes that share
a project name).  Workflows:

- **List stacks**.  Group every container by its `com.docker.compose.
  project` label.  Show: project name / # services running / # total
  / status / created-at.  One key from the dashboard (probably `M`
  for "compose", or `K` for "stack" since `s` is taken).
- **Expand a stack** to its services (`com.docker.compose.service`
  label).  Each service expands to its container(s).  Magit-section
  for natural folding.
- **Stack-level actions**:
  - `u` — up (compose up, reattaches to running ones, recreates the
    rest)
  - `d` — down (stop + remove)
  - `r` — restart (rolling)
  - `P` — pull all images
  - `l` — multi-service log tail (one buffer, each service a colour
    — exactly like the multipod k8s logs view, just docker labels
    in the place of pod selectors)
- **Edit `docker-compose.yml` in place** (`Y` analogous to k8s `Y`
  edit-and-apply).  Re-up the stack on save.  The engine API
  doesn't expose compose-state directly — we'd need to read the
  source `.yml` from a configured directory.

Implementation note: docker compose state isn't first-class in
the engine API.  The `compose` CLI synthesises it from labels.  We
do the same: walk `/containers/json?all=1` and group by the
project label.  For `up`/`down` we'd need to invoke the `compose`
plugin which IS a CLI shell-out — that breaks the no-CLI
invariant unless we re-implement compose semantics (substantial:
volume bindings, network creation, dependency ordering).  Realistic
phasing: read-only "stack list + expand + multi-service logs"
first; mutating ops as a v2 with an explicit no-CLI exception.

---

## Image build from a Dockerfile in a buffer  *(shipped 2026-05-27)*

Open a buffer over a Dockerfile (`C-x C-f Dockerfile`), then
`M-x docker-build`: posts the directory's tar to `POST /build`
with `Content-Type: application/x-tar`, streams the response (a
JSON stream of `{stream: "..."}` per line, one progress dot per
line per layer).  Renders in a buffer like `docker-pull-image`
does for image pulls.  Cancel mid-stream by closing the buffer.

Edge cases worth surfacing:
- `.dockerignore` parsing (we need to skip ignored files when
  building the tar).
- BuildKit (`Content-Type: application/x-tar` + buildkit-specific
  headers) — defer; classic builder is fine for v1.
- Multi-platform / `buildx` — not in scope.

---

## Image push to a registry  *(shipped 2026-05-27)*

We already have `docker-pull-image' (`u' on the dashboard's
docker group).  Push is the mirror: POST `/images/<name>/push`
with the registry credentials from `~/.docker/config.json` (which
eltainer already reads via `docker-auth.el`).  Streams progress
the same way pull does.  Same UX, different verb.

---

## Container create from a form  *(shipped 2026-05-27)*

Today eltainer manages existing containers; you can't create one.
A "new container" buffer (similar to `k8s-edit' but with a fresh
template) presents the most useful POST `/containers/create` JSON
fields:

- Image
- Command + args
- Env vars (table; `+` adds, `-` removes a row)
- Port bindings
- Volume mounts (bind / volume)
- Network
- Restart policy
- Labels

`C-c C-c` POSTs.  Defaults to "the form you'd expect": detach=true,
restart-policy=unless-stopped.  Bind to `+' on the containers view.

The fancier variant is a small interactive form using `widget`;
the duller variant is a YAML-shaped JSON document the user edits
freely.  Latter is faster to ship.

---

## Volume browser + usage stats  *(shipped 2026-05-27)*

A view of every named volume on the daemon: NAME / DRIVER /
MOUNTPOINT / SIZE / CREATED / IN-USE-BY (containers referencing
it).  `RET` on a volume drills into the container-dired view over
that volume's contents (we already mount-resolve filesystems
inside containers via the docker archive API — same machinery
works on a volume's mountpoint).

Per-volume size requires `docker system df -v`-equivalent
(`GET /system/df`) which the engine API does expose.

`d' deletes (with confirmation, refuses if in use).  Eltainer's
`d' on a Networks row already does the analogous thing.

---

## Registry / image search + credentials manager  *(idea, lower priority)*

Wrap `GET /images/search?term=...` and the auth helpers we
already invoke for pull (`docker-credential-*` plugins via
`eltainer-shell-helper.el`).  A small "search Docker Hub /
configured registry" buffer with one-key `pull`.  Then a viewer
for which auths are configured and where they came from.

---

## Container creation from templates  *(idea)*

Saved YAML/JSON templates for "the kind of container the user
runs all the time" — Redis-with-these-flags, Postgres-with-this-
volume, etc.  `M-x docker-template-create` instantiates one with
a couple of prompts.  Cheap by piggybacking on the
container-create form (above).

---

## Dockerfile lint / build-cache prune  *(idea, lower priority)*

Read-only: `M-x docker-system-df` shows the breakdown of disk used
by images / containers / volumes / build cache, with a one-key
`prune` for each.  The engine API exposes both pieces
(`/system/df`, `/build/prune`).

---

## Single-host multi-stack dashboard  *(shipped 2026-05-27)*

A "pulse" for docker (analogous to the k8s cluster-pulse already
shipped).  Aggregate: total containers (running/stopped),
images cached, total disk by category, recent events count by
type.  One screen, useful on a docker host that's been running
unattended for a while.

---

## Out of scope (intentional)

- **Multi-host orchestration**.  Docker Swarm is supported by
  the engine API but eltainer's design point is single-host
  docker + multi-cluster k8s.  Don't pretend to be Portainer
  Enterprise.
- **Kubernetes-mode for the docker side**.  Some Docker UIs ship
  "manage K8s through this UI" too — that's what eltainer's k8s
  side already is; no need to duplicate.
- **Compose v1 (Python)**.  Dead.  Only target v2 (the Go
  plugin's data shape).
- **Vendor extensions / marketplaces**.  No plugin story for
  eltainer's docker side beyond the regular emacs package
  ecosystem.

---

## Prioritisation (rough)

1. **Compose-stack view (read-only)** — biggest single value-add
   for docker users.  Most other docker UIs feature it
   prominently.
2. **Single-host pulse** — high signal, low scope.  Mirrors the
   shipped k8s pulse.
3. **Container create form** — many users want it, the engine
   API makes it straightforward.
4. **Volume browser** — small, useful.
5. **Image build** — useful for the "Dockerfile open in Emacs"
   workflow, but BuildKit makes it a moving target.
6. **Image push** — completeness of the image-management story.

This list is a menu, not a roadmap.  Pick what looks fun.
