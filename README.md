# openfeature-lab

Self-contained local Kubernetes lab for a per-tenant flagd + OpenFeature GitOps stack. `./run.sh up` brings up a kind cluster with ArgoCD, an in-cluster Gitea acting as the GitOps source, cert-manager, metrics-server, and the OpenFeature Operator. Two fake tenants (`tenant-a`, `tenant-b`) each get their own `FeatureFlag` + `FeatureFlagSource` + `Flagd` CRs reconciled by the operator, plus a Node.js consumer and load generator using `@openfeature/server-sdk` + `@openfeature/flagd-provider`. Edit YAML, `./run.sh sync`, watch ArgoCD reconcile.

The point of the lab is to answer: **for a per-tenant flagd + OpenFeature stack with realistic flag-set sizes, what does it cost and how should it be dimensioned?**

Two synthetic tenants stamp the same chart triple (`feature-flags` + `consumer` + `loader`) with different resolver settings, both loaded with 500 flag definitions. The loader pod fires concurrent evaluations through the SDK; metrics-server feeds CPU/memory; an HPA targets each tenant's flagd Deployment.

## Headline finding

**In-process mode is 15x more CPU-efficient than RPC-without-cache and keeps flagd idle even under saturating load.** With 500 flags loaded and a single loader pod (50 concurrent async workers) saturating its 1-CPU limit:

| Metric | **in-process** (tenant-a) | **rpc + cache:disabled** (tenant-b) |
|---|---|---|
| Throughput per loader pod | **73,900 evals/s** | 4,500 evals/s |
| Loader CPU | 999m (saturated) | 987m (saturated) |
| Loader memory (k8s working-set) | 87 MiB | 43 MiB |
| Loader memory (Node RSS) | 149 MB | 95 MB |
| Loader Node heap (live objects) | 27-45 MB | 16-24 MB |
| p50 eval latency | 0.00 ms (microseconds) | 6.9 ms |
| p99 eval latency | 0.05-0.07 ms | 48-53 ms |
| flagd pod CPU | 1m each (idle) | 488m on one pod, 1m on others |
| flagd pod memory | 23-28 MiB | 23-50 MiB |
| flagd HPA replicas | 2/10 (min — no scale needed) | 4/10 (scaled, 61%/60% target) |
| Consumer pod memory | 25 MiB | 25 MiB |

## What each mode actually does

**`rpc` (default, but with `cache: lru` by default in the SDK)**: every `getBooleanValue(...)` is a gRPC roundtrip to flagd, which evaluates the flag definition against the supplied context server-side. The SDK keeps an LRU cache of eval results client-side, plus a long-lived event stream for cache invalidation. Hot-key access hits the cache (sub-ms); cache misses cost ~5-10 ms round-trip.

**`rpc + cache: disabled`**: same as above but every call hits flagd. This is the no-trust-in-caching extreme. Every eval pays the network roundtrip; flagd CPU scales with eval volume.

**`in-process`**: the SDK opens a gRPC sync stream to flagd's sync service (port 8015). flagd pushes the full flag spec (500 flags in this lab) to the SDK. Every eval runs locally inside the Node.js process as a JSONLogic interpretation against the in-memory spec. flagd is touched only for the initial sync and for push notifications when flags change.

## Memory cost of in-process at 500 flags

Is it safe to ship the full flag spec to every app pod? Breakdown of where the bytes go:

- Node heap (live flag data + gRPC state): 27-45 MB, GC'd back to the lower bound.
- K8s working-set (RSS that actually counts against limits): **87 MiB per pod**.
- Node-reported RSS (includes JIT, shared libs, buffers): 149 MB.
- The flag spec itself is a few tens of KB in memory; most of the footprint is Node.js + gRPC client.
- Memory does not scale meaningfully with flag count in any production-realistic range (10s to 1000s of flags add KB-to-MB, not tens of MB).

Conclusion: safe for typical service pods. A 256 MiB memory limit is comfortable; 128 MiB is tight.

## Dimensioning takeaways

**Pick `in-process` as the default consumer config.** Flagd becomes a control plane (accept sync streams, push flag updates), not a data plane. The HPA on flagd never needs to scale beyond `minReplicas: 2` for HA, regardless of eval volume. Sizing question reduces to "enough sync-stream capacity for N consumer pods" — flagd handles thousands per replica on its current 200m/500m CPU profile.

