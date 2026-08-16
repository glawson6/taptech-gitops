#!/usr/bin/env bash
# One-time bootstrap of the MANAGEMENT cluster. Run with kubectl pointed at it.
# Everything after this comes from git.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.11}"

echo "==> target: $(kubectl config current-context)"
read -r -p "    is that the MANAGEMENT cluster? [y/N] " ok
[ "$ok" = y ] || { echo "aborted"; exit 1; }

# 1. 1Password token -- the one secret that cannot come from git.
if ! kubectl -n external-secrets get secret onepassword-token >/dev/null 2>&1; then
  echo "==> 1Password service account token for the taptech-mgmt vault"
  read -r -s -p "    token: " OP_TOKEN; echo
  kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n external-secrets create secret generic onepassword-token \
    --from-literal=token="$OP_TOKEN"
fi

# 2. Argo CD, installed with the SAME chart+values the git Application uses, so
#    that Application adopts this release instead of fighting it.
if ! kubectl get ns argocd >/dev/null 2>&1; then
  echo "==> installing Argo CD $ARGOCD_CHART_VERSION"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    -f platform/argocd/values.yaml \
    --wait --timeout 10m
fi

# 3. Hand over to git.
echo "==> applying root Application"
kubectl apply -f argocd/bootstrap/root.yaml

cat <<'MSG'

Management cluster is up. Remaining steps:

  1. admin password
       kubectl -n argocd get secret argocd-initial-admin-secret \
         -o jsonpath='{.data.password}' | base64 -d; echo

  2. register the applications cluster -- the NAME is what manifests reference
       argocd cluster add <apps-cluster-context> --name apps-prod

  3. create its 1Password token, against THAT cluster
       kubectl --context <apps-ctx> create namespace external-secrets
       kubectl --context <apps-ctx> -n external-secrets \
         create secret generic onepassword-token --from-literal=token='ops_...'

  4. if this repo is private, register credentials
       argocd repo add <repo-url> --username <user> --password <pat>

MSG
