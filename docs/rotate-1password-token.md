# Rotating the 1Password service-account token

Every cluster has one credential that cannot come from git: the
1Password service-account token that lets External Secrets Operator
(ESO) authenticate to the vault. Everything else derives from it.

This runbook rotates it without downtime.

## Why rotate

- Best practice: bounded credential lifetime limits blast radius.
- Compliance: many frameworks (SOC 2, PCI) mandate periodic rotation.
- Compromise response: rotate immediately if the token is ever
  exposed (accidentally committed, logged, screen-shared, pasted into
  an LLM, etc.).

Default cadence: **every 90 days** unless organizational policy
differs. Current token was created **~2026-08-15**; next rotation due
**~2026-11-13**.

## Effect on the cluster

- **During rotation:** ESO caches secrets for `refreshInterval`
  (typically 1h). Existing K8s Secrets keep working. New/refreshing
  ExternalSecrets briefly fail to reconcile while the token is
  invalid.
- **If the token is dead longer than any workload's cached-secret
  window:** pods restart, mount the (unchanged) K8s Secret, and keep
  running. No pods die from token expiry alone.
- **Reloader:** whenever a K8s Secret content actually changes, all
  workloads with `reloader.stakater.com/auto: "true"` restart to pick
  it up. Rotation of the ESO token itself doesn't change any managed
  Secret's content, so no restarts fire.

Zero user-visible impact if done in <1h.

## Prerequisites

- Access to the 1Password Business account that owns the
  `taptech-mgmt` vault.
- `kubectl` context for each cluster whose token is being rotated.
  This runbook uses `taptech-mgmt`; extend to `taptech-prod` etc. by
  repeating the whole thing per cluster + vault.

## The procedure

### 1. Verify what you're rotating

```bash
# On your workstation
kubectl --context taptech-mgmt -n external-secrets get secret onepassword-token \
  -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
```

Note the age. If it's less than 30 days old and you have no compromise
suspicion, skip and come back later.

### 2. Create the new token in 1Password

**Do NOT delete the old one yet.** They coexist briefly.

1. 1Password web UI → **Integrations → Directory → Service Accounts →
   `taptech-mgmt-eso`** (or whatever the service account is named).
2. **Create new access token** (or "New token" / "Rotate" depending on
   1Password's current UI). Same vault permissions (read on
   `taptech-mgmt`).
3. **Set expiration**: 90 days from today.
4. **Copy the new token immediately** — it displays exactly once. Note
   its first 8 characters somewhere so you can spot it in the K8s
   Secret later.

### 3. Update the K8s Secret in-place

```bash
# On your workstation, with the new ops_... token in your clipboard
read -r -s -p "new OP_TOKEN: " NEW_TOKEN; echo

kubectl --context taptech-mgmt -n external-secrets \
  create secret generic onepassword-token \
    --from-literal=token="$NEW_TOKEN" \
    --dry-run=client -o yaml \
  | kubectl --context taptech-mgmt apply -f -
```

The `--dry-run=client -o yaml | apply -f -` pattern updates the Secret
in place without deleting it (a delete would briefly break every
ExternalSecret referencing it).

Verify the update landed:

```bash
kubectl --context taptech-mgmt -n external-secrets get secret onepassword-token \
  -o jsonpath='{.data.token}' | base64 -d | head -c 8; echo '...'
```

Match against the first-8-chars you noted in step 2.

### 4. Force an ESO refresh to prove the new token works

```bash
# Pick any ExternalSecret to test. jenkins-admin is a good canary
# because it should always be present on mgmt.
kubectl --context taptech-mgmt -n jenkins annotate externalsecret jenkins-admin \
  force-sync=$(date +%s) --overwrite

# Wait a few seconds, then check status
kubectl --context taptech-mgmt -n jenkins get externalsecret jenkins-admin \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
```

Expected: `True secret synced`.

If it errors with anything token-related (`authentication failed`,
`invalid token`), your paste picked up a stray character. Redo step 3.

### 5. Confirm ESO controller sees the new token

```bash
kubectl --context taptech-mgmt -n external-secrets logs deploy/external-secrets \
  --tail=20 2>&1 | grep -iE 'onepassword|token|auth' | tail -5
```

You want to see recent `SecretSynced` events, no `unauthenticated` or
`invalid_grant` errors.

### 6. Revoke the OLD token in 1Password

Only after step 4 confirms the new token works.

1Password web UI → same service account → find the old token in the
tokens list → **Revoke**.

### 7. Update your calendar

Set a reminder for **~85 days from today** to rotate again (5-day buffer
before hard expiry). Ninety days is the ceiling; earlier is fine.

## If something goes wrong

### `SecretSyncedError: unauthenticated`

The new token is wrong (bad paste, truncated, expired) or the service
account's vault permissions were changed. Either:

- Re-paste (step 3), OR
- Fall back to the OLD token if you haven't revoked it yet:
  ```bash
  # you kept the old token secret in a password manager, right?
  read -r -s -p "old OP_TOKEN: " OLD; echo
  kubectl --context taptech-mgmt -n external-secrets \
    create secret generic onepassword-token \
      --from-literal=token="$OLD" \
      --dry-run=client -o yaml \
    | kubectl --context taptech-mgmt apply -f -
  ```

### Token revoked prematurely (both old and new dead)

Create a fresh token in 1Password. Repeat steps 3-6. Some
ExternalSecrets may briefly show `SecretSyncedError` for up to
`refreshInterval` (1h) — that's cosmetic; the K8s Secrets they wrote
are unchanged and workloads keep running.

### Bulk force-sync all ExternalSecrets after rotation

If you want to verify every ExternalSecret picks up the new token:

```bash
kubectl --context taptech-mgmt get externalsecret -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name \
  --no-headers | while read ns name; do
    kubectl --context taptech-mgmt -n "$ns" annotate externalsecret "$name" \
      force-sync=$(date +%s) --overwrite >/dev/null
  done
kubectl --context taptech-mgmt get externalsecret -A -o wide
```

Look for any `STATUS != SecretSynced` in the result.

## Rotating per-cluster tokens

Every cluster registered with ArgoCD has its own 1Password vault and
its own service-account token (see `docs/secrets.md`). Rotate each
independently — they're isolated by design.

For `apps-prod`:
```bash
# 1Password vault taptech-prod, service account taptech-prod-eso
# Same procedure, but --context taptech-prod throughout.
```

## Where the token lives (cheat sheet)

| Location | What | Purpose |
|---|---|---|
| 1Password service account | Source of truth | Create/revoke here first |
| K8s Secret `external-secrets/onepassword-token` | Cache | ESO reads this |
| `ClusterSecretStore/onepassword` | Reference | Points ESO at the Secret |
| `platform/external-secrets/stores/<cluster>/clustersecretstore.yaml` | Git | Declares the vault name; commit-safe |
