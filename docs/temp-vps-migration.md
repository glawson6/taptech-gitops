# Temp-VPS bridge migration: refactor prod without user-visible downtime

An alternative to the in-place adoption plan in
[`apps-prod-migration.md`](apps-prod-migration.md). Faster (~5-7 days vs
~5-6 weeks), same end state, requires renting a throwaway VPS.

## The idea

1. Rent a fresh VPS in the same region as the live production box
   (`23.227.173.107`).
2. Install MicroK8s on it. That's the *only* thing installed fresh.
3. Clone the entire running Kubernetes cluster from prod to the new
   VPS: every Namespace, CRD, Secret, ConfigMap, Ingress, workload
   spec (three scripts do the work).
4. rsync all PVC data from prod to the new VPS.
5. Flip DNS: users now on the temp VPS.
6. Wipe the original box. Reinstall MicroK8s cleanly. Register with
   mgmt ArgoCD as the proper `apps-prod` cluster.
7. Migrate everything back from temp to the rebuilt box. Flip DNS
   again.
8. Destroy the temp VPS.

**End state:** original IP `23.227.173.107` runs a proper `apps-prod`
cluster registered with mgmt ArgoCD, all workloads adopted into
`applications/<name>/overlays/prod/` Kustomize overlays. Temp VPS is
gone. Users saw at most a ~5 min DNS TTL cutover per migration.

## The three scripts

| Script | Purpose |
|---|---|
| [`scripts/temp-vps-init.sh`](../scripts/temp-vps-init.sh) | Installs MicroK8s + core addons on the temp box; sets up original→temp SSH for rsync; extracts kubeconfig. |
| [`scripts/clone-k8s-objects.sh`](../scripts/clone-k8s-objects.sh) | Copies Kubernetes objects (Namespaces, CRDs, Secrets, ConfigMaps, workloads at replicas: 0, etc.) from src cluster to dest. Defaults to `--dry-run`. |
| [`scripts/rsync-pvc.sh`](../scripts/rsync-pvc.sh) | Per-PVC data migration between hosts. Scales src workload to 0, rsyncs hostpath dir, fixes ownership. Requires human confirmation before scale-down. |

All three take positional arguments (mostly IPs / context names) and
require passwordless SSH between the boxes. `temp-vps-init.sh` sets that
up as part of its work.

## Timeline

```
      t=0             t=1                t=2                  t=3                  t=4
   (today)      (temp cloned,        (old wiped +          (apps back on         (temp gone,
                 DNS -> temp)        rebuilt as apps-prod  rebuilt original;      migration done)
                                     per gitops)           DNS -> original)

  original      original: idle       original: WIPED       original: apps-prod    apps-prod:
   live         (rollback safety)    -> reinstall clean    (mgmt-managed)          stable
              temp: live prod       temp: live prod       temp: idle             (temp: destroyed)
```

The mgmt cluster at `104.225.223.215` is untouched throughout. It gains
one registered spoke in Phase 4.

## Execution model: who does what

| Action | Who |
|---|---|
| Provision the VPS + inject workstation pubkey | You |
| DNS records (TTL drop, cutover) | You |
| Approve go/no-go on scale-down of a live workload | You (per-workload) |
| SSH to boxes, install snap, enable addons | `temp-vps-init.sh` |
| `kubectl get -o yaml` from src, sanitize, dry-run apply to dest | `clone-k8s-objects.sh --dry-run` (default) |
| Live apply of cloned objects | `clone-k8s-objects.sh --live`, after your review |
| rsync of a PVC's contents | `rsync-pvc.sh` (prompts for confirmation) |
| Wipe original box + reinstall (Phase 4) | You, using `scripts/prep-microk8s.sh` |
| Write Kustomize overlays for each business workload | Manual per workload |
| Register apps-prod with mgmt ArgoCD | `argocd cluster add` after 1P vault exists |
| Create 1Password vault `taptech-prod` + service-account token | You |
| Destroy temp VPS at end | You |

Every script defaults to a safe mode. Nothing destroys or moves live
data without an explicit flag or interactive confirmation.

## Approach

### Phase 0 — Prep (workstation-only; no live changes)

1. **Snapshot** the original box. Confirm daily snapshot cadence and
   retention with your VPS provider.
