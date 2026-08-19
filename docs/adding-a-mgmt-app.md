# Adding a new application to the management cluster

This runbook walks the exact pattern every mgmt-* Application follows.
End of the doc: a worked example adds a **jaiclaw-agent** that talks
to ArgoCD, Jenkins, Grafana, and MinIO from inside the cluster.

## The pattern in one paragraph

For every new mgmt component you make at most three files:

1. **An ArgoCD `Application`** at `argocd/clusters/mgmt/<name>.yaml`
   pointing at either a Helm chart (upstream repo) or a raw manifests
   directory in this repo.
2. **A `platform/<name>/` directory** with the manifests / values
   the Application references.
3. **Optionally an `ExternalSecret`** under
   `platform/<name>/manifests/mgmt/` if it needs credentials.

Then commit + push. ArgoCD picks up the new Application within ~3
minutes, syncs it in wave order, and creates whatever it declares.

## Decide first: Helm-managed or raw manifests?

| Situation | Choose |
|---|---|
| The upstream ships a Helm chart | Helm — reference the chart, override with `values.yaml` |
| You're deploying your own image with a Deployment + Service + Ingress | Raw manifests (single Application with `path:`) |
| You're deploying your own image but it needs to be templated by env | Kustomize (single Application with `path:`) |
| Third-party ships raw YAML only | Bundle it under `platform/<name>/manifests/mgmt/`, reference by path |

The 12 existing mgmt Applications are 8 Helm + 4 raw-manifests. Same
`Application` shape for both; the difference is what's in `source`.

## Sync-wave choice

Read `docs/architecture.md` for the full table. Rules of thumb:

- **Foundation waves (-10 to -7):** you're providing something every
  workload needs (StorageClass, RBAC, admission controller). Adding
  here is rare.
- **Platform waves (-5 to 0):** controllers, ingress, cert issuance.
  Also rare unless you're replacing an existing component.
- **Workload waves (1 to 5):** every new app goes here. Wave 5 is
  fine unless you specifically need another Application to consume
  yours (very unlikely).

Waves are per-Application, but resources inside an Application can
have their OWN wave via `argocd.argoproj.io/sync-wave` annotation.
Use that when one resource in your bundle depends on another (see
the ClusterIssuer-at-wave-4 pattern in cert-manager).

## AppProject membership

Every Application in this repo lives in one of two AppProjects:

- **`platform`** — cluster-scoped resources allowed (RBAC,
  CustomResourceDefinitions, StorageClass, ClusterIssuer, etc.).
  Every third-party component sits here.
- **`applications`** — namespace-scoped only. Business services
  built by Jenkins live here.

If your new component is:
- A controller / operator / cluster-scoped anything → `platform`
- A single-namespace Deployment → could go either place; prefer
  `applications` unless it needs `ClusterRole` bindings

For a Helm-based Application, you must also **allowlist the chart
repo URL** in `argocd/projects/platform.yaml` (or `applications.yaml`)
under `sourceRepos`. This bit us during bootstrap — MinIO wouldn't
sync until `https://charts.min.io` was added to the platform project.

## The Application template (Helm)

Copy from an existing sibling:

```yaml
# argocd/clusters/mgmt/<name>.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mgmt-<name>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "<pick from table>"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform          # or 'applications'
  destination:
    name: in-cluster         # NEVER a URL; look up by ArgoCD-registered name
    namespace: <name>        # the namespace the Helm chart creates
  sources:
    - repoURL: 'https://<chart-repo>'
      chart: <chart-name>
      targetRevision: <pinned version>
      helm:
        releaseName: <name>
        valueFiles:
          # Shared defaults first, per-cluster overrides second. Helm merges
          # in order, so the cluster file wins on any key it sets.
          - $values/platform/<name>/values.yaml
          - $values/platform/<name>/clusters/mgmt.yaml
    - repoURL: 'https://github.com/glawson6/taptech-gitops.git'
      targetRevision: main
      ref: values
    # Optional third source: extra manifests (ExternalSecrets, custom
    # configs) that the chart doesn't include.
    - repoURL: 'https://github.com/glawson6/taptech-gitops.git'
      targetRevision: main
      path: platform/<name>/manifests/mgmt
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      # Add these if you know the chart's admission fills in defaults on
      # your CRs that ArgoCD then keeps trying to reset:
      # - ApplyOutOfSyncOnly=true
      # If your chart bundles CRDs that other resources in the same App
      # reference BEFORE the CRDs are installed (like cert-manager +
      # ClusterIssuer at wave 4):
      # - SkipDryRunOnMissingResource=true
```

