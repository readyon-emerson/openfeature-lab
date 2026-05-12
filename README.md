# openfeature-lab

Local Kubernetes lab for a per-tenant flagd + OpenFeature stack managed via GitOps. Host needs only Docker + kubectl. `kind`, `helm`, `argocd`, and `git` are baked into an orchestrator image. ArgoCD reads manifests from an in-cluster Gitea, so the GitOps flow runs without a real GitHub remote.

## Quickstart

```bash
./run.sh up          # ~3 min cold; sets up everything + auto-starts port-forwards
./run.sh sync        # push manifests/ to Gitea; ArgoCD reconciles
./run.sh logs        # tail tenant-a consumer logs (or `./run.sh logs tenant-b`)
./run.sh down        # tear everything down
```

After `up`, two consumer pods (one per fake tenant) log flag evaluations every 5 seconds. Edit `manifests/git/tenants/tenant-a/feature-flags.yaml`, run `./run.sh sync`, and watch the consumer logs flip values within a few seconds of ArgoCD's reconcile.

| URL | Service | Auth |
|---|---|---|
| http://localhost:8080 | ArgoCD | `admin` / `admin` |
| http://localhost:3000 | Gitea  | `lab` / `lab` |
| localhost:8013        | flagd (tenant-a, gRPC) | n/a |

## What's in the cluster

```
manifests/git/                     mirror of what lives in Gitea
├── argo/
│   ├── root.yaml                  App-of-Apps entry point
│   └── tenants-appset.yaml        matrix: tenants x charts -> 2 Apps per tenant
├── charts/
│   ├── feature-flags/             FeatureFlag + FeatureFlagSource + Flagd CRs
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── featureflag.yaml
│   │       ├── featureflagsource.yaml
│   │       └── flagd.yaml         OpenFeature Operator reconciles into a Deployment+Service
│   └── consumer/                  Node.js demo using OpenFeature SDK
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           └── deployment.yaml
└── tenants/
    ├── tenant-a/
    │   ├── feature-flags.yaml     flag content + flagd source URI
    │   └── consumer.yaml          flagd Service DNS for the consumer to dial
    └── tenant-b/                  same shape, different flag content
```

Two charts, two Applications per tenant. Splitting `feature-flags` from `consumer` mirrors a production shape where the flag system is a per-tenant install and consumer services (backend, API, web) are separate charts that wire in `FLAGD_HOST` / `FLAGD_PORT` env vars.

Cluster-wide install (handled by `up.sh`, not via Gitea):

| Component | Why |
|---|---|
| ArgoCD | reconciles the Gitea repo |
| Gitea | self-contained GitOps source |
| cert-manager | required by the OpenFeature Operator chart (webhook serving cert) |
| OpenFeature Operator | provides `FeatureFlag` + `FeatureFlagSource` CRDs |

## Iteration loop

```bash
# edit flag content
vim manifests/git/tenants/tenant-a/feature-flags.yaml
./run.sh sync              # push to Gitea; ArgoCD reconciles
./run.sh logs              # watch the consumer pick up the new value
```

To change the consumer code:

```bash
vim consumer/index.js
./run.sh up                # rebuilds the consumer image, kind-loads it
```

## Subcommands

| Cmd | What |
|---|---|
| `up` | bring up cluster + install everything + start port-forwards |
| `down` | stop port-forwards, destroy cluster |
| `sync` | push current `manifests/git/` to Gitea |
| `logs [tenant]` | tail consumer logs (default `tenant-a`) |
| `forward {start\|stop\|status}` | manage host port-forwards |
| `shell` | drop into a bash inside the orchestrator |

## Env

| Var | Default | What |
|---|---|---|
| `CLUSTER` | `feature-flags-lab` | kind cluster name |
| `SKIP_BUILD` | `0` | set to `1` to skip orchestrator + consumer image rebuilds |
| `KIND_NODE_IMAGE` | (kind default) | pin a specific kindest/node image |
| `FLAGD_IMAGE` | `ghcr.io/open-feature/flagd:latest` | override flagd image tag (pre-pulled and kind-loaded) |

## Layout

```
.
├── Dockerfile                 orchestrator: kind + kubectl + helm + argocd + git
├── run.sh                     host entry, port-forward management
├── kind/cluster.yaml
├── manifests/
│   ├── bootstrap/             applied directly by up.sh, never goes through Gitea
│   │   ├── argocd-values.yaml
│   │   ├── openfeature-operator-values.yaml
│   │   └── gitea.yaml
│   └── git/                   mirror of what lives in Gitea (ArgoCD reads from here)
│       ├── argo/
│       ├── charts/
│       └── tenants/
├── consumer/                  Node.js OpenFeature SDK consumer source
│   ├── Dockerfile
│   ├── package.json
│   └── index.js
├── scripts/
│   ├── up.sh
│   ├── down.sh
│   └── sync.sh
└── out/                       host-mounted: kubeconfig, port-forward pid/log
```
