# Migrating taptech-prod (23.227.173.107) into ArgoCD

The live production cluster at **23.227.173.107** ("taptech-prod") runs
real-user workloads across three namespaces (`default`, `taptech`,
`event-agent-system`) and uses a platform stack that predates this
repo's GitOps conventions. Bringing it under ArgoCD management without
downtime — and with rollback via the daily VM snapshots — needs a
staged plan, not a big-bang cutover.

This is that plan.

## Current inventory (snapshot as of first reading)

### Business workloads (must not break)

| Namespace | Workload | Type | Hostnames | Persistent state |
|---|---|---|---|---|
| `default` | `jaiclaw-io-prod` | Deployment (Helm v20) | jaiclaw.io, www.jaiclaw.io | via helm secret |
| `default` | `keycloak-prod` | StatefulSet (Helm v1) | keycloak.taptech.net | `postgresql-data-keycloak-prod-postgresql-0` PVC (20Gi) |
| `default` | `keycloak-prod-postgresql` | StatefulSet | — | above |
| `default` | `taptech-holdings-ui-prod` | Deployment (Helm v6) | holdings.taptech.net | — |
| `default` | `taptech-ai-agent-mcp-calendar-server-prod` | Deployment (Helm v1) | taptech-mcp-calendar.taptech.net | — |
| `default` | `taptech-ai-agent-mcp-client-prod` | Deployment (Helm v6) | mcp-client.taptech.net | — |
| `default` | `taptech-ai-agent-security-oauth-prod` | Deployment (Helm v1) | auth.taptech.net | — |
| `default` | `postgresql` | StatefulSet | — | `data-postgresql-0` PVC (20Gi) |
| `default` | `elasticsearch-master` | StatefulSet (Helm v1) | — | `elasticsearch-master-elasticsearch-master-0` PVC (50Gi) |
| `default` | `redis-master` | StatefulSet (Helm v1) | — | `redis-data-redis-master-0` PVC (5Gi) |
| `default` | `taptech-kafka-broker-0` | Kafka via Strimzi | — | `data-taptech-kafka-broker-0` PVC (50Gi) |
| `default` | `minio` | Deployment (Helm v1) | — | `minio` PVC (50Gi) |
| `taptech` | `flag-football-ui-prod` | Deployment (2 replicas) | flag-football.taptech.net | — |
| `taptech` | `taptech-crm-agent-app` | Deployment | agent-crm.taptech.net | — |
| `taptech` | `taptech-keycloak` | Deployment | id.taptech.net | — |
| `taptech` | `taptech-platform-app` | Deployment (2 replicas) | api-crm.taptech.net | — |
| `taptech` | `taptech-web-clients` | Deployment (2 replicas) | clients.taptech.net, *.clients.taptech.net | — |
| `taptech` | `taptech-web-company` | Deployment (2 replicas) | company.taptech.net | — |
| `taptech` | `taptech-postgres` | StatefulSet | — | `data-taptech-postgres-0` (50Gi) |
| `taptech` | `taptech-redis` | StatefulSet | — | `data-taptech-redis-0` (20Gi) |
| `event-agent-system` | `event-agent` | Deployment | events.taptech.net | — |
| `event-agent-system` | `event-agent-redis-master` | StatefulSet | — | `redis-data-event-agent-redis-master-0` (1Gi) |
| `sentinel-system` | `sentinel` | Deployment | — | — |

**Public hostnames served today (13 in prod):** jaiclaw.io, www.jaiclaw.io, keycloak.taptech.net, holdings.taptech.net, taptech-mcp-calendar.taptech.net, mcp-client.taptech.net, auth.taptech.net, events.taptech.net, 1p.taptech.net, flag-football.taptech.net, agent-crm.taptech.net, id.taptech.net, api-crm.taptech.net, clients.taptech.net (wildcard), company.taptech.net.

**Any of these going dark = incident.**

### Platform stack (already installed, differs from GitOps repo)