## The Application template (raw manifests / Kustomize)

Single-source, simpler:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mgmt-<name>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "<pick>"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: 'https://github.com/glawson6/taptech-gitops.git'
    targetRevision: main
    path: platform/<name>/manifests/mgmt   # Kustomize if kustomization.yaml here
  destination:
    name: in-cluster
    namespace: <name>
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Kustomize is detected automatically if `path` contains a `kustomization.yaml`.

## Adding an ExternalSecret

If your workload needs a credential from 1Password:

1. Create the item in the `taptech-mgmt` vault. Field names
   `username`/`password` — see the ExternalSecret field-refs
   discussion in `docs/what-went-wrong.md` (#10) for the
   `credential` vs `password` gotcha.
2. Add the ExternalSecret manifest under
   `platform/<name>/manifests/mgmt/externalsecret-<what>.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <target-secret-name>
  namespace: <name>
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: onepassword}
  target: {name: <target-secret-name>, creationPolicy: Owner}
  data:
    - secretKey: <key-in-k8s-secret>
      remoteRef: {key: <op-item>/<op-field>}
```

3. Consume the K8s Secret in your workload the usual way
   (`envFrom.secretRef`, `volumes.secret`, `existingSecret` in a
   Helm chart).

## Adding an Ingress

Copy the pattern from `platform/argocd/values.yaml` or
`platform/jenkins/values.yaml`. Two decisions:

1. **Public or IP-restricted?** Admin UIs get the
   `whitelist-source-range` annotation with your workstation IP.
   Service endpoints that external systems call get no allowlist.
   See `docs/mgmt-ui-inventory.md`.
2. **Which ClusterIssuer?** Start with `letsencrypt-staging` for
   first-issuance sanity; promote to `letsencrypt-prod` once
   staging works. See `docs/ingress-and-tls.md`.

## Testing before merge

The CI smoke workflow (`.github/workflows/smoke.yaml`) runs on every
PR and catches:

- YAML parse errors
- Files accidentally gitignored (the `secret-*.yaml` bug)
- Placeholder `taptech/taptech-gitops` repo URLs
- ClusterIssuer sync-waves that are non-positive
- ExternalSecret `remoteRef.key` using non-conventional field names
- `kubectl apply --dry-run=server` against a fresh kind cluster for
  every Application + manifest

Before pushing, run it locally on the manifests you touched:

```bash
kubectl apply --dry-run=client -f argocd/clusters/mgmt/<name>.yaml
kubectl apply --dry-run=client -f platform/<name>/manifests/mgmt/
```

For Helm-based Applications, render the chart with your values
first to catch template errors:

```bash
helm template <name> <repo>/<chart> --version <pin> \
  -f platform/<name>/values.yaml \
  -f platform/<name>/clusters/mgmt.yaml \
  | kubectl apply --dry-run=client -f -
```

## After merge

ArgoCD auto-syncs within ~3 min. Force it:

```bash
kubectl --context taptech-mgmt -n argocd patch application mgmt-<name> \
  --type merge -p '{"operation":{"sync":{}}}'
```

Watch:

```bash
kubectl --context taptech-mgmt -n argocd get application mgmt-<name> -w
```

Green means `SYNC STATUS: Synced` AND `HEALTH STATUS: Healthy`.

## Rollback

Every change is a git revert. ArgoCD picks up the revert commit and
either self-heals to the previous spec (if `selfHeal: true`) or waits
for a manual sync.

If a bad change causes ArgoCD itself to stop reconciling, drop the
Application manually:

```bash
kubectl --context taptech-mgmt -n argocd patch application mgmt-<name> \
  --type merge -p '{"metadata":{"finalizers":null}}'
kubectl --context taptech-mgmt -n argocd delete application mgmt-<name>
```

The finalizer-null step is important — without it the delete blocks
on `resources-finalizer.argocd.argoproj.io` trying to cascade-delete
child resources that may themselves be stuck. See
`docs/what-went-wrong.md` for the full story.

---

# Worked example: `mgmt-jaiclaw-agent`

You want a jaiclaw agent that:

- Runs INSIDE the mgmt cluster (uses in-cluster DNS, no ingress
  needed inbound).
- Reads ArgoCD state (list Applications, get sync status).
- Reads Grafana dashboards and metrics.
- Uploads / downloads objects to/from MinIO.
- Triggers Jenkins builds and monitors them.

Everything is in-cluster east-west traffic. No external port. No
ingress. Just a Deployment + ServiceAccount + a few credentials.

## Step 1 — Directory scaffold

```
platform/jaiclaw-agent/
├── values.yaml                        # (unused; we're going raw-manifests)
└── manifests/
    └── mgmt/
        ├── namespace.yaml             # explicit namespace declaration
        ├── serviceaccount.yaml        # SA + minimal RBAC
        ├── deployment.yaml            # the agent Deployment
        └── externalsecrets.yaml       # tokens for argocd/jenkins/grafana/minio
argocd/clusters/mgmt/
└── jaiclaw-agent.yaml                 # the ArgoCD Application
```

## Step 2 — In-cluster endpoints the agent talks to

Cluster DNS is `cluster.local`. Every service resolves at
`<service>.<namespace>.svc.cluster.local`.

| Product | Endpoint (agent talks HTTP to this) | Auth |
|---|---|---|
| ArgoCD | `http://argocd-server.argocd.svc.cluster.local` (port 80, HTTP internally) | Bearer token (see step 4) |
| Jenkins | `http://jenkins.jenkins.svc.cluster.local:8080` | API token in header `Authorization: Basic <user:token>` |
| Grafana | `http://monitoring-grafana.monitoring.svc.cluster.local` | API key or basic auth |
| MinIO | `http://minio.minio.svc.cluster.local:9000` | AWS SigV4 with accessKey/secretKey |
| Prometheus (bonus) | `http://kps-prometheus.monitoring.svc.cluster.local:9090` | none (in-cluster) |

None of these need the ingress hostnames; those are for external
access only. In-cluster the agent bypasses ingress-nginx, cert-manager,
and the IP allowlist entirely.

## Step 3 — 1Password vault setup

Add four items to the `taptech-mgmt` vault:

| Item | Fields | Notes |
|---|---|---|
| `jaiclaw-agent-argocd` | `token` | ArgoCD API token — generate one in the ArgoCD UI under User Info → Generate Token, or via the CLI |
| `jaiclaw-agent-jenkins` | `username`, `token` | User + API token from Jenkins UI: your profile → Configure → API Token |
| `jaiclaw-agent-grafana` | `token` | Service account token from Grafana: Administration → Service accounts |
| `jaiclaw-agent-minio` | `accessKey`, `secretKey` | Create in MinIO console; scope to specific buckets |

Reuse the existing `minio-jenkins` credential if you prefer; the
above just keeps the audit trail clean per-consumer.

## Step 4 — Manifests

### `platform/jaiclaw-agent/manifests/mgmt/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: jaiclaw-agent
```

### `platform/jaiclaw-agent/manifests/mgmt/serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jaiclaw-agent
  namespace: jaiclaw-agent
---
# NOTE: ArgoCD API auth uses a bearer TOKEN, not the pod's SA. This
# ServiceAccount is here for the agent's own lifecycle (metrics, logs)
# and for optional read of its own Application status via the K8s API.
# If the agent needs to READ ArgoCD Application CRs (as opposed to
# going through the ArgoCD API), bind the following ClusterRole:
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jaiclaw-agent-argocd-read
rules:
  - apiGroups: [argoproj.io]
    resources: [applications, applicationsets, appprojects]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jaiclaw-agent-argocd-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jaiclaw-agent-argocd-read
subjects:
  - kind: ServiceAccount
    name: jaiclaw-agent
    namespace: jaiclaw-agent
```

### `platform/jaiclaw-agent/manifests/mgmt/externalsecrets.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jaiclaw-agent-tokens
  namespace: jaiclaw-agent
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: onepassword}
  target: {name: jaiclaw-agent-tokens, creationPolicy: Owner}
  data:
    - secretKey: ARGOCD_TOKEN
      remoteRef: {key: jaiclaw-agent-argocd/token}
    - secretKey: JENKINS_USER
      remoteRef: {key: jaiclaw-agent-jenkins/username}
    - secretKey: JENKINS_TOKEN
      remoteRef: {key: jaiclaw-agent-jenkins/token}
    - secretKey: GRAFANA_TOKEN
      remoteRef: {key: jaiclaw-agent-grafana/token}
    - secretKey: MINIO_ACCESS_KEY
      remoteRef: {key: jaiclaw-agent-minio/accessKey}
    - secretKey: MINIO_SECRET_KEY
      remoteRef: {key: jaiclaw-agent-minio/secretKey}
