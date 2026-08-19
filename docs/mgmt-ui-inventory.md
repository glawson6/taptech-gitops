# Management cluster: application inventory + UI access

Every ArgoCD `Application` under `argocd/clusters/mgmt/` in one place,
with what it does, whether humans reach it directly, and how access is
restricted.

## The 12 mgmt Applications at a glance

| # | Application | Kind | External URL | UI? | Purpose |
|---|---|---|---|---|---|
| 1 | `mgmt-storage` | StorageClass CR | — | — | Declares `taptech-standard` StorageClass (default). Backing store for every PVC (Jenkins, MinIO, Prometheus, Grafana). |
| 2 | `mgmt-external-secrets` | Helm chart | — | — | ESO controller + admission webhook + cert-controller. Watches `ExternalSecret` CRs and writes their resolved values into `Secret` objects. |
| 3 | `mgmt-secret-stores` | Raw manifest | — | — | `ClusterSecretStore/onepassword` — tells ESO where to read from. |
| 4 | `mgmt-reloader` | Helm chart | — | — | Stakater Reloader. Restarts Deployments/StatefulSets whose consumed Secret/ConfigMap content changes. |
| 5 | `mgmt-cert-manager` | Helm chart + `ClusterIssuer`s | — | — | Issues TLS certs for every other mgmt Ingress. Two ClusterIssuers: `letsencrypt-staging` and `letsencrypt-prod`. |
| 6 | `mgmt-ingress-nginx` | Helm chart | — | — | ingress-nginx controller. DaemonSet binding host ports 80/443. Fronts every mgmt UI. |
| 7 | `mgmt-jenkins-agents` | Raw manifests | — | — | Namespace + ServiceAccount + RBAC + ExternalSecrets for Jenkins build agents. Pods spawn on demand. |
| 8 | `mgmt-argocd` | Helm chart | **`argocd.taptech.net`** | ✅ | ArgoCD itself — the GitOps engine. Manages every other Application on every cluster. |
| 9 | `mgmt-minio` | Helm chart | **`minio.taptech.net`** (S3 API)<br>**`minio-console.taptech.net`** (browser UI) | ✅ | S3-compatible object storage. Two ingresses: one for the S3 API, one for the admin console. |
| 10 | `mgmt-jenkins` | Helm chart | **`jenkins.taptech.net`** | ✅ | CI/CD. Web UI + REST API on the same port. |
| 11 | `mgmt-monitoring` | Helm chart (`kube-prometheus-stack`) | **`grafana.taptech.net`** | ✅ | Prometheus + Alertmanager + Grafana. Only Grafana is exposed externally; Prometheus & Alertmanager stay in-cluster. |
| 12 | `root` | ArgoCD Application | — | — | Bootstrap Application applied by hand once (`bootstrap.sh`). Discovers and applies all other mgmt-* Applications from `argocd/clusters/mgmt/`. |

## UI vs API count

- **4 apps have browser UIs**: ArgoCD, Jenkins, Grafana, MinIO Console.
- **5 external hostnames** (because MinIO exposes both S3 API + Console).
- **1 hostname is machine-only**: `minio.taptech.net` is the S3 API, used by Jenkins pipelines and external CI. No browser UI.
- **7 apps have no external endpoint**: storage, external-secrets, secret-stores, reloader, cert-manager, ingress-nginx, jenkins-agents. These are controllers that watch Kubernetes resources; no user ever hits them directly.

## Internal-only endpoints (kubectl port-forward)

These exist and are useful but aren't exposed publicly:

| Service | Namespace | Port | What |
|---|---|---|---|
| `prometheus-kps-prometheus` | `monitoring` | 9090 | PromQL browser + query API. Grafana already queries it internally; port-forward for ad-hoc debugging. |
| `alertmanager-kps-alertmanager` | `monitoring` | 9093 | Alertmanager UI for silences/inhibits. |
| `argocd-server` gRPC | `argocd` | 443 | Second `argocd` CLI login path (bypasses the ingress). |
| `minio` internal | `minio` | 9000 | The S3 API on its ClusterIP. Cross-cluster clients use this rather than the ingress. |

Reach any of them:

```bash
kubectl --context taptech-mgmt -n monitoring port-forward svc/prometheus-kps-prometheus 9090:9090
# then browse http://localhost:9090
```

## IP allowlist (restricting who can reach the UIs)

All four browser-facing ingresses (**ArgoCD, Jenkins, Grafana, MinIO
Console**) are configured with an `nginx.ingress.kubernetes.io/whitelist-source-range`
annotation. As shipped, each has the placeholder value
`REPLACE-WITH-YOUR-IP/32` — the ingress will 403 anyone until you set
your actual IP.

**MinIO's S3 API (`minio.taptech.net`) intentionally has NO allowlist**
— external CI / tooling that pushes artifacts uses it, and access is
controlled by credentials (accessKey/secretKey pair, per bucket).

### Setting your IP

Get your public IP:

```bash
curl -s ifconfig.me; echo
```

Update the four values files with your CIDR:

```bash
# From the repo root
YOUR_IP=1.2.3.4   # from ifconfig.me
find platform/argocd platform/jenkins platform/monitoring platform/minio \
  -name '*.yaml' -exec \
    sed -i.bak "s|REPLACE-WITH-YOUR-IP/32|${YOUR_IP}/32|g" {} \;
find platform -name '*.bak' -delete
git diff  # sanity check
git add -A && git commit -m "ingress: allowlist admin UIs to $YOUR_IP/32"
git push
```

ArgoCD reconciles within ~3 min, or force with:

```bash
for app in mgmt-argocd mgmt-jenkins mgmt-monitoring mgmt-minio; do
  kubectl --context taptech-mgmt -n argocd patch application $app \
    --type merge -p '{"operation":{"sync":{}}}'
done
```

### Adding more CIDRs

Comma-separated inside the same annotation:

```yaml
nginx.ingress.kubernetes.io/whitelist-source-range: "1.2.3.4/32,5.6.7.0/24,10.0.0.0/8"
```

### If Jenkins needs webhooks from GitHub

GitHub publishes their outbound IPs at
https://api.github.com/meta — see `.hooks`. If you enable a webhook,
either:

- Add the GitHub `.hooks` CIDRs to Jenkins's allowlist annotation
  (safest but the list changes; you'll need occasional updates), OR
- Remove the allowlist annotation from Jenkins and rely on the
  built-in webhook signature validation

### Removing the allowlist entirely (make a UI public)

Delete the annotation from the relevant values file. Then ArgoCD sync
picks it up. Auth (ArgoCD admin, Jenkins admin, Grafana admin) is your
only defense at that point.

### Testing the allowlist works

From an allowed IP: `curl -Iv https://argocd.taptech.net` → `HTTP 200`.

From a blocked IP (e.g., a phone on cellular data): same request →
`HTTP 403 Forbidden`. Nginx logs it.

## Related docs

- **`docs/ingress-and-tls.md`** — DNS records, letsencrypt-staging →
  prod promotion, HTTP-01 challenge flow.
- **`docs/architecture.md`** — the mgmt vs apps cluster split rationale.
- **`docs/secrets.md`** — how ExternalSecret / ClusterSecretStore /
  1Password fit together.
- **`docs/rotate-1password-token.md`** — ESO token rotation runbook.
- **`docs/what-went-wrong.md`** — postmortem of the bootstrap session.
