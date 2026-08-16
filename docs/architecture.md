# Architecture

```
                            GitHub
                               |
              +----------------+----------------+
              |                                 |
              v                                 v
      Application Repos                    GitOps Repo (this)
      Java / Maven, tests, Dockerfiles      argocd/ platform/ applications/
              |                                 |
              |                                 v
              |                        MANAGEMENT CLUSTER
              |                        +----------------------+
              +----------------------> | Jenkins  (builds)    |
                                       | Argo CD  (deploys)   |
                                       | Grafana  (observes)  |
                                       +----------+-----------+
                                            |          |
                        push images         |          | HTTPS -> Kubernetes API
                              v             |          |
                     External registry <----+          v
                              |                 APPLICATIONS CLUSTER
                              +---------------> MicroK8s (apps-prod)
                                                Frontend / Backend
                                                Prometheus (local scrape)

                                                K3s -- not built yet
```

Jenkins builds and pushes an image, then commits the new tag into this repo.
Argo CD notices the commit and deploys. Jenkins holds no cluster credentials for
the applications cluster; Argo CD is the only component that does.

## Why the management cluster is separate

The management cluster holds the credentials that matter: Argo CD's connection
to the applications cluster, the registry push credential, the GitOps PAT. The
applications cluster holds only runtime secrets. Compromising an application
does not yield the ability to deploy.

The inverse is worth stating too, because it is easy to get backwards: the
management cluster is the higher-value target of the two, despite feeling like
"just build infrastructure". Anything with access to it can deploy anything to
production.

## Why Kustomize for our services and Helm for third-party

- **Our services** use `base/` + `overlays/<env>/`. The overlay is a literal diff,
  so a pull request shows exactly what differs between environments. And
  `kustomization.yaml` has an `images:` block that `kustomize edit set image`
  rewrites — that is what Jenkins touches, as a clean one-line commit.
- **Third-party components** ship as Helm charts. We consume them as charts and
  keep only values in this repo. Re-templating someone else's chart into raw
  manifests means owning their upgrade path forever.

Rejected: Helm charts for our own services (pushes environment differences into
`values-prod.yaml`, where a diff no longer tells you what changes in the
cluster), and Helm + Kustomize post-rendering (most powerful, hardest to debug).

## Why ApplicationSets for services, explicit Applications for platform

Services are uniform and numerous — a matrix generator crosses the environment
list with the discovered overlay directories, so adding a service means adding a
directory and adding an environment means adding a list entry.

Platform components are individual and ordered: cert-manager before anything
requests a certificate, storage before a PVC binds, External Secrets before
anything needs a secret. Sync waves written out per component are clearer than
waves derived from a generator.

## Sync waves

| Wave | Component |
|---|---|
| -10 | storage |
| -8 | external-secrets, reloader |
| -7 | secret stores (needs ESO's CRDs from the previous wave) |
| -6 | application namespaces |
| -5 | cert-manager, jenkins-agents |
| -4 | ClusterIssuers (needs cert-manager's CRDs) |
| -3 | ingress-nginx, external-dns |
| 0 | Argo CD itself |
| 2 | Jenkins |
| 5 | monitoring |

## Monitoring topology

Prometheus runs on **both** clusters — kubelet, node and cAdvisor metrics can
only be scraped locally, so a single central Prometheus is not an option.
Grafana runs only on the management cluster and holds a datasource per
Prometheus, so dashboards and alert routing are configured once.
