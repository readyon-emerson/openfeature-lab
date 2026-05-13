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
│   ├── consumer/                  Node.js demo using OpenFeature SDK
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       └── deployment.yaml
│   └── loader/                    Node.js load generator (idle by default)
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           └── deployment.yaml
└── tenants/
    ├── tenant-a/
    │   ├── feature-flags.yaml     flag content
    │   ├── consumer.yaml          flagd Service DNS for the consumer to dial
    │   └── loader.yaml            flagd Service DNS for the loader to dial
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

## Stress test

Each tenant gets a `loader` Deployment alongside its consumer. Idle by default (replicas: 0). Scale up to start hammering flagd:

```bash
./run.sh stress start tenant-a 1    # scale tenant-a loader to 1 replica
./run.sh stress status              # show loader replica counts
./run.sh logs tenant-a loader       # tail throughput (rate, p50, p99)
./run.sh stress stop                # scale all loaders to 0
```

Each loader pod runs `WORKERS` (default 50) concurrent async eval loops against the in-namespace flagd via OpenFeature SDK + flagd provider. The provider runs in in-process mode by default: it gRPC-syncs the flag state once from flagd, then evaluates locally. So per-eval cost is a local lookup (sub-millisecond p99 in this lab), not a network hop. That's the realistic production hot path; flagd's RPC eval API is only exercised on the initial sync and on flag-content changes.

ArgoCD treats `spec/replicas` on Deployments as user-managed (via `ignoreDifferences` in the ApplicationSet), so `kubectl scale` (and the `stress start` helper) won't be reverted by selfHeal.

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
| `logs [tenant] [app]` | tail logs (defaults: `tenant-a`, `consumer`) |
| `stress {start\|stop\|status} [tenant] [replicas]` | scale the loader Deployment(s) up/down |
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
├── loader/                    Node.js OpenFeature SDK load generator source
│   ├── Dockerfile
│   ├── package.json
│   └── index.js
├── scripts/
│   ├── up.sh
│   ├── down.sh
│   └── sync.sh
└── out/                       host-mounted: kubeconfig, port-forward pid/log
```
