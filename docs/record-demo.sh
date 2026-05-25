#!/usr/bin/env bash
# Record an eltainer demo into docs/<name>-demo.gif.
#
#   record-demo.sh [exec|metrics|marks]  (default: exec)
#
#   exec     — dashboard, docker exec, context switch, pod logs,
#              multi-container picker         -> docs/exec-demo.gif
#   metrics  — docker + k8s resource gauges   -> docs/metrics-demo.gif
#   marks    — dired-style marks + stern-style multipod log tail
#                                             -> docs/marks-demo.gif
#
# Pipeline:
#   1. asciinema rec --command "emacs -nw -Q -l <name>-demo-init.el" -> .cast
#   2. agg .cast .gif (asciinema's static GIF converter)
#
# Requires: asciinema, agg, emacs in a 100x30 TTY.  Re-runnable.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
demo="${1:-exec}"
case "$demo" in
  exec)    init="$here/demo-init.el" ;;
  metrics) init="$here/metrics-demo-init.el" ;;
  marks)   init="$here/marks-demo-init.el" ;;
  *) echo "record-demo.sh: unknown demo '$demo' (exec|metrics|marks)" >&2; exit 1 ;;
esac
cast="$here/${demo}-demo.cast"
gif="$here/${demo}-demo.gif"

KUBECONFIG=${KUBECONFIG:-$HOME/.kube/configs/config-kind}
export KUBECONFIG

# --- sentinels -------------------------------------------------------------

ensure_pod () {  # ensure_pod NAME <<<MANIFEST
  if ! kubectl get pod "$1" >/dev/null 2>&1; then
    kubectl apply -f - >/dev/null
    kubectl wait --for=condition=Ready "pod/$1" --timeout=90s >/dev/null
  fi
}

if [ "$demo" = exec ]; then
  # Docker sentinel: a container echoing a tick line on a loop.
  if ! docker ps --format '{{.Names}}' | grep -qx eltainer-ticker; then
    docker run -d --name eltainer-ticker alpine:3.20 \
      sh -c 'i=0; while true; do echo "tick $i $(date)"; i=$((i+1)); sleep 5; done'
  fi
  # k8s log-streaming pod for the `l' scene.
  ensure_pod log-ticker <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: log-ticker}
spec:
  restartPolicy: Always
  containers:
  - name: ticker
    image: busybox:1.37
    command: ["/bin/sh","-c","i=0; while true; do echo \"tick $i $(date)\"; i=$((i+1)); sleep 1; done"]
YAML
  # Two-container pod for the `e' container-picker scene (with limits).
  ensure_pod duo-box <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: duo-box}
spec:
  restartPolicy: Always
  containers:
  - name: app
    image: alpine:3.20
    command: ["/bin/sh","-c","echo app-container; sleep infinity"]
    resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: 100m, memory: 64Mi}}
  - name: sidecar
    image: busybox:1.37
    command: ["/bin/sh","-c","echo sidecar-container; sleep infinity"]
    resources: {requests: {cpu: 25m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
YAML
fi

if [ "$demo" = marks ]; then
  # 3-replica deployment of chatty pods so there's something live for
  # the multipod tail to render in colour.  Each pod prints its own
  # name in every line so the per-pod prefixes are obviously distinct
  # in the recording.
  if ! kubectl get deploy chatty >/dev/null 2>&1; then
    kubectl apply -f - <<'YAML' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: chatty}
spec:
  replicas: 3
  selector: {matchLabels: {app: chatty}}
  template:
    metadata: {labels: {app: chatty}}
    spec:
      containers:
      - name: ticker
        image: busybox:1.37
        command:
        - /bin/sh
        - -c
        - |
          i=0
          while true; do
            echo "[$(hostname)] tick $i $(date +%H:%M:%S)"
            i=$((i+1))
            sleep 1
          done
YAML
    kubectl rollout status deploy/chatty --timeout=90s >/dev/null
  fi
fi

if [ "$demo" = metrics ]; then
  # Docker sentinel under steady load (~50% of a core, ~90 MiB) with a
  # memory limit, so the container gauges show real fill.
  if ! docker ps --format '{{.Names}}' | grep -qx eltainer-load; then
    docker run -d --name eltainer-load --memory=256m python:3.12-alpine \
      python3 -c 'import time
d=bytearray(90*1024*1024)
while True:
    t=time.time()
    while time.time()-t<0.05: sum(i*i for i in range(2000))
    time.sleep(0.05)'
  fi
  # k8s sentinel with a burst/idle cpu+mem+network cycle.
  ensure_pod flux-box <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: flux-box}
spec:
  restartPolicy: Always
  containers:
  - name: flux
    image: python:3.12-alpine
    resources: {requests: {cpu: 200m, memory: 64Mi}, limits: {cpu: "1", memory: 256Mi}}
    command:
    - python3
    - -c
    - |
      import time, subprocess, sys, ssl, urllib.request
      ALLOC = "d = bytearray(110*1024*1024); import time; time.sleep(33)"
      CTX = ssl._create_unverified_context()
      URL = "https://kubernetes.default.svc.cluster.local/healthz"
      while True:
          child = subprocess.Popen([sys.executable, "-c", ALLOC])
          end = time.time() + 30
          while time.time() < end:
              t = time.time()
              while time.time() - t < 0.05:
                  sum(i * i for i in range(2000))
              try: urllib.request.urlopen(URL, timeout=2, context=CTX).read()
              except Exception: pass
          child.wait()
          time.sleep(30)
YAML
fi

rm -f "$cast" "$gif"
export DOCKER_CLI_HINTS=false

# asciinema needs a real TTY; `script' fabricates a PTY.  util-linux
# `script' takes the file last + command via `-c'; BSD takes the file
# first.  Detect at runtime.
rec_cmd="stty rows 30 cols 100
  export TERM=xterm-256color
  asciinema rec --overwrite --cols 100 --rows 30 --idle-time-limit 1.5 \
    --command \"TERM=xterm-256color emacs -nw -Q -l '$init'\" '$cast'"
if script --help 2>&1 | grep -q -- '--command'; then
  script -q -c "$rec_cmd" /dev/null
else
  script -q /dev/null sh -c "$rec_cmd"
fi

agg \
  --text-font-family "Menlo,JetBrains Mono,DejaVu Sans Mono,Liberation Mono" \
  --font-size 16 \
  --line-height 1.3 \
  --speed 1.0 \
  --theme dracula \
  "$cast" "$gif"

echo "wrote $gif ($(du -h "$gif" | cut -f1))"