| Component | Live | GitOps repo assumes |
|---|---|---|
| cert-manager | Deployed 119d ago (`v1.x`), namespace `cert-manager` | Chart `v1.16.2`, namespace `cert-manager` |
| ingress controller | MicroK8s addon `nginx-ingress-microk8s-controller`, class `public` | Community `ingress-nginx`, class `nginx` |
| Secret provider | `onepassword-connect` (Connect-server model) + Connect operator | `external-secrets` SDK (SDK-token model) |
| StorageClass | `microk8s-hostpath` (from addon) | `taptech-standard` (repo declares this) |
| MetalLB | Installed for LoadBalancer services | Not in mgmt (single public IP), would be needed here |
| MinIO | Deployed in `default` namespace (Helm v1) | Chart in `minio` namespace |

### Everything Helm-installed
30 helm releases across three namespaces. Every business workload is a
Helm release; a `helm upgrade` from CI (or manual) is presumably what
deploys them today.

## Why big-bang is off the table

Un-excluding `argocd/clusters/apps-prod/*` in `root.yaml` today would
try to apply eight `apps-prod-*` Applications simultaneously. Each of
the eight would try to install (or take over) a platform component
that already exists in a different shape. Concretely:

- `apps-prod-cert-manager` would `helm upgrade` cert-manager to the
  repo-pinned version, potentially reissuing all 13 real certs and
  hitting Let's Encrypt's 50-cert-per-week rate limit.
- `apps-prod-ingress-nginx` would install `ingress-nginx` DaemonSet on
  hostPorts 80/443 while `nginx-ingress-microk8s-controller` is still
  bound. One would stay Pending; if the new one wins the race, all 13
  domains stop responding.
- `apps-prod-storage` would create a StorageClass named
  `taptech-standard` marked default. The live cluster has
  `microk8s-hostpath` marked default. Kubernetes allows multiple
  defaults (technically) but PVC provisioning becomes non-deterministic.
- `apps-prod-external-secrets` would install ESO SDK provider.
  ExternalSecrets would fail (no `taptech-prod` 1Password vault token
  loaded). onepassword-connect keeps working; you'd have two secret
  systems both trying to write to the same target Secrets.

## The strategy: adopt in place, converge over time

**Do NOT sync `apps-prod-*` Applications to this cluster.** Instead:

1. **Register the cluster** with ArgoCD (safe, no changes to workloads).
2. **Fork platform component manifests** into a new profile
   (`apps-prod-live/`) that matches what's actually deployed, and adopt
   each Helm release one at a time.
3. **Adopt business workloads** by creating ArgoCD Applications that
   point at the existing Helm charts + values, taking over ownership
   without redeploying.
4. **Migrate secrets architecture** from onepassword-connect to ESO
   only after all business workloads are green under ArgoCD.
5. **Retire old platform components** (MicroK8s ingress addon, connect
   server) at the end, once the git-managed versions are proven.

Each phase is committable, testable, and reversible via VM snapshot.

## Phase 0 — Preparation (no cluster changes)

**Goal:** everything needed to work safely, done off the box.

1. **Confirm daily snapshot cadence and retention.** Verify the last 7
   days of snapshots exist on the VM host / provider.
2. **Take a fresh snapshot immediately before Phase 1.**
3. **Freeze non-critical deploys on taptech-prod.** No `helm upgrade`
   for the duration of migration; changes are traceable only if the
   live state doesn't drift under us.
4. **Document the current git commits / image tags for every business
   workload.** For each Helm release:
   ```bash
   for release in $(kubectl --context taptech-prod get secret -A -l owner=helm \
     --no-headers | awk '{print $1"/"$2}' | sed 's|sh.helm.release.v1.||;s|\.v[0-9]*$||' | sort -u); do
     ns="${release%%/*}"; name="${release##*/}"
     kubectl --context taptech-prod -n "$ns" get secret -l owner=helm,name="$name" \
       --sort-by=.metadata.creationTimestamp -o name | tail -1
   done
   ```
   Save the output. This is your rollback state.
5. **Register the cluster with mgmt ArgoCD:**
   ```bash
   argocd login argocd.taptech.net --insecure  # or via port-forward
   argocd cluster add taptech-prod --name apps-prod --upsert
   # Verify:
   argocd cluster list | grep apps-prod
   ```
   This creates a `ServiceAccount argocd-manager` in `kube-system` and
   an ArgoCD-managed Secret in mgmt. No workload changes.

## Phase 1 — Non-invasive observability

**Goal:** be able to see everything from mgmt without touching it.

