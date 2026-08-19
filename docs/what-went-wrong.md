# What went wrong: mgmt-cluster bootstrap postmortem

A ~12-hour session brought up the management cluster on
`104.225.223.215`. What should have been a 30-minute bootstrap took a day
because eleven separate defects, spanning gitignore rules, sync-wave
directions, chart pins, snap addons, and 1Password field naming, all
sat quietly in git waiting for the first live bootstrap to trip them.

This document exists so nobody has to rediscover them one at a time. Each
section is: **what broke**, **how it presented**, **the fix (with the
commit hash if applicable)**, and **best practice going forward**.

## Timeline snapshot

| Hour | State |
|---|---|
| 0 | Kubelet up, ArgoCD installed via `bootstrap.sh`, root Application applied. |
| 0–2 | Repo URL still placeholder → `authentication required` on every child sync. |
| 2–4 | Repo URL fixed + PAT registered; four Applications never appeared. |
| 4–7 | Debugged one wedged sync-wave / phantom-hook at a time. |
| 7–10 | Kubelite thrashed at 170% CPU from all the surgery. Rebooted, then reboot. |
| 10–11 | Escalated to full MicroK8s reinstall + fresh bootstrap. |
| 11–12 | All 12 mgmt-* Applications Healthy. |

## The eleven defects

Each one was independent. Each would have blocked a bootstrap on any new
cluster.

### 1. `.gitignore` swallowed `secret-stores.yaml`

**Broke:** `.gitignore` had `secret-*.yaml` (meant to exclude K8s Secret
manifests holding credentials). It also matched
`argocd/clusters/{mgmt,apps-prod}/secret-stores.yaml`, which are ArgoCD
`Application` manifests wiring the ESO `ClusterSecretStore`. They contain
no material.

**Presented as:** `mgmt-secret-stores`, `mgmt-minio`, `mgmt-jenkins`,
`mgmt-monitoring` — four Applications — never appeared. Root synced
"11 resources" but `kubectl get applications` showed fewer. `git status`
showed the files as untracked; `git check-ignore -v` explained why.

**Fix (commit `f7c55f5`):** Added a negation to `.gitignore`:

```
secret-*.yaml
!*sealed*.yaml
!secret-stores.yaml
```

**Best practice:**

- **Never commit a repo where `git status --ignored` hides files that
  should be tracked.** Add `git status --ignored --short | grep <path>`
  to any bootstrap doc's "verify" section.
- **`secret-*.yaml` is too broad a pattern.** Use `*.dec.yaml` and
  `*-secret.yaml` (or better, encrypt with SOPS/sealed-secrets and drop
  the pattern entirely) so structural manifests named `secret-*` remain
  visible.
- **Every `Application` manifest we ship should have a test that verifies
  `kubectl apply --dry-run=server -f` succeeds against a fresh cluster.**
  A CI job with `kind create cluster && kubectl apply -f argocd/` would
  have caught this.

### 2. Placeholder `repoURL` never rewritten

**Broke:** Every `Application` manifest referenced
`https://github.com/taptech/taptech-gitops.git` (the scaffold
placeholder). The actual repo is `github.com/glawson6/taptech-gitops`.
`scripts/set-repo-url.sh` exists to rewrite the placeholder but hadn't
been run.

**Presented as:** After first bootstrap, root Application at status
`Unknown` with `authentication required`. ArgoCD couldn't route
credentials because the URL didn't match the registered PAT credential.

**Fix (commit `d4467c6`):** Ran `./scripts/set-repo-url.sh
https://github.com/glawson6/taptech-gitops.git`.

**Best practice:**

- **`bootstrap.sh` should verify no placeholder URLs remain** before it
  applies anything. One `grep -q 'taptech/taptech-gitops' argocd/` check
  and a `die "run set-repo-url.sh first"` prevents this class of bug.
- **Treat `set-repo-url.sh` as a mandatory first step in the README.**
  Currently it's mentioned; making it a hard prerequisite check in
  `bootstrap.sh` would enforce it.

### 3. Private repo + no ArgoCD credentials

**Broke:** The repo is private. ArgoCD's built-in git support needs
either public repo access or a registered credential. Nothing in this
repo declares a `Secret` with `argocd.argoproj.io/secret-type=repository`,
so ArgoCD had no way to authenticate.

**Presented as:** Even after the URL fix, root sync still failed with
`authentication required`. Fixed once by manually creating a Secret with
the PAT; then wiped by the MicroK8s reinstall; then re-created.

**Fix:** Two paths — one taken, one recommended:

- **What was done:** manually created a Secret in `argocd` namespace:
  ```bash
  kubectl -n argocd create secret generic gitops-repo-creds \
    --from-literal=type=git \
    --from-literal=url=https://github.com/glawson6/taptech-gitops.git \
    --from-literal=username=glawson6 \
    --from-literal=password="$PAT"
  kubectl -n argocd label secret gitops-repo-creds \
    argocd.argoproj.io/secret-type=repository
  ```
- **What should be done long-term:** ship an `ExternalSecret` manifest at
  `platform/argocd/manifests/mgmt/externalsecret-repo.yaml` that pulls
  from 1Password `gitops-repo/{username,password}` into the same Secret
  shape, applied by `mgmt-argocd`. Then a fresh bootstrap sets it up
  automatically. **This is filed as a follow-up in
  `docs/bootstrap-mgmt-cluster.md`** but not yet implemented.

**Best practice:**

- **Bootstrap must include repo credential seeding**, either as a
  documented manual step in `bootstrap.sh`'s tail message (add it, it's
  missing) or as an ExternalSecret ArgoCD adopts on first sync.
- **Prefer fine-grained PATs** scoped to just this repo, `Contents:
  Read-only` if this is the only cluster that reads it, or `Read/Write`
  if Jenkins commits image-tag bumps here.

### 4. `apps-prod` cluster manifests + AppSet wedged `root`

**Broke:** `argocd/clusters/apps-prod/*.yaml` and
`argocd/appsets/applications.yaml` both target `destination.name:
apps-prod` — a cluster that hasn't been registered with ArgoCD yet (per
`docs/adding-a-cluster.md`, that's a separate future step).