2. **Freeze deploys** on `23.227.173.107` — no `helm upgrade` from
   anyone until Phase 4 completes. Drift under active migration is
   unrecoverable.
3. **Inventory the original** so the temp box matches:
   ```bash
   ssh tap@23.227.173.107 'uname -m && microk8s version && lsb_release -a'
   ```
   Save output. Confirm arch (must match) and MicroK8s channel (temp
   must install same channel).
4. **DNS TTL drop**: all 13 hostnames → 60s TTL. Do this at least
   24 hours before Phase 3 cutover.
5. **Provision temp VPS**: same arch, same region as original,
   >= 8 cores / 32 GB RAM / 500 GB disk. Inject your workstation
   pubkey at provision time so `ssh tap@<temp-ip>` works out of the box.

### Phase 1 — Clone the cluster to temp VPS

1. Install MicroK8s + addons + SSH-key setup on temp:
   ```bash
   ./scripts/temp-vps-init.sh <temp-ip> --channel 1.31/stable
   ```
   Add `--metallb <range>` if the original uses MetalLB; add
   `--original tap@<original-ip>` if not `tap@23.227.173.107`.

2. Merge the emitted kubeconfig into your local `~/.kube/config` as
   context `taptech-prod-temp`. The script prints the exact commands
   to run.

3. Dry-run the clone to inspect every manifest:
   ```bash
   ./scripts/clone-k8s-objects.sh taptech-prod taptech-prod-temp
   # Look at /tmp/clone-YYYYMMDD-HHMMSS/ manifests.
   # Watch for hardcoded IPs in ConfigMaps, service-account tokens that
   # were skipped, anything referencing the old node hostname.
   ```

4. When happy, apply live:
   ```bash
   ./scripts/clone-k8s-objects.sh taptech-prod taptech-prod-temp --live
   ```
   Temp cluster now has every Namespace, CRD, Secret, ConfigMap, and
   workload spec from the original. **All workloads are at replicas:
   0** — no pods running yet.

5. Verify shape parity:
   ```bash
   kubectl --context taptech-prod      get all -A --no-headers | wc -l
   kubectl --context taptech-prod-temp get all -A --no-headers | wc -l
   ```
   Counts should be within ~5% of each other (the diff is workloads
   at replicas: 0 on temp not creating ReplicaSets/Pods).

### Phase 2 — Migrate data and bring workloads up on temp

Per stateful workload, in order (least-critical first so early failures
don't cascade):

| # | Workload | Method |
|---|---|---|
| 1 | Redis (3 instances) | Accept cache loss; scale to 1 on temp with empty data. OR `rsync-pvc.sh` if you must preserve. |
| 2 | MinIO (default namespace, 50Gi) | `./scripts/rsync-pvc.sh taptech-prod default minio <temp-ip>` |
| 3 | Kafka (50Gi) | `./scripts/rsync-pvc.sh taptech-prod default taptech-kafka-broker <temp-ip>` |
| 4 | Elasticsearch (50Gi) | `./scripts/rsync-pvc.sh taptech-prod default elasticsearch-master <temp-ip>` |
| 5 | Postgres × 3 (20Gi each) | **NOT rsync.** For each: `kubectl exec` into src pod, `pg_dumpall > /tmp/dump.sql`, `kubectl cp` to workstation, `kubectl cp` to dest pod (scaled up first with empty PVC), `psql < /tmp/dump.sql`. Postgres data dir is off-limits to file-level copy — safety over speed. |
| 6 | Application-tier Deployments | `kubectl --context taptech-prod-temp scale deploy -n <ns> <name> --replicas=<orig>` per workload. Bring up in dependency order (databases first). |

After each: **smoke-test via `curl --resolve <host>:443:<temp-ip>
https://<host>/`** from your workstation. All 13 hostnames should
return 2xx before Phase 3.

`rsync-pvc.sh` prompts before scaling a src workload down — say "yes"
once you're sure the window is right. It does NOT scale the dest
workload up; that's a per-workload decision you make after verifying
the data landed.

### Phase 3 — DNS cutover to temp

1. Final data sync for any stateful workloads that changed since Phase 2
   (usually only Postgres if apps have been serving reads from original;
   re-dump + restore).
2. Update DNS A records: all 13 hostnames → temp VPS IP.
3. Monitor both boxes' ingress logs during the cutover window. Old box
   drains within ~5 min (TTL 60s from Phase 0).
4. Soak for 30 min. Users are on temp.

**Rollback at Phase 3:** flip DNS records back to original. Original
has been idle but preserved. Recovery time: ~5 min.

### Phase 4 — Wipe + rebuild original as GitOps `apps-prod`

1. Take a final snapshot of original as belt-and-suspenders.
2. Nuke the old install:
   ```bash
   ssh tap@23.227.173.107 'sudo snap remove microk8s --purge'
   ```
3. Reinstall using this repo's GitOps flow (NOT the temp-clone flow —
   the whole point of the rebuild is to land the proper platform):
   ```bash
   ssh tap@23.227.173.107 'sudo snap install microk8s --classic --channel=1.31/stable'
   ssh tap@23.227.173.107 'bash -s' < scripts/prep-microk8s.sh
   ```
   `prep-microk8s.sh` (unlike `temp-vps-init.sh`) DISABLES the MicroK8s
   ingress addon because the git-managed community `ingress-nginx` will
   own ports 80/443 instead.
