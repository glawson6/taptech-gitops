# apps-prod — application cluster

The existing MicroK8s box. Runs the four business services plus the platform
components they depend on.

Argo CD reaches it over HTTPS to the Kubernetes API. Register it from the
management cluster, and the name matters — manifests reference `apps-prod`,
never a URL:

    argocd cluster add <kubectl-context> --name apps-prod

Config lives in `argocd/clusters/apps-prod/`.
