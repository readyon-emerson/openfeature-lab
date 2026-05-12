#!/usr/bin/env bash
#
# Push /lab/manifests/git into the Gitea repo at lab/lab-manifests so ArgoCD
# reconciles new changes. With --bootstrap, also creates the repo if it
# doesn't exist yet (called by up.sh on first install).
set -euo pipefail
set -o pipefail

LAB_USER="lab"
LAB_PASS="lab"
REPO_NAME="lab-manifests"
PF_PORT=23000

BOOTSTRAP=0
[ "${1:-}" = "--bootstrap" ] && BOOTSTRAP=1

kubectl -n gitea port-forward deploy/gitea "${PF_PORT}:3000" >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  curl -sf "http://localhost:${PF_PORT}/api/v1/version" >/dev/null 2>&1 && break
  sleep 1
done

if [ "${BOOTSTRAP}" = "1" ]; then
  curl -sf -o /dev/null -u "${LAB_USER}:${LAB_PASS}" \
    -X POST "http://localhost:${PF_PORT}/api/v1/user/repos" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${REPO_NAME}\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" \
    || true   # 409 if repo exists; that's fine
fi

WORK="$(mktemp -d)"
git clone -q "http://${LAB_USER}:${LAB_PASS}@localhost:${PF_PORT}/${LAB_USER}/${REPO_NAME}.git" "${WORK}"
find "${WORK}" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
# Only the git/ subtree gets pushed; bootstrap/ stays local to the orchestrator.
cp -R /lab/manifests/git/. "${WORK}/"
git -C "${WORK}" add -A

if git -C "${WORK}" diff --cached --quiet; then
  echo "    no manifest changes."
  exit 0
fi

git -C "${WORK}" \
  -c user.name="${LAB_USER}" \
  -c user.email="${LAB_USER}@local" \
  commit -q -m "lab: sync manifests"
git -C "${WORK}" push -q origin HEAD:main
echo "    pushed to Gitea."
