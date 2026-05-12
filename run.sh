#!/usr/bin/env bash
#
# Host entry. Builds the orchestrator image (Docker layer-cached), runs the
# requested subcommand inside it, and manages host-side port-forwards so the
# UIs stay reachable from your browser after the orchestrator exits.
#
# Subcommands:
#   up        bring up cluster, install everything, start ArgoCD + Gitea forwards
#   down      stop forwards, destroy cluster
#   sync      push current manifests/ to Gitea (ArgoCD will reconcile)
#   logs      tail consumer logs for a tenant (default tenant-a)
#   forward   {start|stop|status} - manage port-forwards explicitly
#   shell     drop into a bash inside the orchestrator (talking to the kind cluster)
#
# Env:
#   CLUSTER      kind cluster name (default: feature-flags-lab)
#   SKIP_BUILD   set to 1 to skip orchestrator + consumer image rebuilds
set -euo pipefail
set -o pipefail

cd "$(dirname "$0")"

CLUSTER="${CLUSTER:-feature-flags-lab}"
KUBECONFIG_FILE="$(pwd)/out/kubeconfig"

# Format: "name|namespace|target|local:remote". macOS bash 3.2 doesn't have
# associative arrays, so parallel-encoded as a regular array.
# flagd Services are ArgoCD-managed and async; forward_start skips them
# silently if not present yet.
FORWARDS=(
  "argocd|argocd|svc/argocd-server|8080:443"
  "gitea|gitea|svc/gitea-http|3000:3000"
  "flagd-tenant-a|tenant-a|svc/flagd|8013:8013"
)

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is required and must be running." >&2
  exit 1
fi

mkdir -p out out/forwards

# --- helpers --------------------------------------------------------------

build_orchestrator() {
  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "==> building orchestrator (cached on subsequent runs)"
    docker build -q -t feature-flags-lab:local . >/dev/null
  fi
}

docker_sock() {
  local s="${DOCKER_HOST:-}"
  if [ -z "$s" ]; then
    for c in /var/run/docker.sock "$HOME/.docker/run/docker.sock" "$HOME/.colima/default/docker.sock"; do
      [ -S "$c" ] && s="unix://$c" && break
    done
  fi
  [ -z "$s" ] && s="unix:///var/run/docker.sock"
  echo "${s#unix://}"
}

run_in_orchestrator() {
  # $@ = command to exec inside the container
  local sock; sock="$(docker_sock)"
  local tty=""
  [ -t 0 ] && [ -t 1 ] && tty="-it"
  exec docker run --rm $tty \
    -v "${sock}:/var/run/docker.sock" \
    -v "$(pwd)/out:/out" \
    --network host \
    -e CLUSTER="${CLUSTER}" \
    -e SKIP_BUILD="${SKIP_BUILD:-0}" \
    -e KUBECONFIG=/out/kubeconfig \
    feature-flags-lab:local "$@"
}

forward_start() {
  if [ ! -f "${KUBECONFIG_FILE}" ]; then
    echo "    (kubeconfig missing; skipping port-forwards)"
    return
  fi
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r name ns target ports <<<"${entry}"
    local pid_file="out/forwards/${name}.pid"
    if [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
      echo "    ${name}: already running (PID $(cat "${pid_file}"))"
      continue
    fi
    if ! kubectl --kubeconfig "${KUBECONFIG_FILE}" -n "${ns}" get "${target}" >/dev/null 2>&1; then
      echo "    ${name}: skipped (${target} not present in ns ${ns} yet)"
      continue
    fi
    nohup kubectl --kubeconfig "${KUBECONFIG_FILE}" -n "${ns}" \
      port-forward "${target}" "${ports}" \
      >"out/forwards/${name}.log" 2>&1 &
    echo $! > "${pid_file}"
    disown 2>/dev/null || true
    echo "    ${name}: started (PID $(cat "${pid_file}"), localhost:${ports%%:*})"
  done
}

forward_stop() {
  for f in out/forwards/*.pid; do
    [ -f "$f" ] || continue
    local name; name="$(basename "$f" .pid)"
    local pid; pid="$(cat "$f")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo "    ${name}: stopped (PID $pid)"
    fi
    rm -f "$f"
  done
}

forward_status() {
  if [ ! -d out/forwards ]; then
    echo "no forwards"
    return
  fi
  for f in out/forwards/*.pid; do
    [ -f "$f" ] || continue
    local name; name="$(basename "$f" .pid)"
    local pid; pid="$(cat "$f")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "    ${name}: running (PID $pid)"
    else
      echo "    ${name}: stale pid file"
    fi
  done
}

# --- subcommands ----------------------------------------------------------

cmd="${1:-up}"
shift || true

case "$cmd" in
  up)
    build_orchestrator
    docker run --rm \
      -v "$(docker_sock):/var/run/docker.sock" \
      -v "$(pwd)/out:/out" \
      --network host \
      -e CLUSTER="${CLUSTER}" \
      -e SKIP_BUILD="${SKIP_BUILD:-0}" \
      -e KUBECONFIG=/out/kubeconfig \
      feature-flags-lab:local /lab/scripts/up.sh
    echo "==> starting host port-forwards"
    forward_start
    cat <<EOF

==> lab is up.

UIs (already forwarded):
  ArgoCD:    http://localhost:8080       (user: admin, pass: admin)
  Gitea:     http://localhost:3000       (user: lab,   pass: lab)
  flagd-a:   localhost:8013              (gRPC; poke with grpcurl if you want)

Iterate:
  ./run.sh sync                          # push manifests/ to Gitea; ArgoCD reconciles
  ./run.sh logs                          # tail tenant-a consumer logs
  ./run.sh logs tenant-b                 # tail tenant-b consumer logs
  ./run.sh down                          # tear everything down

Forwards:
  ./run.sh forward status | stop | start
EOF
    ;;
  down)
    forward_stop
    build_orchestrator
    run_in_orchestrator /lab/scripts/down.sh
    ;;
  sync)
    build_orchestrator
    run_in_orchestrator /lab/scripts/sync.sh
    ;;
  logs)
    tenant="${1:-tenant-a}"
    exec kubectl --kubeconfig "${KUBECONFIG_FILE}" -n "${tenant}" \
      logs -l app=consumer --tail=200 -f
    ;;
  forward)
    sub="${1:-start}"
    case "$sub" in
      start)  forward_start ;;
      stop)   forward_stop ;;
      status) forward_status ;;
      *) echo "Usage: ./run.sh forward {start|stop|status}" >&2; exit 1 ;;
    esac
    ;;
  shell)
    run_in_orchestrator
    ;;
  *)
    echo "Usage: ./run.sh {up|down|sync|logs [tenant]|forward|shell}" >&2
    exit 1
    ;;
esac
