# Adding a cluster or an environment

The K3s cluster in the architecture diagram is not built yet. This is what it
takes when it is.

## Adding an application cluster

1. Register it. The name is the contract — nothing in git holds an API URL.

       argocd cluster add <context> --name apps-k3s

2. Create its 1Password vault (`taptech-k3s`) and a service account scoped to
   that vault only. Then create the bootstrap token secret **on that cluster**:

       kubectl --context <ctx> create namespace external-secrets
       kubectl --context <ctx> -n external-secrets create secret generic onepassword-token \
         --from-literal=token='<service account token>'

   This is the one credential that cannot come from git.

3. Copy `argocd/clusters/apps-prod/` to `argocd/clusters/apps-k3s/`, then in each
   file change `destination.name`, the `metadata.name` prefix, and the
   `path: platform/<component>/manifests/<cluster>` suffix.

4. Add per-cluster values: `platform/<component>/clusters/apps-k3s.yaml` for
   every Helm component. **Give external-dns a unique `txtOwnerId`** — see the
   note in `platform/external-dns/clusters/mgmt.yaml` for what happens otherwise.

5. Add the environment to the list in `argocd/appsets/applications.yaml`:

       - env: staging
         cluster: apps-k3s
         namespace: taptech-staging
         autoSync: "true"

6. Add the destination to the `applications` AppProject, and create
   `applications/<svc>/overlays/staging/` for each service that should run there.

## Adding an environment on an existing cluster

Steps 5 and 6 only. Namespaces separate the environments; the cluster is shared.

## Repurposing a cluster

If a production cluster is ever demoted to a lower environment, rotate every
secret it has held. It retains credentials it should no longer have, and access
to a non-production cluster is looser by design. That is a rotation exercise,
not a config change, and nothing in this repo will remind you to do it.
