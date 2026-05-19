#!/usr/bin/env bash
# Record the eltainer `e' demo into docs/exec-demo.gif.
#
# Pipeline:
#   1. asciinema rec --command "emacs -nw -Q -l demo-init.el" → .cast
#   2. agg .cast .gif (asciinema's static GIF converter)
#
# Requires: asciinema, agg (`brew install agg`), emacs in a 100x30 TTY.
#
# Re-runnable; overwrites the previous cast/gif.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cast="$here/exec-demo.cast"
gif="$here/exec-demo.gif"

# Make sure the docker sentinel container actually exists.
if ! docker ps --format '{{.Names}}' | grep -qx eltainer-ticker; then
  docker run -d --name eltainer-ticker alpine:3.20 \
    sh -c 'i=0; while true; do echo "tick $i $(date)"; i=$((i+1)); sleep 5; done'
fi

# Make sure the k8s log-streaming pod exists in the kind cluster.
# The demo `l'-pressing scene relies on it producing fresh log lines.
KUBECONFIG=${KUBECONFIG:-$HOME/.kube/configs/config-kind}
export KUBECONFIG
if ! kubectl get pod log-ticker >/dev/null 2>&1; then
  kubectl apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: log-ticker
spec:
  restartPolicy: Always
  containers:
  - name: ticker
    image: busybox:1.37
    command:
    - /bin/sh
    - -c
    - 'i=0; while true; do echo "tick $i $(date)"; i=$((i+1)); sleep 1; done'
YAML
  kubectl wait --for=condition=Ready pod/log-ticker --timeout=60s >/dev/null
fi

rm -f "$cast" "$gif"

# Emacs needs DOCKER_CLI_HINTS off so its child-process callers don't
# spew "What's next" footers; eltainer itself doesn't invoke the CLI
# in this demo, but better to be sure.
export DOCKER_CLI_HINTS=false

# asciinema needs a real TTY for its own stdin or it falls into
# "headless" mode and never allocates a PTY for the child — emacs then
# never gets a terminal to draw into.  `script' fabricates a PTY for us;
# `stty rows … cols …' inside it sets the dimensions (asciinema's own
# --cols/--rows flags only stamp the cast metadata, they don't resize
# the PTY).
#
# BSD `script' (macOS) takes the typescript file as the first
# positional and the command after; util-linux `script' (Linux) takes
# the file last and the command via `-c'.  We detect at runtime.
if script --help 2>&1 | grep -q -- '--command'; then
  # util-linux
  script -q -c "
    stty rows 30 cols 100
    export TERM=xterm-256color
    asciinema rec \
      --overwrite \
      --cols 100 --rows 30 \
      --idle-time-limit 1.5 \
      --command \"TERM=xterm-256color emacs -nw -Q -l '$here/demo-init.el'\" \
      '$cast'
  " /dev/null
else
  # BSD
  script -q /dev/null sh -c "
    stty rows 30 cols 100
    export TERM=xterm-256color
    asciinema rec \
      --overwrite \
      --cols 100 --rows 30 \
      --idle-time-limit 1.5 \
      --command \"TERM=xterm-256color emacs -nw -Q -l '$here/demo-init.el'\" \
      '$cast'
  "
fi

agg \
  --text-font-family "Menlo,JetBrains Mono,DejaVu Sans Mono,Liberation Mono" \
  --font-size 16 \
  --line-height 1.3 \
  --speed 1.0 \
  --theme monokai \
  "$cast" "$gif"

echo "wrote $gif ($(du -h "$gif" | cut -f1))"