```

### `platform/jaiclaw-agent/manifests/mgmt/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaiclaw-agent
  namespace: jaiclaw-agent
  labels:
    app.kubernetes.io/name: jaiclaw-agent
  annotations:
    # Rolling restart whenever the ExternalSecret contents change.
    # Handles token rotation without needing to manually bounce the pod.
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: jaiclaw-agent
  template:
    metadata:
      labels:
        app.kubernetes.io/name: jaiclaw-agent
    spec:
      serviceAccountName: jaiclaw-agent
      containers:
        - name: agent
          # Replace with your actual jaiclaw agent image
          image: ghcr.io/glawson6/jaiclaw-agent:0.1.0
          imagePullPolicy: IfNotPresent
          env:
            # In-cluster endpoints (no ingress traversal)
            - name: ARGOCD_URL
              value: "http://argocd-server.argocd.svc.cluster.local"
            - name: JENKINS_URL
              value: "http://jenkins.jenkins.svc.cluster.local:8080"
            - name: GRAFANA_URL
              value: "http://monitoring-grafana.monitoring.svc.cluster.local"
            - name: PROMETHEUS_URL
              value: "http://kps-prometheus.monitoring.svc.cluster.local:9090"
            - name: MINIO_URL
              value: "http://minio.minio.svc.cluster.local:9000"
          envFrom:
            - secretRef:
                name: jaiclaw-agent-tokens
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {cpu: "1",  memory: 512Mi}
          # Health probes assume the agent exposes /healthz on :8080.
          # Adjust to whatever the jaiclaw agent actually serves.
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 30
            failureThreshold: 3