1. **Create ArgoCD Applications in `sync-policy: none` mode** for each
   existing Helm release. These reference the SAME chart + values that
   are already deployed, so ArgoCD sees them as `Synced` with no
   changes needed. If it says `OutOfSync` for anything, that's a
   drift to investigate, not to sync.
2. Put these in a new git dir `argocd/clusters/apps-prod-live/` (NOT
   the existing `apps-prod/`) so they don't collide with the
   platform-conformant manifests already there.
3. Root Application excludes `apps-prod-live/*` initially. Nudge one
   Application at a time via `argocd app get <name>` from the CLI.

Example for the first one:

```yaml
# argocd/clusters/apps-prod-live/keycloak-prod.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps-prod-keycloak-prod
  namespace: argocd
spec:
  project: applications
  destination:
    name: apps-prod       # the registered cluster name
    namespace: default    # keycloak-prod lives here today
  source:
    repoURL: 'oci://registry-1.docker.io/bitnamicharts'  # or wherever the chart came from
    chart: keycloak
    targetRevision: <version currently deployed>
    helm:
      releaseName: keycloak-prod
      values: |
        # EXACT values currently in use, dumped from `helm get values keycloak-prod`
  syncPolicy: {}          # no automated sync. Manual sync only.
```

**Verification per adopted release:** `argocd app diff apps-prod-keycloak-prod`
returns empty (or only cosmetic drift). If it wants to change anything,
STOP and figure out why before syncing.

## Phase 2 — Adopt platform in place

**Goal:** cert-manager / ingress / secret-provider become
ArgoCD-managed without changing what's running.

Order matters — do one component at a time, verify, then next.

### 2a. cert-manager

Live cert-manager is already at some version. Two paths:

- **Match & adopt:** write an ArgoCD Application at the same chart
  version, same values, same namespace. Sync in manual mode. Verify
  `helm history cert-manager` shows no new revision after sync.
- **Upgrade path:** if the live version is older than
  `platform/cert-manager/values.yaml`'s `v1.16.2`, plan the upgrade as
  a separate change AFTER adoption is complete. cert-manager upgrades
  are usually safe (in-place, no cert reissuance) but read release
  notes.

Rollback: `helm rollback cert-manager` from the previous secret
revision, restore VM snapshot if needed.

### 2b. Ingress controller

**This is the hardest.** The live cluster uses MicroK8s' `nginx-ingress-microk8s-controller` with IngressClass `public`. Every existing `Ingress` references `class: public`. Switching to community `ingress-nginx` with class `nginx` would require rewriting all 15 Ingress objects.

Two options:

- **Adopt the MicroK8s ingress** — write an ArgoCD Application that
  wraps the addon's DaemonSet + services + ClusterRole. Ugly (the
  addon has no Helm chart) but no ingress churn.
- **Replace with community ingress-nginx** — install the community
  chart with `ingressClassResource.name: public` (matching the current
  class name), verify traffic flows, then delete the MicroK8s addon.
  Requires a short (~30s) window where both controllers may fight for
  ports; do it during a low-traffic window with a rollback plan.

Recommendation: **replace**, during a scheduled window, with the class
name matching so no Ingress objects need to change.

### 2c. Secret provider

Current: onepassword-connect (Connect server + operator). Target: ESO
SDK. This is a bigger change than the others because every existing
1Password-backed Secret is written by the operator, and both
controllers writing the same Secret is a bad state.

Suggested sequence:

1. Deploy ESO alongside connect (they don't conflict as long as they
   target different Secret names).
2. Create a `taptech-prod` 1Password vault with a service account
   token, inject the token as `onepassword-token` in `external-secrets`
   namespace.
3. Migrate each ExternalSecret one at a time: switch its source
   annotation from `onepassword.com/*` to
   `secretStoreRef: {kind: ClusterSecretStore, name: onepassword}`,
   verify content matches.
4. After all Secrets migrated, uninstall onepassword-connect.

## Phase 3 — StorageClass rename

The `apps-prod-storage` Application declares `taptech-standard` as the
default StorageClass. Live cluster uses `microk8s-hostpath`.

Path forward: `platform/storage/apps-prod/storageclass.yaml` should be
rewritten to REFERENCE the existing StorageClass, not create a new
one. Either:

