# Bootstrapping the management cluster

The runbook for standing up the first management cluster from scratch on a
MicroK8s host. Target used for this walkthrough: **104.225.223.215**, SSH as
`tap@`. Everything in this doc is one-time work; after Step 3, ArgoCD owns the
cluster and future changes are just commits.

Prereqs on your workstation: `kubectl`, `helm`, `ssh`, `scp`, and (optional
but recommended) the [1Password CLI](https://developer.1password.com/docs/cli/)
`op` and the MinIO client `mc`.

Prereqs on the host: MicroK8s already installed (`microk8s status` should
respond), `tap` can `sudo`.

## TL;DR — drive Steps 2–3 from your workstation

If Steps 0 (SSH) and 1 (1Password) are already done, one command runs the
rest:

```bash
HOST=104.225.223.215 OP_TOKEN='ops_...' ./scripts/bootstrap-mgmt.sh
```

It will prompt once for `tap`'s sudo password on the host (hidden). Set
`SUDO_PASS` in the environment to skip that prompt (useful for CI). The
script is idempotent — re-run it and it skips work already done. Read the
rest of this document to understand what it's doing (and to troubleshoot when
something diverges).

---

## Step 0 — SSH access to the host

You need publickey SSH as `tap@104.225.223.215` before anything else works.
If your workstation key is not on the box yet, install it while logged in on
a console:

```bash
# ON the host, as any user with sudo:
echo 'ssh-ed25519 AAAA...your-pubkey... you@host' \
  | sudo tee -a /home/tap/.ssh/authorized_keys > /dev/null
sudo chmod 700 /home/tap/.ssh
sudo chmod 600 /home/tap/.ssh/authorized_keys
sudo chown -R tap:tap /home/tap/.ssh
```

Get your workstation pubkey with `cat ~/.ssh/id_ed25519.pub` (or `id_rsa.pub`).

Test from your workstation (not from the box):

```bash
ssh tap@104.225.223.215 'whoami && hostname'
# expect: tap  <hostname>
```

If it still says `Permission denied (publickey)`, check `sudo tail -50
/var/log/auth.log` on the host for the exact reason.

---

## Step 1 — 1Password vault setup

### 1.1 Create the vault

In the 1Password web/desktop client, on a **Business** account (service
accounts require Business):

1. **New Vault** → name it **exactly** `taptech-mgmt`. The name is hard-coded
   in `platform/external-secrets/stores/mgmt/clustersecretstore.yaml`, so
   anything else will not resolve.
2. Description: *"Management cluster: CI, ArgoCD, Jenkins, Grafana, MinIO.
   Read by ESO on the mgmt cluster only."*

### 1.2 Create the service account

1. **Integrations → Directory → Service Accounts → Create Service Account**.
2. Name: `taptech-mgmt-eso`.
3. Vault access: **read-only** on `taptech-mgmt` **only**.
4. Token expiration: 90 days. Schedule the rotation now — this token is the
   one credential that cannot come from git.
5. Copy the token (`ops_...`) — it shows once. Paste it into `bootstrap.sh`
   in Step 3.

### 1.3 Create the items

Every ExternalSecret's `remoteRef.key` is `<item>/<field>` (see
`docs/secrets.md`). Field labels within a single item **must be unique** or
ESO fails with `found multiple labels with the same key`.

For each row: 1Password → **New Item → API Credential** (the category is
cosmetic; any category works), then add custom fields as listed. Save fields
loose, not inside a section.

