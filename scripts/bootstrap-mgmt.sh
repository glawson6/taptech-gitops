#!/usr/bin/env bash
# Drive Steps 2 and 3 of docs/bootstrap-mgmt-cluster.md end-to-end from your
# workstation. Assumes Step 0 (SSH pubkey installed) and Step 1 (1Password
# vault + items) are already done.
#
# Usage:
#   HOST=104.225.223.215 [SSH_USER=tap] [CONTEXT=taptech-mgmt] \
#     [OP_TOKEN='ops_...'] ./scripts/bootstrap-mgmt.sh
#
# What it does:
#   1. Sanity-checks SSH + sudo on the target.
#   2. Runs scripts/prep-microk8s.sh on the host over SSH.
#   3. Copies the kubeconfig back, rewrites 127.0.0.1 -> HOST, merges into
#      ~/.kube/config, renames the context to $CONTEXT.
#   4. Waits for the node to be Ready.
#   5. Runs scripts/bootstrap.sh against $CONTEXT. If OP_TOKEN is set, feeds
#      it in non-interactively; otherwise you'll be prompted by bootstrap.sh.
#
# Idempotent -- safe to re-run. Each step checks the current state and skips
# work that is already done.
set -euo pipefail

: "${HOST:?set HOST=<ip-or-hostname of the mgmt node>}"
SSH_USER="${SSH_USER:-tap}"
CONTEXT="${CONTEXT:-taptech-mgmt}"
KUBE_PORT="${KUBE_PORT:-16443}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_KUBECONFIG="$HOME/.kube/config"
STAGING_KUBECONFIG="/tmp/microk8s-config.$$"
trap 'rm -f "$STAGING_KUBECONFIG"' EXIT

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m--  %s\033[0m\n' "$*" >&2; }

ssh_target="${SSH_USER}@${HOST}"

# ------------------------------------------------------------------ Step 2.1
say "checking SSH on $ssh_target"
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_target" 'true' 2>/dev/null; then
  warn "publickey SSH to $ssh_target failed."
  warn "install your workstation pubkey per Step 0 of docs/bootstrap-mgmt-cluster.md"
  exit 1
fi

# Sudo over SSH is fiddly: -t (TTY) conflicts with stdin redirection, and
# sudo's password cache does not survive across SSH sessions. Ask once here
# and pipe it to `sudo -S` for every remote call.
#
# If SUDO_PASS is already exported, skip the prompt (useful for CI).
if [ -z "${SUDO_PASS:-}" ]; then
  read -r -s -p "sudo password for $ssh_target: " SUDO_PASS; echo
fi
# Sanity-check the password. `sudo -S -v` reads from stdin, so pipe it.
if ! printf '%s\n' "$SUDO_PASS" \
     | ssh "$ssh_target" 'sudo -S -p "" -v' 2>/dev/null; then
  warn "sudo authentication failed on $ssh_target."
  warn "check the password, or run 'sudo passwd $SSH_USER' on the host."
  exit 1
fi

# ------------------------------------------------------------------ Step 2.1
say "running scripts/prep-microk8s.sh on $HOST"
# Base64-inline the script so stdin stays free for the sudo password. `sudo
# -S -p ""` reads exactly one line from stdin as the password, then execs
# bash which reads the decoded script from its own stdin. We concat with
# printf so the password is line 1 and the script is line 2+.
PREP_B64="$(base64 < "$REPO_ROOT/scripts/prep-microk8s.sh" | tr -d '\n')"
{
  printf '%s\n' "$SUDO_PASS"
  printf '%s' "$PREP_B64" | base64 --decode
} | ssh "$ssh_target" "sudo -S -p '' bash"

# ------------------------------------------------------------------ Step 2.2
say "fetching kubeconfig from $HOST"
# prep-microk8s.sh already wrote /tmp/microk8s-config on the host.
scp -q "$ssh_target:/tmp/microk8s-config" "$STAGING_KUBECONFIG"

# ------------------------------------------------------------------ Step 2.3
say "rewriting server URL to https://$HOST:$KUBE_PORT"
sed -i.bak "s|server: https://127.0.0.1:$KUBE_PORT|server: https://$HOST:$KUBE_PORT|" \
  "$STAGING_KUBECONFIG"
rm -f "${STAGING_KUBECONFIG}.bak"

# TLS check: MicroK8s' API cert may not include $HOST in its SANs. If it
# doesn't, curl will fail. Try, and fall back to insecure-skip-tls-verify
# (loud warning) so bootstrap can proceed. Rotate the cert later.
if ! curl --silent --show-error --max-time 5 \
     --cacert /dev/null -k "https://$HOST:$KUBE_PORT/livez" >/dev/null; then
  warn "cannot reach https://$HOST:$KUBE_PORT -- check firewall / port"
  exit 1
fi
if ! python3 -c "
import ssl, socket
ctx = ssl.create_default_context()
try:
    with socket.create_connection(('$HOST', $KUBE_PORT), timeout=5) as s:
        with ctx.wrap_socket(s, server_hostname='$HOST'):
            pass
except ssl.SSLCertVerificationError:
    raise SystemExit(1)
except Exception:
    raise SystemExit(0)
" 2>/dev/null; then
  warn "API cert does not include $HOST in its SANs."
  warn "adding 'insecure-skip-tls-verify: true' to the staged kubeconfig."
  warn "fix later: 'sudo microk8s refresh-certs -e server.crt' on the host,"
  warn "  then re-run this script."
  # Insert the field under the cluster stanza and drop the CA data.
  python3 - "$STAGING_KUBECONFIG" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'^(\s*)certificate-authority-data:.*$',
           r'\1insecure-skip-tls-verify: true',
           s, count=1, flags=re.MULTILINE)
