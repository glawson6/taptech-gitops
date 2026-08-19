#!/usr/bin/env bash
# One-time host prep for a MicroK8s node destined to become the taptech-gitops
# management cluster. Run it on the target box (or via ssh). Idempotent.
#
#   ssh tap@<host> 'bash -s' < scripts/prep-microk8s.sh
#
# When it finishes, copy /tmp/microk8s-config back to your workstation, merge it
# into ~/.kube/config, rewrite the server URL to the host's reachable address
# (MicroK8s emits 127.0.0.1 by default), and rename the context. Then run
# scripts/bootstrap.sh against that context.
set -euo pipefail

if ! command -v microk8s >/dev/null 2>&1; then
  echo "microk8s is not installed on this host" >&2
  exit 1
fi

sudo microk8s status --wait-ready

# Addons the platform assumes are present:
#   dns              -- CoreDNS, required for everything
#   hostpath-storage -- backs the taptech-standard StorageClass
#   rbac             -- enforces the Roles ArgoCD/ExternalSecrets create
#
# NOT enabled: `ingress`. Recent MicroK8s ships Traefik as the default
# ingress addon (older versions shipped NGINX); either way it grabs host
# ports 80/443 and registers its own IngressClass, colliding with the
# ingress-nginx Helm chart that ArgoCD manages (platform/ingress, wave -3).
# One controller only, and it must be the git-managed one. If the addon
# was ever turned on, disable it below.
#
# MetalLB is optional. Enable it only if this box has a LAN with a spare IP
# range to hand out. On a single public-IP VM the ingress-nginx Service's
# hostNetwork/HostPort binding (configured via platform/ingress values) is
# enough. Uncomment and set the range if you want MetalLB:
#   sudo microk8s enable metallb:10.64.140.43-10.64.140.49
sudo microk8s enable dns hostpath-storage rbac

# Idempotent: only disable if currently enabled.
if sudo microk8s status --format short 2>/dev/null | grep -q '^ingress: enabled'; then
  echo "disabling microk8s ingress addon (git-managed ingress-nginx replaces it)"
  sudo microk8s disable ingress
fi

# Let the invoking user drive microk8s without sudo. Safe to re-run.
if ! id -nG "$USER" | grep -qw microk8s; then
  sudo usermod -a -G microk8s "$USER"
  echo "added $USER to the microk8s group; log out and back in for it to take effect"
fi
sudo chown -f -R "$USER" "$HOME/.kube" 2>/dev/null || true

sudo microk8s config > /tmp/microk8s-config
chmod 600 /tmp/microk8s-config
# Whoever is invoking this (via sudo from the workstation driver) needs to
# scp it back. Hand ownership to the invoking user, not root.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  chown "$SUDO_USER" /tmp/microk8s-config
fi

cat <<MSG

MicroK8s is ready. Kubeconfig written to /tmp/microk8s-config on this host.

Next steps from your workstation:

  scp tap@<host>:/tmp/microk8s-config /tmp/microk8s-config
  # inspect it; the server field will be https://127.0.0.1:16443
  # rewrite it to the host's reachable address, e.g. https://<host>:16443
  KUBECONFIG=~/.kube/config:/tmp/microk8s-config \\
    kubectl config view --flatten > ~/.kube/config.new
  mv ~/.kube/config.new ~/.kube/config
  kubectl config rename-context microk8s taptech-mgmt
  kubectl --context taptech-mgmt get nodes    # expect Ready

Then run ./scripts/bootstrap.sh against the taptech-mgmt context.
MSG