```

### `argocd/clusters/mgmt/jaiclaw-agent.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mgmt-jaiclaw-agent
  namespace: argocd
  annotations:
    # Wave 5+ so cert-manager, ingress, ESO, MinIO, Jenkins, and
    # monitoring have all landed. Wave 6 leaves room for future
    # workloads that need to sit between monitoring and this.
    argocd.argoproj.io/sync-wave: "6"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform            # needs cluster-scoped RBAC
  source:
    repoURL: 'https://github.com/glawson6/taptech-gitops.git'
    targetRevision: main
    path: platform/jaiclaw-agent/manifests/mgmt
  destination:
    name: in-cluster
    namespace: jaiclaw-agent
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

## Step 5 — Commit, push, verify

```bash
git add platform/jaiclaw-agent/ argocd/clusters/mgmt/jaiclaw-agent.yaml
git commit -m "jaiclaw-agent: initial mgmt cluster deployment

In-cluster agent that reads ArgoCD Application state, drives Jenkins
builds, queries Grafana/Prometheus, and moves objects to/from MinIO.
All auth via ExternalSecrets from the taptech-mgmt vault. No public
ingress -- runs east-west only."
git push

# Kick reconciliation (or wait ~3 min)
kubectl --context taptech-mgmt -n argocd annotate application root \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl --context taptech-mgmt -n argocd patch application root \
  --type merge -p '{"operation":{"sync":{}}}'

# Watch the new Application appear
kubectl --context taptech-mgmt -n argocd get application mgmt-jaiclaw-agent -w
```

