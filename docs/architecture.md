# Architecture

## The system in one picture

```
┌────────────────────────┐                      ┌──────────────────────────────┐
│   git: taptech-gitops  │                      │           Argo CD            │
│   github.com/glawson6/ │ -- polls main --->   │   self-managed via           │
│   taptech-gitops.git   │                      │   mgmt-argocd Application    │
└────────────────────────┘                      └──────────────────────────────┘
                                                                |
                                                                |
                                                                | v applies
                                                                |
    ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │ [ Tier 1 :: FOUNDATION -- waves -10 to -7 ]                                                                            │
    │                                                                                                                        │
    │ ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐ │
    │ │ mgmt-storage             │  │ mgmt-external-secrets    │  │ mgmt-reloader            │  │ mgmt-secret-stores       │ │
    │ │ wave -10                 │  │ wave -8                  │  │ wave -8                  │  │ wave -7                  │ │
    │ │ StorageClass             │  │ ESO controller           │  │ restart on cfg chg       │  │ 1Password store          │ │
    │ └──────────────────────────┘  └──────────────────────────┘  └──────────────────────────┘  └──────────────────────────┘ │
    │                                                                                                                        │
    └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

    ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │ [ Tier 2 :: PLATFORM -- waves -5 to 0 ]                                                                                │
    │                                                                                                                        │
    │ ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐ │
    │ │ mgmt-cert-manager        │  │ mgmt-jenkins-agents      │  │ mgmt-ingress-nginx       │  │ mgmt-argocd              │ │
    │ │ wave -5                  │  │ wave -5                  │  │ wave -3                  │  │ wave 0                   │ │
    │ │ issues TLS certs         │  │ build agent RBAC         │  │ hostPort :80/:443        │  │ self-management          │ │
    │ └──────────────────────────┘  └──────────────────────────┘  └──────────────────────────┘  └──────────────────────────┘ │
    │                                                                                                                        │
    └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

    ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │ [ Tier 3 :: WORKLOADS -- waves 1 to 5 ]                                                                                │
    │                                                                                                                        │
    │       ┌──────────────────────────┐          ┌──────────────────────────┐          ┌──────────────────────────┐         │
    │       │ mgmt-minio               │          │ mgmt-jenkins             │          │ mgmt-monitoring          │         │
    │       │ wave 1  -  S3 store      │          │ wave 2  -  CI/CD         │          │ wave 5  -  Prom/Grafana  │         │
    │       └──────────────────────────┘          └──────────────────────────┘          └──────────────────────────┘         │
    └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘


┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ingress-nginx  ->  argocd.taptech.net | jenkins.taptech.net | grafana.taptech.net | minio-console.taptech.net   [allowlist 104.14.172.65/32]  │
│                                                                                                                                                │
│ ingress-nginx  ->  minio.taptech.net (S3 API)                                                                    [public, cred-gated]         │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Reading it:** ArgoCD sits at the top, self-managed. It polls
`origin/main` roughly every three minutes and applies whatever
changed. Its output is 11 sibling `Application` resources grouped
into three tiers by sync-wave — foundation (storage, secrets, reload
controller), platform (cert-manager, ingress, ArgoCD's own release),
and workloads (MinIO, Jenkins, monitoring). The bottom band is the
one ingress controller fronting five external hostnames.

## The 12th Application: `root`

Not shown in the tier diagram because it's the bootstrap. `root` is
applied by hand once via `scripts/bootstrap.sh`. Its only job is to
recursively watch `argocd/` in git and create/update the sibling
`mgmt-*` Applications. Deleting `root` doesn't delete its children
(they have their own finalizers); creating it on a fresh cluster
creates all eleven.

See `docs/mgmt-ui-inventory.md` for the table of every mgmt
Application with its purpose and external URL.

## Traffic paths in

Two distinct paths hit the cluster from outside:

```
                                                                                        ┌──────────────────────────┐
┌──────────────────────┐                ┌──────────────────────────────┐                │ argocd-server            │
│ Admin workstation    │   https        │ ingress-nginx                │    allow       │ jenkins                  │
│ 104.14.172.65        │--------------->│ allowlist check              │--------------->│ monitoring-grafana       │
└──────────────────────┘                └──────────────────────────────┘                │ minio-console            │
                                                                                        └──────────────────────────┘
                                          x   blocked otherwise (HTTP 403)

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

