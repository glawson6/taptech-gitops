# taptech-gitops

Single source of truth for everything running in TapTech Kubernetes clusters.
Argo CD reconciles this repo; nothing is applied by hand.

## Clusters

| Cluster | Argo CD name | Runs |
|---|---|---|
| Management | `in-cluster` | Argo CD, Jenkins, Grafana, platform components |
| Applications (MicroK8s) | `apps-prod` | The four business services + their platform components |
| K3s | — | Not built yet. See `docs/adding-a-cluster.md` |

Destinations are referenced by **cluster name**, never by API URL. The endpoint
lives in the Argo CD cluster secret created by `argocd cluster add --name`, so
no cluster address is ever committed and adding a cluster touches one list.

## Layout

```
argocd/
  bootstrap/        the single manifest applied by hand
  projects/         AppProjects: platform (cluster-scoped ok), applications (not)
  clusters/<name>/  one explicit Application per component, per cluster
  appsets/          matrix generator: environments x service overlays
platform/
  <component>/
    values.yaml           shared across clusters
    clusters/<name>.yaml  per-cluster overrides, merged second
    manifests/<name>/     extra resources for that cluster
applications/
  <service>/base/         cluster-agnostic manifests
  <service>/overlays/prod
clusters/           per-cluster notes
docs/               architecture, secrets, Jenkins, runbooks
scripts/            bootstrap and day-2 helpers
```

Platform components are explicit Applications rather than generated: they are
individually ordered by sync wave, and a wave you can read beats one you have to
derive from a generator.

## Separation of concerns

| Repo | Owns | Changed by |
|---|---|---|
| Application repos | Java/Maven source, tests, Dockerfile | Developers |
| External registry | Immutable image tags | Jenkins |
| **This repo** | Desired cluster state | Jenkins (tag bumps) + humans |

Jenkins never runs `kubectl apply`. It builds, pushes, and commits a one-line
image tag change here. Argo CD does the deploying, and it is the only thing
holding credentials to the application cluster.

## Environments

One today: `prod`, on `apps-prod`, in namespace `taptech-prod`. It does **not**
auto-sync — a Jenkins tag-bump commit makes the Application OutOfSync and waits
for a human. With no lower environment to catch problems first, that gate is the
only one there is.

## First-time setup

```bash
./scripts/set-repo-url.sh https://github.com/<org>/taptech-gitops.git
git add -A && git commit -m "chore: scaffold gitops repo" && git push
./scripts/bootstrap.sh          # against the management cluster
```

## Adding a service

```bash
./scripts/new-app.sh notifications
```

Commit it. The ApplicationSet discovers the new overlay directory and creates
the Argo CD Application — no edits under `argocd/`.