| Item | Fields | Consumed by |
|---|---|---|
| `jenkins-admin` | `username` = `admin`<br>`password` = 32-char random | `platform/jenkins/manifests/mgmt/externalsecrets.yaml` |
| `registry-push` | `username` = registry push user<br>`credential` = registry password/token | `platform/jenkins/manifests/mgmt/externalsecrets.yaml` |
| `gitops-repo` | `username` = GitHub user with write on the gitops repo<br>`credential` = GitHub PAT (scope `repo`) | `platform/jenkins/manifests/mgmt/externalsecrets.yaml` |
| `grafana` | `username` = `admin`<br>`password` = 32-char random | `platform/monitoring/manifests/mgmt/externalsecret-grafana.yaml` |
| `minio-root` | `username` = `admin`<br>`password` = 32-char random (**8+ chars, no whitespace**) | `platform/minio/manifests/mgmt/externalsecret.yaml` — the MinIO chart reads it as `existingSecret` |
| `minio-jenkins` | `username` = `jenkins`<br>`password` = 32-char random | Step 4 (Jenkins → MinIO wiring) |

### 1.4 Verify with the CLI (optional)

```bash
export OP_SERVICE_ACCOUNT_TOKEN='ops_...'
op vault list                              # taptech-mgmt should appear
op item list --vault taptech-mgmt          # 6 items listed
op item get minio-root --vault taptech-mgmt --format json \
  | jq '.fields[].label'
```

Item/field mismatches surface later as `SecretSyncedError` on the
corresponding ExternalSecret; catching them here saves the round-trip.

---

## Step 2 — Host prep and kubeconfig retrieval

### 2.1 Run prep on the box

The script is idempotent. `sudo` inside the SSH session needs a TTY (`-t`)
and one authentication at the top (`sudo bash -s`):

```bash
# From your workstation, current dir = repo root
ssh -t tap@104.225.223.215 'sudo -v'                             # cache sudo
ssh -t tap@104.225.223.215 'sudo bash -s' < scripts/prep-microk8s.sh
```

Expected tail:

```
MicroK8s is ready. Kubeconfig written to /tmp/microk8s-config on this host.
```

If `tap` has no sudo password, either set one (`sudo passwd tap` from the
console) or add a NOPASSWD rule scoped to the script's commands:

```bash
# on the host, from console
sudo visudo -f /etc/sudoers.d/tap-microk8s
# add exactly this line:
tap ALL=(ALL) NOPASSWD: /snap/bin/microk8s, /usr/sbin/usermod, /bin/chown
```

### 2.2 Retrieve the kubeconfig

```bash
scp tap@104.225.223.215:/tmp/microk8s-config /tmp/microk8s-config
```

### 2.3 Rewrite the server URL

MicroK8s emits `https://127.0.0.1:16443`, unreachable from your workstation.
Point it at the host:

```bash
sed -i.bak 's|server: https://127.0.0.1:16443|server: https://104.225.223.215:16443|' \
  /tmp/microk8s-config
```

Confirm port `16443` is reachable:

```bash
nc -vz 104.225.223.215 16443
```

If it's firewalled, either open it or tunnel:

```bash
ssh -N -L 16443:127.0.0.1:16443 tap@104.225.223.215 &
# then in the kubeconfig: server: https://127.0.0.1:16443
```

If `kubectl` later complains the cert doesn't match the IP, either regenerate
the API cert with the IP as a SAN (`sudo microk8s refresh-certs -e
server.crt` on the host, then re-fetch the kubeconfig) or as a **temporary**
workaround add `insecure-skip-tls-verify: true` under the cluster stanza.

### 2.4 Merge into your local kubeconfig

```bash
KUBECONFIG=~/.kube/config:/tmp/microk8s-config \
  kubectl config view --flatten > ~/.kube/config.new
mv ~/.kube/config.new ~/.kube/config
chmod 600 ~/.kube/config

kubectl config rename-context microk8s taptech-mgmt
kubectl config use-context taptech-mgmt

kubectl get nodes                          # expect Ready
kubectl get storageclass                   # microk8s-hostpath present
```

The built-in `microk8s-hostpath` StorageClass is separate from the
`taptech-standard` one this repo defines. ArgoCD creates `taptech-standard`
during bootstrap; that's the name every chart in this repo requests.

---

## Step 3 — Bootstrap

### 3.1 Confirm the target

```bash
kubectl config current-context             # must print: taptech-mgmt
kubectl cluster-info
```

### 3.2 Run bootstrap

```bash
./scripts/bootstrap.sh
```