- Add `taptech-standard` as an alias / secondary class, OR
- Drop the storage Application on apps-prod entirely, let workloads
  use `microk8s-hostpath` directly. Update service manifests that
  hardcode `taptech-standard` to accept either.

Given the complication, **skip storage from apps-prod-* entirely for
now.** MicroK8s hostpath works; don't fix what isn't broken.

## Phase 4 — Adopt business workloads

**Only after Phase 2 is stable.** For each Helm release listed above:

1. Extract current values: `helm get values -n <ns> <release>`
2. Create an ArgoCD Application pointing at the source chart repo +
   version + values.
3. Manual-sync mode. `argocd app diff` must be clean before enabling
   auto-sync.
4. Enable auto-sync + selfHeal only after the app has been
   manual-synced clean at least twice with no drift.

Timeline: **one workload per day** is a safe cadence. There are ~15
Helm releases in prod; expect three weeks of Phase 4 with a normal
work rhythm.

## Phase 5 — Retire the old

Once every workload is managed by ArgoCD:

- Delete `onepassword-connect` release + namespace.
- Delete MicroK8s ingress addon (`microk8s disable ingress`), then
  verify community ingress-nginx still binds ports.
- Un-exclude `argocd/clusters/apps-prod-live/*` in root.yaml.
- Retire `argocd/clusters/apps-prod/*` (the old platform-conformant
  set) — or repurpose it for a truly fresh apps cluster in the future.

## Rollback strategy

**VM snapshot from the day before is always your escape hatch.** Every
phase is reversible via one snapshot restore. That's 15-90 minutes of
downtime on prod domains, depending on VM provider.

Per-component rollback:

| Change | Rollback |
|---|---|
| `argocd cluster add` | `argocd cluster rm apps-prod` — nothing else touched |
| Adopt Helm release via App | `argocd app delete <name>` (without cascade). Helm release remains, ArgoCD forgets it. |
| Ingress swap | Re-enable MicroK8s addon, `kubectl delete daemonset ingress-nginx-controller` |
| Secret provider swap | Reinstall onepassword-connect. ExternalSecrets stay; connect writes them again. |
| Any complete disaster | Restore VM snapshot |

## Non-negotiables

- **No apps-prod-* Application ever has `syncPolicy.automated`
  enabled during phases 0-4.** Manual sync only until we trust it.
- **Never delete a live ExternalSecret / Ingress / Deployment without
  a snapshot taken within the last 24h.**
- **`argocd app sync --prune` is banned during Phase 4.** A misconfigured
  Application would delete real workloads.
- **DNS records are NOT migrated.** All 13 public hostnames continue
  to resolve to 23.227.173.107 throughout. No DNS churn.
- **Every phase requires an in-writing sign-off from you before I execute.**

## Prep to start Phase 0

You'll need to do these before I can proceed:

1. **Confirm snapshot cadence + last snapshot timestamp.** Reply here or
   in a follow-up.
2. **Freeze deploys** on taptech-prod. Communicate this to anyone else
   who might push.
3. **Decide** whether to adopt the MicroK8s ingress or replace it (Phase 2b).
4. **Create the `taptech-prod` 1Password vault** with a service account
   scoped to it only (Phase 2c). Same shape as the `taptech-mgmt` vault.
5. **Give me the go-ahead for Phase 0 step 5** (cluster register). This
   is the single most reversible step; it's what turns "planning" into
   "actively adopting."

## Estimated timeline

| Phase | Effort | Wall-clock (with normal deploy freeze) |
|---|---|---|
| 0 — Prep + cluster register | 30 min | 1 day (waits on snapshot confirmation) |
| 1 — Observability apps | 4 hrs | 1 day |
| 2 — Platform adoption | 8-16 hrs | 3-7 days (cert-manager, ingress, ESO one at a time) |
| 3 — Storage decision | 30 min doc, no exec | 1 day |
| 4 — Business workloads | 1 hr/workload × 15 = 15 hrs | 3 weeks |
| 5 — Retire old | 2 hrs | 1 day |
| **Total** | ~1 week of actual work | ~5-6 weeks calendar time |

There is no version of this that finishes in one session. Rushing it
is how prod goes down.