┌──────────────────────┐                ┌──────────────────────────────┐                ┌──────────────────────────┐
│ External CI          │     s3 API     │ ingress-nginx                │   cred check   │ minio (S3 API)           │
│ any public IP        │--------------->│ minio.taptech.net (open)     │--------------->│ port 9000                │
└──────────────────────┘                └──────────────────────────────┘                └──────────────────────────┘

                                          signed request required; buckets are per-credential ACL
```

- **Admin traffic** (top): only the four browser UIs. Ingress-nginx
  applies the `whitelist-source-range` annotation and returns HTTP
  403 for any source IP not in the list. Auth (ArgoCD admin, Jenkins
  admin, Grafana admin) is the second gate.
- **S3 traffic** (bottom): `minio.taptech.net` deliberately has no
  IP allowlist so external CI / laptops / other clusters can push
  objects. Access is controlled by AWS SigV4 signatures against
  per-user access keys stored in 1Password.

See `docs/mgmt-ui-inventory.md` for how to update the allowlist and
`docs/ingress-and-tls.md` for the cert-issuance flow.

## Why the management cluster is separate

The management cluster holds the credentials that matter: ArgoCD's
connection to any applications cluster, the registry push credential,
the GitOps PAT, MinIO admin. Applications clusters (when registered)
hold only runtime secrets. Compromising an application does not yield
the ability to deploy.

The inverse is worth stating too, because it's easy to get backwards:
the management cluster is the higher-value target of the two, despite
feeling like "just build infrastructure." Anything with access to it
can deploy anything to production. That's why every mgmt UI sits
behind an IP allowlist AND admin auth.

## Repo layout that produces the diagram

```
argocd/
  bootstrap/root.yaml                one Application, applied by hand once
  projects/{platform,applications}   AppProjects: sourceRepo allowlist, dest scope
  clusters/mgmt/*.yaml               one Application per Tier-1/2/3 component
  clusters/apps-prod/*.yaml          same shape, excluded from root until cluster registered
  appsets/applications.yaml          matrix generator (env x service overlay) for business apps
platform/
  <component>/values.yaml            shared Helm values across all clusters
  <component>/clusters/<name>.yaml   per-cluster override, merged second
  <component>/manifests/<name>/      raw manifests (ExternalSecrets, ClusterIssuers, etc.)
applications/
  <service>/base/                    cluster-agnostic Kustomize base
  <service>/overlays/<env>/          per-environment overlay (uniform diff surface)
docs/                                architecture, runbooks, postmortem
scripts/                             bootstrap + day-2 helpers
```

**Every `mgmt-*` Application in the diagram maps to one file under
`argocd/clusters/mgmt/`. Every file references one component under
`platform/`.** Adding a new mgmt component means one file in each of
those two directories — see `docs/adding-a-mgmt-app.md`.

## Why Kustomize for our services and Helm for third-party

- **Our services** use `base/` + `overlays/<env>/`. The overlay is a
  literal diff, so a pull request shows exactly what differs between
  environments. `kustomization.yaml` has an `images:` block that
  `kustomize edit set image` rewrites — the one-line commit Jenkins
  makes.
- **Third-party components** ship as Helm charts. We consume them as
  charts and keep only values in this repo. Re-templating someone
  else's chart into raw manifests means owning their upgrade path
  forever.

Rejected: Helm charts for our own services (pushes environment
differences into `values-prod.yaml`, where a diff no longer tells you
what changes in the cluster). Rejected: Helm + Kustomize
post-rendering (most powerful, hardest to debug).

## Why ApplicationSets for services, explicit Applications for platform

Services are uniform and numerous — a matrix generator crosses the
environment list with the discovered overlay directories, so adding
a service means adding a directory and adding an environment means
adding a list entry.

Platform components are individual and ordered by sync wave:
cert-manager before anything requests a certificate, storage before
a PVC binds, External Secrets before anything needs a secret. Waves
written out per component are clearer than waves derived from a
generator.

## Sync waves (authoritative table)

| Wave | Application | Why this order |
|---|---|---|
| -10 | `mgmt-storage` | Every PVC bind needs this StorageClass |
| -8 | `mgmt-external-secrets` | ESO CRDs must exist before any ExternalSecret |
| -8 | `mgmt-reloader` | Watches everything but no dependencies |
| -7 | `mgmt-secret-stores` | Needs ESO's `ClusterSecretStore` CRD from wave -8 |
| -5 | `mgmt-cert-manager` | Chart install; CRDs land here |
| -5 | `mgmt-jenkins-agents` | Namespace + RBAC for Jenkins pods |
| -3 | `mgmt-ingress-nginx` | Serves 80/443 before any workload needs an ingress |
| 0 | `mgmt-argocd` | Argo CD self-manages from git |
| 1 | `mgmt-minio` | Uses ExternalSecret (wave -8), storage (wave -10) |
| 2 | `mgmt-jenkins` | Uses ExternalSecret (-8), storage (-10), ingress (-3), MinIO (1) |
| 4 | ClusterIssuers | Applied AFTER cert-manager Deployment is Healthy — otherwise the webhook that validates them isn't up (this was a bug once; see `docs/what-went-wrong.md` #5) |
| 5 | `mgmt-monitoring` | Last: uses ingress, cert-manager, StorageClass |

## Monitoring topology

Prometheus runs on **both** the mgmt cluster AND every registered
apps cluster — kubelet, node and cAdvisor metrics can only be
scraped locally, so a single central Prometheus is not an option.

Grafana runs only on the management cluster and holds a datasource
per Prometheus, so dashboards and alert routing are configured once.
`platform/monitoring/clusters/mgmt.yaml` defines Grafana's
`additionalDataSources` — one entry per registered apps cluster.

## Where secrets come from

Two-layer: **1Password vault** → **ESO** → **K8s Secret** →
**workload**. See `docs/secrets.md` for the full flow.

The one thing that cannot come from git: the ESO service-account
token that lets the operator authenticate to 1Password in the first
place. That's created by hand once per cluster during
`bootstrap.sh`. `docs/rotate-1password-token.md` documents rotation.

## Where the bootstrap actually happens

- `scripts/bootstrap.sh` — one hand-run per cluster. Installs ArgoCD
  via Helm, seeds the 1Password token, applies
  `argocd/bootstrap/root.yaml`. Everything else in the diagram flows
  from root.
- `scripts/prep-microk8s.sh` — one-time host prep (MicroK8s addons,
  kubeconfig extraction).
- `scripts/fetch-kubeconfigs.sh` — pull kubeconfigs from each
  cluster and merge them into `~/.kube/config` with sane names.

## Related docs

- **`docs/mgmt-ui-inventory.md`** — every Application in table form
  with URLs + auth model.
- **`docs/adding-a-mgmt-app.md`** — runbook for adding a new
  platform component; worked example adds a jaiclaw agent.
- **`docs/ingress-and-tls.md`** — DNS records + Let's Encrypt.
- **`docs/secrets.md`** — 1Password + ESO wiring.
- **`docs/adding-a-cluster.md`** — how to onboard a new apps cluster.
- **`docs/apps-prod-migration.md`** — comprehensive plan for
  adopting the live 23.227.173.107 cluster in place.
- **`docs/temp-vps-migration.md`** — alternative plan: rent a temp
  VPS, clone the cluster, wipe + rebuild original as GitOps
  `apps-prod`. Faster (~5-7 days). Ships with three scripts:
  `scripts/temp-vps-init.sh`, `scripts/clone-k8s-objects.sh`,
  `scripts/rsync-pvc.sh`.
- **`docs/what-went-wrong.md`** — postmortem of the 12-hour
  bootstrap session; every fix that shipped is documented here.
- **`docs/bootstrap-mgmt-cluster.md`** — end-to-end bootstrap
  runbook (has a TL;DR at the top).
- **`docs/rotate-1password-token.md`** — ESO token rotation.
- **`docs/jenkins-integration.md`** — how Jenkins commits image-tag
  bumps into this repo.