Prompts:

1. `is that the MANAGEMENT cluster? [y/N]` — type `y` (the line above shows
   which context; verify it says `taptech-mgmt` first).
2. `1Password service account token ... token:` — paste the `ops_...` token
   from Step 1.2. Input is hidden.

Then it installs ArgoCD via Helm (chart 7.7.11) and applies
`argocd/bootstrap/root.yaml`. Expect ~2 minutes for Helm; then ~10–15 minutes
for ArgoCD to reconcile everything else.

### 3.3 Watch reconciliation

```bash
kubectl -n argocd get pods -w
# Ctrl-C when argocd-server, argocd-repo-server, argocd-application-controller
# are 1/1 Running.

kubectl -n argocd get applications -w
```

Expected sync-wave order (from `argocd/clusters/mgmt/*.yaml`):

```
wave -10  mgmt-storage             creates taptech-standard StorageClass
wave  -8  mgmt-external-secrets    ESO CRDs + operator
wave  -8  mgmt-reloader            restarts pods on Secret changes
wave  -7  mgmt-secret-stores       ClusterSecretStore 'onepassword'
wave  -5  mgmt-cert-manager
wave  -5  mgmt-jenkins-agents
wave  -3  mgmt-ingress-nginx
wave  -3  mgmt-external-dns
wave   0  mgmt-argocd              ArgoCD self-manages from here
wave   1  mgmt-minio               reads minio-root ExternalSecret
wave   2  mgmt-jenkins             reads jenkins-admin ExternalSecret
wave   5  mgmt-monitoring          Grafana reads grafana ExternalSecret
```

Every Application should end at `Synced / Healthy`.

**Common failures**:

| Symptom | Cause | Fix |
|---|---|---|
| `SecretSyncedError` on an ExternalSecret | 1Password item/field name mismatch | Fix in 1Password, then `kubectl -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite` |
| MinIO `CrashLoopBackOff`, log: `Access Key length should be at least 3` | `minio-root/username` too short | Fix in 1Password, force-sync, delete the pod |
| MinIO PVC stuck `Pending` | StorageClass mismatch | `kubectl get storageclass taptech-standard` — should exist; if not, `mgmt-storage` app failed |
| Jenkins pod `CreateContainerConfigError` | `jenkins-admin` Secret missing | Check the `mgmt-jenkins` app synced *after* ESO (it should — wave 2 vs -8) |

### 3.4 Retrieve the ArgoCD admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### 3.5 Smoke-test MinIO

```bash
kubectl -n minio port-forward svc/minio 9000:9000 &

mc alias set local http://127.0.0.1:9000 \
  "$(kubectl -n minio get secret minio-root -o jsonpath='{.data.rootUser}' | base64 -d)" \
  "$(kubectl -n minio get secret minio-root -o jsonpath='{.data.rootPassword}' | base64 -d)"

mc ls local/                               # jenkins-artifacts jenkins-backups mgmt-general
mc admin info local

kill %1                                    # stop port-forward
```

---

## Step 4 — Wire Jenkins to MinIO (follow-up commit)

Jenkins boots without MinIO — this step is optional but recommended if you
want pipelines to publish artifacts / backups to the object store. Do it
**after** Step 3 is fully green.

### 4.1 Add plugins

Edit `platform/jenkins/values.yaml`, extend `controller.installPlugins`:

```yaml
  installPlugins:
    - kubernetes:latest
    - workflow-aggregator:latest
    - git:latest
    - configuration-as-code:latest
    - credentials-binding:latest
    - job-dsl:latest
    - aws-credentials:latest     # adds "AWS Credentials" type
    - pipeline-aws:latest        # withAWS + s3Upload / s3Download
```

### 4.2 Register the MinIO credential in JCasC

Same file, extend `controller.JCasC.configScripts`:

```yaml
      minio: |
        credentials:
          system:
            domainCredentials:
              - credentials:
                  - aws:
                      scope: GLOBAL
                      id: minio-jenkins
                      description: "MinIO S3 credentials (mgmt cluster)"
                      accessKey: ${minio-jenkins-accessKey}
                      secretKey: ${minio-jenkins-secretKey}
```

