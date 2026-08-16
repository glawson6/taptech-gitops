# Secrets

External Secrets Operator with the 1Password SDK provider. No Connect server.

## The model

Nothing encrypted is committed. What lives in git is a *reference* — vault, item,
field — and ESO resolves it into a Kubernetes Secret inside the cluster. The
reference is safe to read in a pull request, and rotating a value in 1Password
propagates without a commit.

One credential per cluster cannot work this way: the 1Password service account
token that lets ESO authenticate at all. It is created by hand, once, per
cluster. Everything else derives from it.

## Vaults

| Vault | Holds | Read by |
|---|---|---|
| `taptech-mgmt` | Jenkins admin, registry **push**, GitOps PAT, Grafana admin | management cluster |
| `taptech-prod` | registry **pull**, application runtime secrets | apps-prod cluster |

Each cluster has its own service account, scoped to its own vault. The isolation
is physical: the apps cluster has no token for the management vault, so it cannot
read the credential that can push images or commit to this repo.

Every cluster names its store `onepassword`, so an `ExternalSecret` can reference
the same store regardless of which cluster it lands on.

## Creating a service account token

In 1Password: create a service account granted read access to exactly one vault.
Then, against the cluster it belongs to:

    kubectl create namespace external-secrets
    kubectl -n external-secrets create secret generic onepassword-token \
      --from-literal=token='ops_...'

Service accounts require a 1Password Business plan.

## Item naming

`remoteRef.key` is `<item>/<field>`, so `registry-pull/credential` means the
field `credential` on the item `registry-pull`. Field labels must be unique
within an item — two fields both labelled `password` will fail with
`found multiple labels with the same key`.

## Rotation actually taking effect

Secrets mounted as **volumes** refresh in place. Secrets consumed as
**environment variables** do not — they are fixed when the container starts.
Our deployments use env vars, so without help a rotated credential updates the
Kubernetes Secret, ESO reports success, everything reads green, and the running
pods keep the old value indefinitely.

That is why Reloader is installed and why workloads carry
`reloader.stakater.com/auto: "true"`. Remove the annotation to opt a workload
out; do it knowingly.
