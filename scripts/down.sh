#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${CLUSTER:-feature-flags-lab}"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "==> deleting kind cluster '${CLUSTER}'"
  kind delete cluster --name "${CLUSTER}"
else
  echo "==> kind cluster '${CLUSTER}' not present"
fi

rm -f /out/kubeconfig
echo "==> done"