**With `in-process`, flagd's CPU profile is driven by**:
1. Sync stream count (linear in consumer pod count, but very low per-stream cost).
2. Flag-change push events (rare, batched).
3. Initial sync handshakes (per-consumer-pod, one-time on startup).

**With `rpc + cache: disabled`, flagd's CPU profile is driven by**:
1. Eval volume (linear, every call hits the JSONLogic interpreter on flagd).
2. gRPC HTTP/2 connection routing: each consumer pod pins to one flagd backend (1 long-lived connection per pod). With N consumer pods and M flagd replicas, distribution averages out via random pinning. A single consumer pod won't spread load across all flagd replicas.

**HPA behavior under sustained eval pressure (rpc + cache:disabled, 50 workers, 4.5k eval/s)**: flagd HPA scaled from 2 to 4 replicas once one pod hit ~228% of its CPU request. With more consumer pods (each opening a separate connection), load distributes naturally and HPA scales more evenly.

## True GitOps immediate flag changes

For "edit YAML, see consumers flip within seconds without restarts":

1. **SDK**: `resolverType: in-process`. flagd pushes new spec via the open sync stream the moment its CR-watch fires. Next eval uses the new spec locally. No cache to invalidate.
2. **flagd**: kubernetes sync source (what this lab uses). Informer-driven, sub-second pickup of `FeatureFlag` CR changes.
3. **ArgoCD**: webhook from your Git remote. Default polling (~3 min) is too slow for "immediate"; webhook reduces to seconds. In production: GitHub webhook to `argocd-server`.

End-to-end: `git push` → `~3-5 seconds` → all consumer pods see the new value, no rollout.

## Per-tenant chart configs in this lab

`tenants/tenant-a/loader.yaml` — in-process, port 8015, 500-flag selection:
```yaml
tenant: tenant-a
flagdHost: flagd.tenant-a.svc.cluster.local
flagdPort: 8015
resolverType: in-process
flagCount: 500
```

`tenants/tenant-b/loader.yaml` — rpc with cache off, port 8013:
```yaml
tenant: tenant-b
flagdHost: flagd.tenant-b.svc.cluster.local
resolverType: rpc
cache: disabled
flagCount: 500
```

`tenants/<tenant>/feature-flags.yaml` — `featureFlag.generateCount: 500` adds `bulk-flag-0` … `bulk-flag-499` synthetic boolean flags alongside any explicit flags.

## Reproducing the measurement

```bash
./run.sh up                          # ~5 min cold (kind, ArgoCD, cert-manager, metrics-server, OF Operator, Gitea)
./run.sh stress start tenant-a 1     # in-process, 50 workers
./run.sh stress start tenant-b 1     # rpc+disabled, 50 workers
# wait 75s for warm-up + memory steady-state
./run.sh top                         # CPU/mem snapshot, both tenants
./run.sh hpa                         # watch flagd HPA across tenants
./run.sh logs tenant-a loader        # rate, p50, p99, heap, rss
./run.sh logs tenant-b loader
./run.sh stress stop                 # scale all loaders to 0
```

ArgoCD treats `Deployment.spec/replicas` as user-managed (via `ignoreDifferences` in the ApplicationSet) so `kubectl scale` and the `stress start` helper aren't reverted by selfHeal.

## Quick reference

| URL | Service | Auth |
|---|---|---|
| http://localhost:8080 | ArgoCD | `admin` / `admin` |
| http://localhost:3000 | Gitea  | `lab` / `lab` |
| localhost:8013 | flagd RPC eval (tenant-a, gRPC) | n/a |

| Cmd | What |
|---|---|
| `up` | cluster + installs + port-forwards |
| `down` | tear everything down |
| `sync` | push `manifests/git/` to Gitea; ArgoCD reconciles |
| `logs [tenant] [app]` | tail logs (defaults: `tenant-a`, `consumer`) |
| `stress {start\|stop\|status} [tenant] [replicas]` | scale loader Deployment(s) |
| `top` | CPU/mem snapshot for tenant pods |
| `hpa` | watch HPAs across tenants |
| `forward {start\|stop\|status}` | manage host port-forwards |
| `shell` | bash inside the orchestrator |

Cluster-wide install (handled by `up.sh`): ArgoCD, Gitea, cert-manager (required by OF Operator's webhook serving cert), metrics-server (kind kubelet TLS skipped), OpenFeature Operator (provides `FeatureFlag` / `FeatureFlagSource` / `Flagd` CRDs).