open(p, 'w').write(s)
PY
fi

# ------------------------------------------------------------------ Step 2.4
say "merging into $LOCAL_KUBECONFIG"
mkdir -p "$(dirname "$LOCAL_KUBECONFIG")"
touch "$LOCAL_KUBECONFIG"
# If a context named $CONTEXT already exists, drop it so the merge is clean.
if KUBECONFIG="$LOCAL_KUBECONFIG" kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1; then
  warn "context $CONTEXT exists locally -- replacing it"
  KUBECONFIG="$LOCAL_KUBECONFIG" kubectl config delete-context "$CONTEXT" >/dev/null 2>&1 || true
  KUBECONFIG="$LOCAL_KUBECONFIG" kubectl config delete-cluster "$CONTEXT" >/dev/null 2>&1 || true
  KUBECONFIG="$LOCAL_KUBECONFIG" kubectl config delete-user "$CONTEXT" >/dev/null 2>&1 || true
fi

MERGED="${LOCAL_KUBECONFIG}.new.$$"
KUBECONFIG="$LOCAL_KUBECONFIG:$STAGING_KUBECONFIG" \
  kubectl config view --flatten > "$MERGED"
mv "$MERGED" "$LOCAL_KUBECONFIG"
chmod 600 "$LOCAL_KUBECONFIG"

# The imported context is called "microk8s"; rename it.
if kubectl config get-contexts microk8s >/dev/null 2>&1; then
  kubectl config rename-context microk8s "$CONTEXT" >/dev/null
fi
kubectl config use-context "$CONTEXT" >/dev/null

say "waiting for node to be Ready (up to 2 min)"
kubectl wait --for=condition=Ready node --all --timeout=120s
kubectl get nodes

# ------------------------------------------------------------------ Step 3.1
say "confirming target for bootstrap"
CURRENT="$(kubectl config current-context)"
if [ "$CURRENT" != "$CONTEXT" ]; then
  warn "current context is $CURRENT, expected $CONTEXT -- aborting"
  exit 1
fi

# ------------------------------------------------------------------ Step 3.2
say "running scripts/bootstrap.sh against $CONTEXT"
cd "$REPO_ROOT"
if [ -n "${OP_TOKEN:-}" ]; then
  # bootstrap.sh reads two interactive prompts: the y/N confirm and the
  # 1Password token. Feed both non-interactively.
  # If the onepassword-token secret already exists, bootstrap.sh skips the
  # token prompt entirely -- in that case we still need to answer y.
  if kubectl -n external-secrets get secret onepassword-token >/dev/null 2>&1; then
    printf 'y\n' | ./scripts/bootstrap.sh
  else
    printf 'y\n%s\n' "$OP_TOKEN" | ./scripts/bootstrap.sh
  fi
else
  # No token passed -- run interactively so the user can paste it.
  ./scripts/bootstrap.sh
fi

# ------------------------------------------------------------------ Step 3.3
say "reconciliation kicked off. watch it with:"
cat <<EOF

  kubectl -n argocd get pods -w
  kubectl -n argocd get applications -w

  # ArgoCD admin password:
  kubectl -n argocd get secret argocd-initial-admin-secret \\
    -o jsonpath='{.data.password}' | base64 -d; echo

Every mgmt-* Application should reach Synced/Healthy within ~15 min.
Wave order and troubleshooting: docs/bootstrap-mgmt-cluster.md
EOF
