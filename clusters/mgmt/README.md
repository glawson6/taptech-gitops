# mgmt — management cluster

New cluster. Argo CD runs here and this is where you point `kubectl` to bootstrap.

Runs: Argo CD (self-managed), Jenkins + build agents, Grafana (single pane of
glass for both clusters), Prometheus (for this cluster's own metrics),
External Secrets, cert-manager, ingress-nginx, external-dns, Reloader, storage.

Does **not** run business services — the `applications` AppProject does not list
this cluster as a permitted destination, so a stray Application cannot land here.

Registered in Argo CD as `in-cluster` (the default name for the cluster Argo CD
itself runs on). Config lives in `argocd/clusters/mgmt/`.