**Presented as:** Root's sync-wave barrier ("wait for wave -7 Healthy
before starting wave -6") stalled forever because
`apps-prod-secret-stores` could never reach Healthy (target cluster
doesn't exist). All wave -6, -5, -3, 0, 1, 2, 5 mgmt Applications
never got created.

**Fix (commits `0a37661`, `23870ae`):** Excluded both from `root`'s
directory scan:

```yaml
# argocd/bootstrap/root.yaml
directory:
  recurse: true
  exclude: '{bootstrap/*,clusters/apps-prod/*,appsets/*}'
```

**Best practice:**

- **`root` should default to mgmt-only.** The comment in `root.yaml`
  documents un-exclude-when-registered — but the default state should be
  the working one, not the aspirational one.
- **When adding a new cluster:** register with `argocd cluster add ...
  --name <name>` FIRST, THEN un-exclude in git in the same commit that
  adds `clusters/<name>/`.
- **Long-term:** consider splitting root into two Applications
  (`root-mgmt`, `root-apps-prod`) so mgmt bootstrap is fully independent
  of app-cluster registration state.

### 5. ClusterIssuer sync-wave was inverted

**Broke:** `platform/cert-manager/manifests/{mgmt,apps-prod}/cluster-issuers.yaml`
had `argocd.argoproj.io/sync-wave: "-4"`. The comment on the file said
"applied a wave AFTER the chart so the CRDs exist" — but `-4` is BEFORE
the chart's default wave `0`, not after. Sign error.

**Presented as:** `mgmt-cert-manager` stuck at
`OutOfSync/Missing`. Message: "waiting for healthy state of
ClusterIssuer/letsencrypt-prod and 1 more resources". ClusterIssuers
couldn't become Healthy (no cert-manager webhook), so the chart
resources at wave 0 never installed.

**Fix (commit `903824d`):** Changed sync-wave to `"4"` (positive) so the
CI applies after the chart:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

**Best practice:**

- **Sign errors in sync-wave are subtle.** When a manifest says "after
  the chart", the number MUST be greater than the chart's default (0).
- **CI should include a sync-wave sanity check** for cert-manager
  ClusterIssuers, admission webhooks that reference CRDs from their own
  chart, and any similar hen-and-egg cases.
- **Prefer `SkipDryRunOnMissingResource=true`** on Applications where
  early-wave resources reference CRDs installed later in the same App.
  We added that to `mgmt-cert-manager` regardless (commit `516fd52`).

### 6. Ingress-nginx admission webhook Job stalled repeatedly

**Broke:** The `ingress-nginx` Helm chart installs a `PreSync` `Job`
(`ingress-nginx-admission-create`) that provisions a TLS cert for the
admission webhook. On this resource-tight single-node MicroK8s, that Job
repeatedly failed to schedule or hung, leaving ArgoCD stuck waiting for
a hook completion that never came. Deleting the Job made ArgoCD think
the hook succeeded when it hadn't (phantom hook state).

**Presented as:** `mgmt-ingress-nginx` stuck `OutOfSync/Progressing`
with message "waiting for completion of hook
batch/Job/ingress-nginx-admission-create" — but no Job existed. Trying
to delete the Application recreated the same stuck state.

**Fix (commit `516fd52`):** Disabled admission webhooks on mgmt:

```yaml
# platform/ingress/clusters/mgmt.yaml
controller:
  admissionWebhooks:
    enabled: false
```

Also added `ApplyOutOfSyncOnly=true` to the Application syncOptions so a
single drifted resource can't retrigger whole-app sync loops.

**Best practice:**

- **On single-node / resource-tight clusters, disable optional
  admission webhooks.** ArgoCD server-side-validates before applying;
  the runtime webhook is defense-in-depth for untrusted user
  submissions, which mgmt doesn't have.
- **Never delete a stuck ArgoCD hook Job with `kubectl delete`.** ArgoCD
  tracks hook phase in its own state; deleting the Job leaves the phase
  as `Running` forever. Instead: delete-and-recreate the Application
  itself, or use the ArgoCD API to terminate the operation.

### 7. Traefik addon left orphaned container after `microk8s disable ingress`

**Broke:** Recent MicroK8s ships **Traefik** as the `ingress` addon,
not NGINX. `microk8s enable ingress` created a bare Traefik pod (no
Deployment, no Helm release owning it). `microk8s disable ingress`
removed the pod entry from k8s but the containerd shim + Traefik
process kept running, holding host ports 80/443 hostage.

**Presented as:** After `microk8s disable ingress` succeeded and the
git-managed `ingress-nginx` DaemonSet tried to bind hostPorts, the pods
sat `Pending` with "didn't have free ports for the requested pod
ports". `ps -ef` on the host showed a running Traefik process; `ctr
containers ls` showed the orphaned container in the `k8s.io`
namespace.

**Fix:** Manually killed the orphan via containerd:

```bash
sudo /snap/bin/microk8s ctr --namespace=k8s.io task kill --signal SIGKILL <container-id>
sudo /snap/bin/microk8s ctr --namespace=k8s.io containers rm <container-id>
sudo pkill -9 traefik
```

Also updated `scripts/prep-microk8s.sh` (commit already in earlier work)
to disable the addon during host prep so future bootstraps don't hit it.

**Best practice:**

- **Never run `microk8s enable ingress`** on a mgmt cluster where you
  want a git-managed ingress. `scripts/prep-microk8s.sh` handles this.
- **After `microk8s disable ingress`, verify no orphans:**
  ```bash
  sudo /snap/bin/microk8s ctr --namespace=k8s.io containers ls | grep -i traefik
  sudo ss -tlnp | grep -E ':80 |:443 '
  ```
- **File a MicroK8s upstream issue** if the addon disable doesn't clean
  up. This is arguably a snap bug.

### 8. Jenkins chart 5.8.16 pinned to Jenkins 2.492.1, but `installLatestPlugins:true` fetched newer plugins requiring 2.504.3+

**Broke:** `platform/jenkins/values.yaml` had `installLatestPlugins:
true` and a chart pin (`5.8.16`) that shipped Jenkins `2.492.1`.
Plugins on the Jenkins update center are versioned; "latest" as of
today required Jenkins ≥ `2.504.3` for `workflow-scm-step`, `git`,
`credentials`, `cloudbees-folder`, and about a dozen more.

**Presented as:** Jenkins pod's `init` container printed pages of
`plugin XYZ requires a greater version of Jenkins (2.504.3) than
2.492.1` and exited 1. Pod entered `Init:CrashLoopBackOff` forever.

**Fix (commit `9638da0`):** Bumped chart to `5.9.54` (ships Jenkins
`2.568.2`).

**Best practice:**

- **`installLatestPlugins: true` + pinned chart is a time bomb.** Pick
  one:
  - **Pin plugins explicitly** with `plugin-name:X.Y.Z` and update on
    a schedule. Reproducible, boring, safer.
  - **OR** keep `installLatestPlugins: true` and pin the chart to
    `.tag` (or use a Renovate/Dependabot rule to bump it monthly).
- **When bumping the Jenkins chart:** `helm show chart jenkins/jenkins`
  and `helm show chart jenkins/jenkins --version <old>` and confirm
  the `appVersion` moved.

### 9. k8s-sidecar 2.10.1 rejected MicroK8s CA (Python 3.15 stricter TLS)

**Broke:** The Jenkins chart bundles `kiwigrid/k8s-sidecar:2.10.1` as
the `config-reload` init container. This image runs Python 3.15, whose
`ssl` module now rejects CA certs that lack the `keyUsage` extension.
MicroK8s' in-cluster CA does not include it. So the sidecar cannot
call the K8s API and exits 1.

**Presented as:** After the Jenkins version fix, pod moved to
`Init:0/2` with `config-reload-init` crash-looping. Sidecar logs
showed `SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED]
certificate verify failed: CA cert does not include key usage
extension`.

**Fix (commit `1e70ef9`):** Set `SKIP_TLS_VERIFY=true` env var on the
config-reload sidecar in `platform/jenkins/values.yaml`:

```yaml
controller:
  sidecars:
    configAutoReload:
      env:
        - name: SKIP_TLS_VERIFY
          value: "true"