Expected timeline (fresh Application creation): ~2 min to root sync
+ ~1 min for the ExternalSecret to resolve + ~30s for the pod to
start. Green in about 4 minutes.

## Step 6 — Verify the agent can reach each endpoint

```bash
POD=$(kubectl --context taptech-mgmt -n jaiclaw-agent get pod \
  -l app.kubernetes.io/name=jaiclaw-agent -o jsonpath='{.items[0].metadata.name}')

# ArgoCD reachable?
kubectl --context taptech-mgmt -n jaiclaw-agent exec $POD -- \
  curl -sf -H "Authorization: Bearer $ARGOCD_TOKEN" \
  http://argocd-server.argocd.svc.cluster.local/api/v1/applications | head

# Jenkins reachable?
kubectl --context taptech-mgmt -n jaiclaw-agent exec $POD -- \
  curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" \
  http://jenkins.jenkins.svc.cluster.local:8080/api/json | head

# Grafana reachable?
kubectl --context taptech-mgmt -n jaiclaw-agent exec $POD -- \
  curl -sf -H "Authorization: Bearer $GRAFANA_TOKEN" \
  http://monitoring-grafana.monitoring.svc.cluster.local/api/health

# MinIO reachable (requires an S3-speaking client; not curl)?
# In the agent container, use aws-cli or mc:
kubectl --context taptech-mgmt -n jaiclaw-agent exec $POD -- \
  mc alias set local http://minio.minio.svc.cluster.local:9000 \
    "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" && \
  kubectl --context taptech-mgmt -n jaiclaw-agent exec $POD -- \
  mc ls local/
```

If any of these return non-2xx, check the ExternalSecret status
(`kubectl -n jaiclaw-agent get externalsecrets`) and the vault item.

## Step 7 — Observability

The agent inherits monitoring from the platform: `kps-prometheus`
scrapes any Pod with a Prometheus `podmonitor` label. If the agent
exposes metrics on `:8080/metrics`, add:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: jaiclaw-agent
  namespace: jaiclaw-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: jaiclaw-agent
  podMetricsEndpoints:
    - port: http
      path: /metrics
      interval: 30s
```

Grafana finds this automatically once the PodMonitor is applied.

## Common gotchas

- **ArgoCD server serves HTTP internally** (we set
  `server.insecure: true`). Use `http://argocd-server.argocd.svc...`,
  not `https`. If you use `https` on the internal port you'll get a
  TLS handshake error.
- **Jenkins requires a crumb for POST requests** (CSRF protection).
  Client libraries handle this; if you're using raw curl for a POST
  you need to fetch `/crumbIssuer/api/json` first.
- **MinIO requires AWS SigV4 signing** for any authenticated call.
  `curl` alone won't work; use `mc`, `aws s3`, or an SDK.
- **Reloader restart on token rotation** is triggered by the
  annotation on the Deployment (not the Secret) and by the K8s
  Secret's content changing. Both conditions must hold. If the vault
  item is rotated but the ExternalSecret hasn't reconciled yet
  (up to `refreshInterval: 1h`), the pod won't restart until the
  Secret content actually changes.
- **Cluster DNS zone is `cluster.local`.** If you migrate to a
  cluster with a different zone (some managed K8s services rewrite
  this), update the endpoint URLs.

## Related docs

- **`docs/architecture.md`** — the tier diagram + wave table.
- **`docs/mgmt-ui-inventory.md`** — what each existing mgmt app
  serves, ingress hostnames, allowlist config.
- **`docs/secrets.md`** — full 1Password → ESO → K8s Secret flow.
- **`docs/what-went-wrong.md`** — the eleven bootstrap defects that
  are already fixed. Reading this before adding a new component will
  save you re-discovering the same traps.
