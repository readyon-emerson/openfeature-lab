# Orchestrator image. Bakes kind, kubectl, helm, argocd, and the docker CLI
# so the host only needs Docker (plus the host kubectl that run.sh uses for
# port-forwards). Kind nodes run as sibling containers via the mounted host
# docker socket.
FROM debian:bookworm-slim

ARG KIND_VERSION=0.31.0
ARG KUBECTL_VERSION=1.36.1
ARG HELM_VERSION=v3.20.2
ARG ARGOCD_VERSION=v3.4.2
ARG DOCKER_CLI_VERSION=29.4.3

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tar jq bash git python3 apache2-utils \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in amd64) DOCKER_ARCH=x86_64 ;; arm64) DOCKER_ARCH=aarch64 ;; esac \
    && curl -fsSL "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
       | tar -xz -C /tmp \
    && mv /tmp/docker/docker /usr/local/bin/ \
    && rm -rf /tmp/docker

RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${ARCH}" \
       -o /usr/local/bin/kind \
    && chmod +x /usr/local/bin/kind

RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
       -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
       | tar -xz -C /tmp \
    && mv "/tmp/linux-${ARCH}/helm" /usr/local/bin/ \
    && rm -rf "/tmp/linux-${ARCH}"

RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}" \
       -o /usr/local/bin/argocd \
    && chmod +x /usr/local/bin/argocd

WORKDIR /lab
COPY scripts/   /lab/scripts/
COPY manifests/ /lab/manifests/
COPY kind/      /lab/kind/
COPY consumer/  /lab/consumer/
COPY loader/    /lab/loader/
RUN chmod +x /lab/scripts/*.sh

ENTRYPOINT ["/bin/bash"]
