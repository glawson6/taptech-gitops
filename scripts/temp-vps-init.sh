#!/usr/bin/env bash
# One-shot init for a temporary VPS that will act as a clone target of the
# live apps-prod cluster. See docs/temp-vps-migration.md for the full plan.
#
# Deliberately does NOT install the GitOps platform stack -- this box is a
# faithful clone of the current production platform, not the future one.
# The MicroK8s `ingress` addon stays enabled; ingress-nginx from Helm is NOT
# installed. Everything else (Helm releases, Secrets, workloads) comes over
# via `clone-k8s-objects.sh` after this script finishes.
#
# Usage:
#   ./scripts/temp-vps-init.sh <temp-ip> [--channel 1.31/stable] \
#       [--metallb 10.64.140.100-10.64.140.110] [--original tap@23.227.173.107]
#
# Idempotent. Safe to re-run.
set -euo pipefail

TEMP_IP="${1:?usage: temp-vps-init.sh <temp-ip> [--channel X] [--metallb RANGE] [--original tap@IP]}"
shift || true

# Sensible defaults; override with flags. Channel must match the ORIGINAL
# box's MicroK8s version (see Phase 0 inventory in docs/temp-vps-migration.md).
CHANNEL="1.31/stable"
METALLB_RANGE=""   # empty = don't enable metallb (single-IP VPS, common case)
ORIGINAL="tap@23.227.173.107"
SSH_USER="tap"

while [ $# -gt 0 ]; do
  case "$1" in
    --channel)  CHANNEL="$2"; shift 2 ;;
    --metallb)  METALLB_RANGE="$2"; shift 2 ;;
    --original) ORIGINAL="$2"; shift 2 ;;
    --user)     SSH_USER="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

TEMP="${SSH_USER}@${TEMP_IP}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m--  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# --- Preconditions ---------------------------------------------------------
say "checking workstation -> ${TEMP} SSH"
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$TEMP" 'true' 2>/dev/null; then
  die "cannot SSH to ${TEMP} without a password. Inject your workstation
      pubkey into the VPS at provision time (most providers offer this
      in their web UI). Verify with: ssh ${TEMP} 'echo ok'"
fi

say "checking ${TEMP} sudo works (passwordless preferred)"
if ! ssh -o BatchMode=yes "$TEMP" 'sudo -n true' 2>/dev/null; then
  warn "passwordless sudo unavailable on ${TEMP}. Interactive sudo works but
      slows the script. To fix: on ${TEMP}, add '${SSH_USER} ALL=(ALL) NOPASSWD:ALL'
      to /etc/sudoers.d/${SSH_USER}. Continuing with interactive sudo..."
  SUDO_INTERACTIVE=1
else
  SUDO_INTERACTIVE=0
fi

# --- MicroK8s install ------------------------------------------------------
say "installing MicroK8s ${CHANNEL} on ${TEMP} (skipped if already installed)"
if [ "$SUDO_INTERACTIVE" -eq 1 ]; then
  ssh -t "$TEMP" "if ! command -v microk8s >/dev/null; then sudo snap install microk8s --classic --channel=${CHANNEL}; else echo 'microk8s already installed'; fi"
else
  ssh "$TEMP" "if ! command -v microk8s >/dev/null; then sudo snap install microk8s --classic --channel=${CHANNEL}; else echo 'microk8s already installed'; fi"
fi

say "waiting for MicroK8s to be ready"
ssh "$TEMP" 'sudo microk8s status --wait-ready --timeout 120' >/dev/null

# --- Addons ----------------------------------------------------------------
# Match the ORIGINAL box's addon set. Do NOT run prep-microk8s.sh here --
# that disables ingress, which is what we want for the FUTURE cluster but
# NOT the temp clone target. See docs/temp-vps-migration.md "Execution model".
say "enabling addons: dns hostpath-storage rbac ingress"
ssh "$TEMP" 'sudo microk8s enable dns hostpath-storage rbac ingress' >/dev/null

if [ -n "$METALLB_RANGE" ]; then
  say "enabling metallb (range: ${METALLB_RANGE})"
  ssh "$TEMP" "sudo microk8s enable metallb:${METALLB_RANGE}" >/dev/null