`${minio-jenkins-accessKey}` and `${minio-jenkins-secretKey}` are JCasC
secret refs — Jenkins reads them from env vars of the same name, injected
next.

### 4.3 Mount the K8s Secret into the controller

Same file, add under `controller`:

```yaml
  additionalExistingSecrets:
    - name: minio-jenkins
      keyName: accessKey
    - name: minio-jenkins
      keyName: secretKey
```

The Jenkins chart projects each entry into an env var named
`<secretName>-<keyName>` — matching the JCasC refs above.

### 4.4 Move the `minio-jenkins` ExternalSecret into the jenkins namespace

Secrets don't cross namespaces. The `minio-jenkins` ExternalSecret currently
lives in `platform/minio/manifests/mgmt/externalsecret.yaml` (namespace
`minio`) but Jenkins runs in `jenkins`. Move it.

**Append to `platform/jenkins/manifests/mgmt/externalsecrets.yaml`**:

```yaml
---
# MinIO S3 credentials for Jenkins pipelines. Provisioned in this namespace
# so the controller's additionalExistingSecrets can project it as env vars.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: minio-jenkins
  namespace: jenkins
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: onepassword}
  target: {name: minio-jenkins, creationPolicy: Owner}
  data:
    - secretKey: accessKey
      remoteRef: {key: minio-jenkins/username}
    - secretKey: secretKey
      remoteRef: {key: minio-jenkins/password}
```

**Delete** the `minio-jenkins` block from
`platform/minio/manifests/mgmt/externalsecret.yaml`. MinIO itself only needs
`minio-root`.

### 4.5 Commit and let ArgoCD redeploy

```bash
git add platform/jenkins/values.yaml \
        platform/jenkins/manifests/mgmt/externalsecrets.yaml \
        platform/minio/manifests/mgmt/externalsecret.yaml
git commit -m "jenkins: wire MinIO as S3 artifact store"
git push
# ArgoCD picks it up within ~3 min, or force it:
#   argocd app sync mgmt-jenkins
# Reloader restarts the Jenkins pod when the Secret content changes.
```

### 4.6 Verify

```bash
kubectl -n jenkins exec deploy/jenkins -c jenkins -- printenv | grep -i minio
# both env vars present

# In the Jenkins UI: Manage Jenkins → Credentials → System → Global
# → 'minio-jenkins' listed as AWS Credentials type.
```

### 4.7 Pipeline usage (reference, not for this repo)

```groovy
withAWS(credentials: 'minio-jenkins',
        endpointUrl: 'http://minio.minio.svc.cluster.local:9000',
        region: 'us-east-1') {              // required by AWS SDK, value ignored
  s3Upload(bucket: 'jenkins-artifacts',
           file: 'target/app.jar',
           path: "${env.JOB_NAME}/${env.BUILD_NUMBER}/app.jar")
}
```

---

## What you have when you're done

- MicroK8s on 104.225.223.215 running dns, hostpath-storage, ingress, rbac.
- ArgoCD in the `argocd` namespace, self-managed from this repo.
- Every platform component from `argocd/clusters/mgmt/` reconciled `Synced /
  Healthy`.
- MinIO with three pre-created buckets (`jenkins-artifacts`,
  `jenkins-backups`, `mgmt-general`), root creds sourced from 1Password.
- Jenkins with admin creds from 1Password; optionally (Step 4) wired to
  MinIO as an S3 artifact store.
- Grafana ready to be exposed once cert-manager + ingress are configured for
  a public host.

## Next things

- Register an application cluster: follow `docs/adding-a-cluster.md`. This
  document does not create app clusters; it stands up the mgmt cluster the
  runbook assumes exists.
- Configure DNS + TLS for the ingress hosts (Jenkins, Grafana, MinIO
  console). Depends on your `platform/external-dns/` provider.
- Rotate the 1Password service account token before the 90-day expiry.
