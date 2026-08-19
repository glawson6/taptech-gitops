# Ingress + TLS for management UIs

Every management-cluster UI is behind ingress-nginx with a
cert-manager-issued TLS cert. All hostnames are subdomains of
`taptech.net` pointing at the mgmt cluster's public IP.

## Hostname → target map

| Host | Serves | Namespace |
|---|---|---|
| `argocd.taptech.net` | Argo CD UI + API | `argocd` |
| `jenkins.taptech.net` | Jenkins controller | `jenkins` |
| `grafana.taptech.net` | Grafana dashboards | `monitoring` |
| `minio.taptech.net` | MinIO S3 API (for external clients) | `minio` |
| `minio-console.taptech.net` | MinIO web console | `minio` |

All resolve to the mgmt cluster's public IP: **104.225.223.215**.

## DNS: what you need to create

Five `A` records at your DNS provider (or a single wildcard if that's
easier and matches your security posture):

```
argocd.taptech.net.         A     104.225.223.215
jenkins.taptech.net.        A     104.225.223.215
grafana.taptech.net.        A     104.225.223.215
minio.taptech.net.          A     104.225.223.215
minio-console.taptech.net.  A     104.225.223.215
```

Or one wildcard (simpler, matches any future subdomain):

```
*.taptech.net.              A     104.225.223.215
```

TTL 300s (5 min) is fine while you're iterating.

**Verify with dig:**

```bash
for h in argocd jenkins grafana minio minio-console; do
  printf '%-32s ' "$h.taptech.net"
  dig +short "$h.taptech.net"
done
# Expect: 104.225.223.215 on every line
```

## TLS: staging then prod

cert-manager is configured with **two** ClusterIssuers:

- `letsencrypt-staging` — Let's Encrypt's staging endpoint. Fake CA
  (browsers warn), but no rate limits. Use while iterating.
- `letsencrypt-prod` — real, browser-trusted certs. **Aggressive
  rate limits**: 50 certificates per registered domain per week.
  Hitting it locks you out for 7 days. See
  https://letsencrypt.org/docs/rate-limits/.

**Every Ingress in this repo starts on `letsencrypt-staging`.** After
DNS is confirmed and the staging cert issues successfully, promote to
prod:

```bash
# From the repo root, atomic swap across every ingress that uses staging
grep -rl 'letsencrypt-staging' platform/ \
  | xargs sed -i.bak 's|letsencrypt-staging|letsencrypt-prod|g'
find platform -name '*.bak' -delete
git diff  # sanity check
git add -A && git commit -m "ingress: promote all UIs to letsencrypt-prod"
git push
```

Force-refresh cert-manager to reissue against the new issuer:

```bash
# Delete the staging Order + Certificate so cert-manager reissues fresh
kubectl --context taptech-mgmt get certificate -A \
  | grep -E '(argocd|jenkins|grafana|minio)' \
  | awk '{print $1, $2}' \
  | while read ns name; do
      kubectl --context taptech-mgmt -n "$ns" delete certificate "$name"
    done
# cert-manager auto-recreates them from the Ingress annotations
```

Watch:

```bash
kubectl --context taptech-mgmt get certificate -A -w
```

Expect `READY: True` on each within a couple minutes (HTTP-01 challenge
requires the host to be reachable on port 80).

## How the pieces fit

```
Browser
   │  https://argocd.taptech.net
   ▼
DNS A record → 104.225.223.215
   │
   ▼
ingress-nginx-controller (DaemonSet, hostPort 80/443)
   │  reads Ingress with tls.secretName: argocd-tls
   │  terminates TLS using cert-manager-issued cert
   │  forwards HTTP to argocd-server:80
   ▼
argocd-server pod (configs.params.server.insecure: true → serves HTTP)
```

cert-manager watches Ingresses annotated with
`cert-manager.io/cluster-issuer: <issuer>` and:
1. Creates a `Certificate` resource matching the Ingress TLS block.
2. Requests a cert from Let's Encrypt via HTTP-01 challenge.
3. Let's Encrypt hits `http://<host>/.well-known/acme-challenge/<token>`.
4. ingress-nginx routes that path to cert-manager's solver pod.
5. Solver responds with the token; Let's Encrypt issues the cert.
6. cert-manager writes it to `Secret/<secretName>` in the same namespace.
7. Ingress-nginx picks up the Secret and starts serving TLS.

If step 3 fails, the ClusterIssuer stays `Ready=False` with a message
like `no such host` — that's your DNS not being propagated yet.

## First-time bring-up sequence

1. **Create DNS records** (above).
2. **Wait for DNS to propagate**: `dig +short` returns the IP from a
   fresh resolver.
3. **Ingress manifests are already in git; ArgoCD picks them up on the
   next sync (~3 min) or via**:
   ```bash
   for app in mgmt-argocd mgmt-jenkins mgmt-monitoring mgmt-minio; do
     kubectl --context taptech-mgmt -n argocd patch application $app \
       --type merge -p '{"operation":{"sync":{}}}'
   done
   ```
4. **Watch cert-manager**:
   ```bash
   kubectl --context taptech-mgmt get certificate -A
   ```
   Once every `READY=True`, open the UIs in a browser. You'll get a
   cert warning (staging CA) — expected.
5. **Promote to prod**: run the sed + delete-certificate steps above.

## Troubleshooting

### `Certificate` stays `READY: False`

```bash
kubectl --context taptech-mgmt -n <ns> describe certificate <name>
```

Common causes:
- **DNS not resolving**: `dig +short host` returns nothing. Fix DNS.
- **Port 80 not reachable from Internet**: HTTP-01 challenge fails.
  Check `curl http://<host>/` returns anything (even 404 is fine —
  just proves the ingress got the request).
- **Rate-limited on prod**: check the certificate's message for
  `too many certificates`. Wait a week, or use staging until issue is
  resolved.

### Ingress works but browser shows `Not Secure` on prod cert

You promoted the git manifest but cert-manager didn't reissue. Delete
the `Certificate` (see promote section) — cert-manager will recreate
against the new issuer.

### `502 Bad Gateway` on the ingress

Backend service isn't ready. `kubectl -n <ns> get pods` to check. If
you just applied Ingress but the backend Deployment isn't Ready yet,
you'll see this transiently.

### Grafana / Jenkins login redirects loop

Almost always a scheme mismatch — the upstream service thinks it's
serving HTTPS while the ingress is terminating it. For ArgoCD we set
`server.insecure: true` explicitly; if you enable ingress on a service
we haven't wired here, check for a similar setting.