else
  warn "skipping metallb (no --metallb range given). If the original uses
      metallb and workloads reference LoadBalancer services, they will stay
      Pending on temp. Add --metallb '<start>-<end>' and re-run if needed."
fi

# --- User + kubectl setup --------------------------------------------------
say "adding ${SSH_USER} to microk8s group (takes effect next login)"
ssh "$TEMP" "sudo usermod -a -G microk8s ${SSH_USER} && sudo chown -f -R ${SSH_USER} ~/.kube 2>/dev/null || true"

say "extracting kubeconfig to /tmp/microk8s-config on ${TEMP}"
# MicroK8s emits 127.0.0.1; rewrite to the reachable IP so it works from
# your workstation once merged. Also chown so scp as ${SSH_USER} can pick it up.
ssh "$TEMP" "sudo microk8s config | sed 's|server: https://127.0.0.1:16443|server: https://${TEMP_IP}:16443|' > /tmp/microk8s-config && sudo chown ${SSH_USER} /tmp/microk8s-config && chmod 600 /tmp/microk8s-config"

# --- SSH: original -> temp (for rsync) -------------------------------------
say "setting up SSH key: ${ORIGINAL} -> ${TEMP} (used by rsync-pvc.sh)"
# Generate a keypair on the original if none exists. Then push the pubkey to
# the temp box's authorized_keys.
ssh -o BatchMode=yes "$ORIGINAL" 'test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "$(hostname)-to-temp-clone"' 2>/dev/null || \
  die "cannot SSH to ${ORIGINAL} without a password. Fix your workstation
      -> ${ORIGINAL} SSH first."

ORIGINAL_PUBKEY=$(ssh -o BatchMode=yes "$ORIGINAL" 'cat ~/.ssh/id_ed25519.pub')
[ -n "$ORIGINAL_PUBKEY" ] || die "empty pubkey from ${ORIGINAL}"

# Idempotent append (skip if already present)
ssh "$TEMP" "grep -qF '${ORIGINAL_PUBKEY}' ~/.ssh/authorized_keys 2>/dev/null || echo '${ORIGINAL_PUBKEY}' >> ~/.ssh/authorized_keys"
ssh "$TEMP" 'chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'

say "verifying ${ORIGINAL} can SSH to ${TEMP} without a password"
if ! ssh -o BatchMode=yes "$ORIGINAL" "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${TEMP} 'echo ok'" 2>/dev/null | grep -q '^ok$'; then
  die "original -> temp passwordless SSH still not working. rsync-pvc.sh will
      fail. Investigate: ssh ${ORIGINAL} 'ssh -v ${TEMP} true' 2>&1"
fi

# --- Done ------------------------------------------------------------------
cat <<MSG

$(printf '\033[1;32m==> temp VPS initialized\033[0m')

Kubeconfig is at /tmp/microk8s-config on ${TEMP_IP}. To merge locally:

  scp ${TEMP}:/tmp/microk8s-config /tmp/temp-vps-kubeconfig
  # Rename the internal cluster/user/context to taptech-prod-temp so it
  # doesn't collide with your existing 'microk8s' or other contexts:
  ruby -ryaml -e '
    kc = YAML.load_file("/tmp/temp-vps-kubeconfig")
    new = "taptech-prod-temp"
    kc["clusters"][0]["name"] = new
    kc["users"][0]["name"]    = new
    kc["contexts"].each { |c| c["name"] = new; c["context"]["cluster"] = new; c["context"]["user"] = new }
    kc["current-context"] = new
    File.write("/tmp/temp-vps-kubeconfig", kc.to_yaml)
  '
  KUBECONFIG=~/.kube/config:/tmp/temp-vps-kubeconfig kubectl config view --flatten > ~/.kube/config.new
  mv ~/.kube/config.new ~/.kube/config
  chmod 600 ~/.kube/config

Verify:
  kubectl --context taptech-prod-temp get nodes    # expect Ready

Then run:
  ./scripts/clone-k8s-objects.sh taptech-prod taptech-prod-temp --dry-run

MSG