```

**Best practice:**

- **On MicroK8s specifically, workloads with strict TLS validation of
  the in-cluster API may need `SKIP_TLS_VERIFY` or a rebuild of the
  MicroK8s CA.** This will bite more workloads over time as language
  runtimes tighten.
- **Long-term fix at the platform level:** regenerate the MicroK8s
  serving CA with the `keyUsage` extension. This is a MicroK8s bug
  and worth reporting.
- **Sidecars talking to the local kubelet only need HTTP** if the
  scheme is configurable; check chart options before adding `SKIP_TLS_VERIFY`.

### 10. 1Password field names didn't match ExternalSecret refs (`credential` vs `password`)

**Broke:** Two `ExternalSecret` manifests
(`platform/jenkins/manifests/mgmt/externalsecrets.yaml`) referenced
`remoteRef.key: gitops-repo/credential` and `registry-push/credential`.
But 1Password items conventionally use `password` for PASSWORD-typed
fields, and this vault does. So ESO couldn't resolve the reference.

**Presented as:** `SecretSyncedError` on those ExternalSecrets after
bootstrap. K8s Secrets that Jenkins / ArgoCD need to consume never got
created. `op read` returned `[ERROR] ... item does not have a field
'credential'` — but embedded in the output rather than as a non-zero
exit code, which meant scripting was easy to fool.

**Fix (commit `7642763`):** Changed both to `remoteRef.key:
<item>/password`.

**Best practice:**

- **Use a single naming convention across all vault items** — either
  `password` everywhere (matches 1Password's UI default) or
  `credential` everywhere. Document which.
- **`bootstrap-mgmt-cluster.md` should include a validation script** that
  iterates the ExternalSecrets in git and confirms each `remoteRef.key`
  resolves in the target vault:
  ```bash
  export OP_SERVICE_ACCOUNT_TOKEN=$TOKEN
  # For each remoteRef.key like `foo/bar`:
  op read "op://taptech-mgmt/foo/bar" || echo "MISSING: foo/bar"
  ```
- **Add a CI check** that greps all ExternalSecret manifests and
  cross-references them against a known vault schema.

### 11. MicroK8s kubelite CPU thrash after heavy state manipulation

**Broke:** Not a config bug in the repo — a behavior of MicroK8s on
this single-node VPS under load. Many delete-and-recreate cycles on
stuck resources (fixing #6, #7 iteratively) left kubelite's internal
watch/reconcile queues backlogged. It settled into 170% CPU
persistently, with sub-second API server unavailability windows that
made every subsequent kubectl call flaky. `StatefulSet` controller
stopped reconciling new pods; `kube-controller-manager` leader lease
had a 3-day-old holder that couldn't be re-acquired.

**Presented as:** Load average 8-10 sustained. `kubectl get` returning
intermittent `TLS handshake timeout`. `mgmt-jenkins` StatefulSet
reporting `READY 1/1` in status but zero pods actually existing.

**Fix:** Rebooted the VM. Load dropped briefly then climbed again.
Ultimately went to full `snap remove microk8s --purge && snap install
microk8s --classic --channel=1.32/stable`. Fresh install stayed
healthy through the whole re-bootstrap.

**Best practice:**

- **Prefer `argocd app delete --cascade` (via API) over
  `kubectl delete application`** because ArgoCD's own delete path
  handles finalizers and hook state cleanly. Direct kubectl deletes on
  Applications repeatedly left dangling operationState references.
- **Don't force-delete pods to escape hook wedges.** It creates the
  phantom-hook state that then requires deleting the parent
  Application, which then leaves ArgoCD's controller with a stale
  operation reference, which then requires deleting root, which then
  leaves the child Application specs orphaned. It's turtles all the
  way down. When ArgoCD is wedged, the cheapest fix is often `argocd
  app terminate-op` via the API, then `argocd app sync --force`.
- **If MicroK8s does thrash, reinstall it.** Faster than surgery. Everything
  meaningful is in git and ArgoCD rebuilds in 15 minutes.
- **Consider a lighter-weight bootstrap-only cluster** for the first
  install. Then move workloads once stable. Or just size the VM
  generously — MicroK8s + kine-based dqlite is not free.

## Meta patterns

Beyond the specific bugs, three habits made the day worse than it needed
to be:

### A. "It should work" isn't verification

The repo shipped assuming Jenkins would pull "latest plugins" against a
pinned Jenkins version and it would just fit. It shipped assuming
`.gitignore` wouldn't accidentally match structural manifests. It
shipped assuming `sync-wave: -4` was "after wave 0" because "-4 is bigger
than 0 in absolute value" or whatever heuristic slipped in when the
comment was written. Each of these could have been caught by rendering
the repo once against a throwaway `kind` cluster, or by writing a CI
check that just does `kubectl apply --dry-run=server -f`.

**Rule: any manifest not tested against a real cluster is unverified.**

### B. Direct kubectl deletion of ArgoCD resources leaves stale state

I deleted stuck `Application` CRs directly with kubectl at least a dozen
times. Each time, ArgoCD's `application-controller` was mid-way through
an `operationState.phase=Running` block that referenced the resource I'd
just deleted. That controller then held stale references in memory,
which propagated to child Application syncResults, which meant
subsequent syncs on OTHER Applications also got confused. The fix is
usually to restart the controller pod — but on a thrashing kubelite,
that took multiple attempts.

**Rule: prefer `argocd app` CLI over `kubectl delete application`.**
When ArgoCD is unavailable (bootstrap phase), delete Applications one at
a time and let each finalize before touching the next. Don't
strip-finalizers in a batch loop.

### C. Reboot-first, surgery-second

We spent ~4 hours doing surgery on stuck resources when a
`snap remove --purge && snap install` would have taken 15 minutes and
started us on a known-clean state. The reason we didn't do it earlier
was fear that ArgoCD would have to be reinstalled — but ArgoCD IS
installed by `bootstrap.sh` in one command, and all state that matters
is in git and 1Password. Cluster state is expendable when the desired
state is fully declarative.

**Rule: if you've been fighting the cluster for more than an hour and
your desired state is fully in git, reinstall.**

## What's fixed in the repo now

All eleven fixes are committed and pushed to `origin/main`. A fresh
bootstrap on any new mgmt cluster should not hit any of these:

| # | Commit | Change |
|---|---|---|
| 1 | `f7c55f5` | `.gitignore` un-ignores `secret-stores.yaml` |
| 2 | `d4467c6` | `repoURL` rewritten to `glawson6/taptech-gitops` |
| 4 | `0a37661` | Root excludes `clusters/apps-prod/*` |
| 4 | `23870ae` | Root excludes `appsets/*` |
| — | `800af37` | Dropped `external-dns` from mgmt (deferred to first Cloudflare setup) |
| 5 | `903824d` | ClusterIssuer sync-wave `-4` → `4` |
| — | `80e782d` | Allow `charts.min.io` in `platform` AppProject |
| 6 | `516fd52` | `SkipDryRunOnMissingResource=true` on cert-manager; `admissionWebhooks: false` on ingress-nginx mgmt |
| 8 | `9638da0` | Jenkins chart `5.8.16` → `5.9.54` (Jenkins `2.492.1` → `2.568.2`) |
| 10 | `7642763` | ExternalSecret `remoteRef.key` field name `credential` → `password` |
| 9 | `1e70ef9` | `SKIP_TLS_VERIFY=true` on Jenkins config-reload sidecar |

## Still open

Not defects, just things left for a future session:

- **Repo credential as ExternalSecret**: the ArgoCD `gitops-repo-creds`
  Secret is created manually today. Should be an `ExternalSecret` under
  `platform/argocd/manifests/mgmt/` sourced from 1Password.
- **Register `apps-prod` cluster** and un-exclude
  `clusters/apps-prod/*` + `appsets/*` in `root.yaml` (task #16).
- **Wire Jenkins → MinIO as S3 store** (task #17, Step 4 of
  `bootstrap-mgmt-cluster.md`).
- **Rotate 1Password service account token** by ~Nov 2026 (task #18).
- **Ingress hostnames + TLS**: `Ingress` objects aren't defined for any
  service yet. cert-manager is ready, ingress-nginx is ready, but
  nothing external resolves.
- **Cosmetic Sync drift** on Jenkins / MinIO / Monitoring: Helm-managed
  labels. Suppress with `ignoreDifferences` on those Applications.
- **A `kind`-based smoke test in CI** that runs
  `kubectl apply --dry-run=server -f argocd/` and confirms every
  Application at least parses. Would have caught bugs #1, #5, #10.