4. Fetch the fresh kubeconfig:
   ```bash
   ./scripts/fetch-kubeconfigs.sh prod
   ```
5. Register with mgmt ArgoCD:
   ```bash
   argocd login argocd.taptech.net
   argocd cluster add taptech-prod --name apps-prod --upsert
   ```
6. Create the `taptech-prod` 1Password vault (if it doesn't exist) with a
   read-only service-account token scoped to it, then inject:
   ```bash
   kubectl --context taptech-prod create namespace external-secrets
   kubectl --context taptech-prod -n external-secrets create secret generic \
     onepassword-token --from-literal=token='ops_...'
   ```
7. **Un-exclude `clusters/apps-prod/*` and `appsets/*` in
   `argocd/bootstrap/root.yaml`.** Commit + push. ArgoCD picks up the
   platform stack (cert-manager v1.16.2, community ingress-nginx, ESO,
   monitoring, etc.). Reconciles in ~15 min.
8. **Write Kustomize overlays** for each business workload under
   `applications/<name>/overlays/prod/`. Source the current shape from
   `helm get manifest -n <ns> <release>` on the temp cluster (where
   the Helm releases are still live). Largest chunk of Phase 4 —
   ~15 workloads.
9. Verify each `apps-prod-<workload>` Application reaches Synced/Healthy
   with NO real user traffic (still on temp).

### Phase 5 — Cutover back and destroy temp

1. Data sync temp → original per workload (reverse of Phase 2):
   ```bash
   ./scripts/rsync-pvc.sh taptech-prod-temp <ns> <workload> 23.227.173.107
   ```
   Postgres via `pg_dumpall` / `psql` as before.
2. Application smoke tests: `curl --resolve <host>:443:23.227.173.107`.
3. DNS cutover back: all 13 hostnames → `23.227.173.107`.
4. 24-hour soak. If clean, destroy temp VPS.
5. Add apps-prod's Prometheus as a Grafana datasource on mgmt:
   `platform/monitoring/clusters/mgmt.yaml` `additionalDataSources`.

## Application overlays (Phase 4 step 8)

For each of the ~15 business workloads, create:

```
applications/<name>/
  base/
    kustomization.yaml
    deployment.yaml
    service.yaml
    ingress.yaml
    (any ConfigMaps, ExternalSecrets)
  overlays/prod/
    kustomization.yaml    # bases: ../../base; namespace: <target>; images: ...
    patch-env.yaml
    patch-resources.yaml
```

The `kustomize.images` block enables Jenkins to bump image tags with
`kustomize edit set image` (see `docs/jenkins-integration.md`).

`argocd/appsets/applications.yaml` (matrix generator) discovers each
new overlay directory once Phase 4 step 7 un-excludes it.

## Rollback strategy

Every phase is reversible.

| Phase | Rollback | Recovery time |
|---|---|---|
| 0 (prep) | Revert TTL to original | Immediate |
| 1 (init + clone) | Destroy temp VPS | Immediate |
| 2 (data migration) | Destroy temp VPS | Immediate |
| 3 (DNS to temp) | DNS records → original | ~5 min (TTL drain) |
| 4 (rebuild original) | Restore from snapshot | 15-90 min (provider) |
| 5 (DNS back) | DNS → temp; investigate; retry | ~5 min |

Never delete the temp VPS until Phase 5 has soaked cleanly for at least
24 hours.

## SSH-key relationships

Two need to be set up:

1. **Workstation → temp VPS** — installed by you at VPS provision
   (most providers offer this in their web UI). Prereq for
   `temp-vps-init.sh`.
2. **Original box → temp VPS** — installed BY `temp-vps-init.sh`
   (generates a keypair on the original if none exists, appends the
   pubkey to temp's `authorized_keys`, verifies passwordless SSH).
   Prereq for `rsync-pvc.sh`.

`rsync-pvc.sh` fails fast if #2 doesn't work rather than silently
falling back to a password prompt in the middle of a data copy.

## Verification

- **Phase 1**: `microk8s status --wait-ready` on temp shows addons
  enabled. `kubectl --context taptech-prod-temp get ns` list matches
  the original.
- **Phase 2**: for each host, `curl --resolve <host>:443:<temp-ip>
  https://<host>/` returns 2xx served by temp (verify via a
  distinguishing response header or pod IP).
- **Phase 3**: `dig +short <host>` from multiple resolvers returns
  temp IP. Original's ingress access log rate → 0; temp's rises.
- **Phase 4**: `kubectl --context taptech-prod get nodes` shows fresh
  MicroK8s Ready. `argocd app list | grep apps-prod-` shows platform
  Applications Synced/Healthy. Every business workload has a
  corresponding `applications/*/overlays/prod/` and matching
  `apps-prod-<name>` ArgoCD Application.
- **Phase 5**: `dig +short` returns original IP. `curl` returns 2xx
  from a real browser AND via `--resolve` against `23.227.173.107`.
  All ArgoCD `apps-prod-*` Applications Synced/Healthy.
- **End-to-end**: Grafana on mgmt shows metrics from both mgmt and
  apps-prod. Jenkins pipeline that commits an image-tag bump results
  in ArgoCD deploying to apps-prod.

## Estimated timeline

| Phase | Wall-clock | Notes |
|---|---|---|
| 0 — Prep | 1 day | TTL propagation |
| 1 — Init + clone objects | 2-4 hours | scripted |
| 2 — Data migration + bring-up | 1 day | rsync + per-Postgres pg_dump; parallelizable across DBs |
| 3 — Cutover to temp | 1 hour scheduled + 24h soak | |
| 4 — Rebuild original + overlays | 2-3 days | Kustomize overlay authoring is the big time-sink |
| 5 — Cutover back + destroy temp | 1 hour + 24h soak | |
| **Total** | **~5-7 days calendar time** | Materially faster than the in-place approach in [`apps-prod-migration.md`](apps-prod-migration.md) |

## Out of scope

- **Secrets architecture migration** (onepassword-connect → ESO SDK):
  connect stays through Phase 5 for continuity. Separate future work.
- **Monitoring history**: Prometheus TSDB on original is lost during
  rebuild (Phase 4). New Prometheus starts fresh. If long-term metrics
  matter, add the `prometheus-server` PVC to Phase 5's data
  migrate-back list.
- **Kafka message continuity**: consumers restart from committed
  offsets and accept whatever gap the migration creates. MirrorMaker2
  would be needed for zero-gap semantics; not planned here.
- **Choice of VPS provider**: you pick. Same region as original
  strongly recommended for rsync speed and low latency.

## Related docs

- [`docs/apps-prod-migration.md`](apps-prod-migration.md) — the
  alternative in-place adoption plan. Longer but no VPS rental.
- [`docs/architecture.md`](architecture.md) — the mgmt-cluster
  ArgoCD tier diagram.
- [`docs/adding-a-cluster.md`](adding-a-cluster.md) — the reference
  pattern for adding a fresh apps cluster (which is what Phase 4
  produces).
- [`docs/secrets.md`](secrets.md) — 1Password + ESO wiring you'll
  need for Phase 4 step 6.
