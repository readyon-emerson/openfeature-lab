#!/usr/bin/env bash
#
# Brings up the lab end-to-end. Called by host run.sh inside the orchestrator.
#   1. pre-pull externals
#   2. build consumer image
#   3. create kind cluster
#   4. load images (via tar archive to dodge Docker Desktop snapshotter quirk)
#   5. install ArgoCD
#   6. install OpenFeature Operator (CRDs + webhook, webhook stays inert)
#   7. install Gitea, seed admin user + repo, push manifests via sync.sh
#   8. apply ArgoCD root Application (ApplicationSet stamps out per-tenant Apps)
set -euo pipefail
set -o pipefail

CLUSTER="${CLUSTER:-feature-flags-lab}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
FLAGD_IMAGE="${FLAGD_IMAGE:-ghcr.io/open-feature/flagd:latest}"

load_image_to_kind() {
  local img="$1"
  local archive
  archive="$(mktemp /tmp/img-XXXXXX.tar)"
  docker save "${img}" -o "${archive}" >/dev/null
  # docker save on Docker Desktop emits a manifest list referencing both
  # amd64 + arm64 manifests, but ships only the local platform's layers.
  # kind load image-archive then trips on the foreign-platform digest.
  # Strip foreign-arch manifests before loading.
  python3 /lab/scripts/_strip_foreign_arch.py "${archive}"
  kind load image-archive --name "${CLUSTER}" "${archive}"
  rm -f "${archive}"
}

echo "==> pre-pulling external images on host daemon"
docker pull -q "${FLAGD_IMAGE}" >/dev/null &
wait
echo "    done"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "==> building consumer image from /lab/consumer"
  docker build -q -t feature-flags-consumer:dev /lab/consumer >/dev/null
  echo "==> building loader image from /lab/loader"
  docker build -q -t feature-flags-loader:dev /lab/loader >/dev/null
fi

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "==> creating kind cluster '${CLUSTER}'"
  if [ -n "${KIND_NODE_IMAGE}" ]; then
    kind create cluster --name "${CLUSTER}" --config /lab/kind/cluster.yaml --image "${KIND_NODE_IMAGE}" --wait 90s
  else
    kind create cluster --name "${CLUSTER}" --config /lab/kind/cluster.yaml --wait 90s
  fi
else
  echo "==> kind cluster '${CLUSTER}' already exists"
fi

kind get kubeconfig --name "${CLUSTER}" > /out/kubeconfig
chmod 600 /out/kubeconfig
echo "==> kubeconfig written to ./out/kubeconfig"

echo "==> loading images into kind (via tar archive)"
for img in feature-flags-consumer:dev feature-flags-loader:dev "${FLAGD_IMAGE}"; do
  echo "    ${img}"
  load_image_to_kind "${img}"
done

echo "==> installing argo-cd (admin password hardcoded to 'admin')"
ARGOCD_ADMIN_HASH=$(htpasswd -bnBC 10 "" admin | tr -d ':\n' | sed 's/^\$2y/\$2a/')
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --version 9.5.13 \
  --values /lab/manifests/bootstrap/argocd-values.yaml \
  --set "configs.secret.argocdServerAdminPassword=${ARGOCD_ADMIN_HASH}" \
  --set "configs.secret.argocdServerAdminPasswordMtime=2026-01-01T00:00:00Z" \
  --wait --timeout 5m

echo "==> installing metrics-server (kubelet TLS skipped: kind's kubelet certs aren't signed by the metrics-server-trusted CA)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname}' \
  --wait --timeout 3m

echo "==> installing cert-manager (OpenFeature Operator chart unconditionally renders cert-manager Certificate + Issuer for its webhook serving cert)"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  --set crds.enabled=true \
  --wait --timeout 5m

echo "==> installing OpenFeature Operator (FeatureFlag + FeatureFlagSource CRDs)"
helm repo add openfeature https://open-feature.github.io/open-feature-operator >/dev/null 2>&1 || true
helm repo update openfeature >/dev/null
helm upgrade --install open-feature-operator openfeature/open-feature-operator \
  --namespace open-feature-operator-system --create-namespace \
  --values /lab/manifests/bootstrap/openfeature-operator-values.yaml \
  --wait --timeout 3m

echo "==> installing Gitea"
kubectl apply -f /lab/manifests/bootstrap/gitea.yaml
kubectl -n gitea rollout status deploy/gitea --timeout=3m

echo "==> creating Gitea admin user 'lab' (idempotent)"
# kubectl exec enters as root; gitea binary refuses to run as root, so drop
# to the `git` user.
kubectl -n gitea exec deploy/gitea -- su git -c \
  "gitea admin user create --username lab --password lab --email lab@local --admin --must-change-password=false" \
  2>&1 | grep -v "user already exists" || true

echo "==> pushing manifests to Gitea (creates repo if needed)"
/lab/scripts/sync.sh --bootstrap

echo "==> applying ArgoCD root Application"
kubectl apply -f /lab/manifests/git/argo/root.yaml

echo "==> waiting for tenant-a flagd Service to appear (best-effort, up to 90s)"
kubectl wait --for=create --timeout=90s -n tenant-a svc/flagd 2>/dev/null \
  || echo "    not yet present; ArgoCD is still reconciling. Re-run './run.sh forward start' once it's up."

echo "==> lab is up (in-cluster)."
