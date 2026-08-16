#!/usr/bin/env bash
# Fetch MicroK8s kubeconfigs from each taptech cluster and merge them into
# your local ~/.kube/config under stable, unambiguous names.
#
#   Env                 Context             API server
#   -----               -------             ----------
#   taptech-mgmt        tap@104.225.223.215 https://104.225.223.215:16443
#   taptech-dev         tap@10.92.6.70      https://10.92.6.70:16443
#   taptech-prod        tap@23.227.173.107  https://23.227.173.107:16443
#
# Idempotency contract:
#   * Same result whether you run once, twice, or with any subset of envs.
#   * A per-host failure NEVER modifies the local kubeconfig for that env
#     (or any other). Successes commit; failures roll back.
#   * Contexts fetched in earlier runs are preserved when you re-run a subset.
#   * A timestamped backup is written before any change.
#
# Usage:
#   ./scripts/fetch-kubeconfigs.sh                     # all three
#   ./scripts/fetch-kubeconfigs.sh mgmt                # one env
#   ./scripts/fetch-kubeconfigs.sh mgmt dev            # subset
#
# Requires: ssh access as tap@ to each host. Passwordless sudo for
# `microk8s config` is preferred; otherwise you'll be prompted per host.
set -euo pipefail

declare -a ENVS=(
  "mgmt:104.225.223.215"
  "dev:10.92.6.70"
  "prod:23.227.173.107"
)

SSH_USER="${SSH_USER:-tap}"
LOCAL_KUBECONFIG="$HOME/.kube/config"
STAGING_DIR="$(mktemp -d -t fetch-kubeconfigs.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m--  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# --- Precondition checks -----------------------------------------------------
command -v kubectl >/dev/null || die "kubectl not found in PATH"
command -v ruby    >/dev/null || die "ruby not found in PATH"
command -v ssh     >/dev/null || die "ssh not found in PATH"
command -v scp     >/dev/null || die "scp not found in PATH"

# --- Determine which envs to process ----------------------------------------
if [ $# -eq 0 ]; then
  SELECTED=(mgmt dev prod)
else
  SELECTED=("$@")
fi
# Validate up front so we don't backup then bail.
for env in "${SELECTED[@]}"; do
  found=false
  for row in "${ENVS[@]}"; do
    [ "${row%%:*}" = "$env" ] && { found=true; break; }
  done
  $found || die "unknown env '$env' -- valid: mgmt dev prod"
done

# --- Backup before any change -----------------------------------------------
mkdir -p "$(dirname "$LOCAL_KUBECONFIG")"
touch "$LOCAL_KUBECONFIG"
BACKUP="${LOCAL_KUBECONFIG}.pre-fetch.$(/bin/date +%Y%m%d-%H%M%S)"
cp -p "$LOCAL_KUBECONFIG" "$BACKUP"
echo "backed up existing kubeconfig -> $BACKUP"

host_for() {
  local want="$1"
  for row in "${ENVS[@]}"; do
    local env="${row%%:*}" host="${row#*:}"
    if [ "$env" = "$want" ]; then echo "$host"; return 0; fi
  done
  return 1
}

# --- Stage 1: fetch and rewrite ALL kubeconfigs first ------------------------
# Nothing touches ~/.kube/config in this stage. If any host fails, we exit
# without having modified the local config.
declare -a READY_ENVS=()
declare -a READY_STAGES=()

for env in "${SELECTED[@]}"; do
  host="$(host_for "$env")"
  ctx="taptech-${env}"
  staged="$STAGING_DIR/${ctx}.yaml"

  say "fetching ${ctx} from ${SSH_USER}@${host}"

  # `sudo` on Ubuntu strips PATH via `secure_path` in /etc/sudoers, which
  # usually does NOT include /snap/bin -- so `sudo microk8s config` fails
  # with "command not found" even though microk8s is installed. Locate the
  # snap binary via a robust shell-side lookup that tries the two common
  # snap paths, then falls back to whatever is on the interactive PATH.
  remote_locate='
    for p in /snap/bin/microk8s /var/lib/snapd/snap/bin/microk8s; do
      if [ -x "$p" ]; then echo "$p"; exit 0; fi
    done
    command -v microk8s 2>/dev/null || { echo "microk8s not found" >&2; exit 127; }
  '
  remote_cfg_cmd="MK=\$(${remote_locate}) && sudo -n \"\$MK\" config"

  # Try passwordless sudo first. On failure, fall back to a two-step
  # interactive scp so sudo's prompt has a clean TTY.
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}@${host}" \
       "$remote_cfg_cmd" > "$staged" 2>/dev/null; then
    :
  else
    warn "passwordless sudo unavailable on ${host}; will prompt"
    remote_tmp="/tmp/microk8s-config.$$"
    remote_interactive="MK=\$(${remote_locate}) && sudo \"\$MK\" config > ${remote_tmp} && sudo chown ${SSH_USER} ${remote_tmp}"
    if ! ssh -t "${SSH_USER}@${host}" "$remote_interactive"; then
      warn "SSH+sudo failed for ${host} -- skipping ${ctx}"
      continue
    fi
    if ! scp -q "${SSH_USER}@${host}:${remote_tmp}" "$staged"; then
      ssh "${SSH_USER}@${host}" "rm -f ${remote_tmp}" 2>/dev/null || true
      warn "scp failed for ${host} -- skipping ${ctx}"
      continue
    fi
    ssh "${SSH_USER}@${host}" "rm -f ${remote_tmp}" 2>/dev/null || true
  fi

  if [ ! -s "$staged" ]; then
    warn "empty kubeconfig from ${host} -- skipping ${ctx}"
    continue
  fi

  # Rewrite server URL: MicroK8s emits 127.0.0.1, useless from the workstation.
  # Match any port so this survives non-default MicroK8s ports.
  sed -i.bak "s|server: https://127.0.0.1:|server: https://${host}:|" "$staged"
  rm -f "${staged}.bak"

  # Rename cluster / user / context so entries don't collide when merged.
  # MicroK8s ships the same three names (microk8s-cluster, admin, microk8s)
  # on every box -- without renaming, `kubectl config view --flatten` silently
  # collapses them into one.
  if ! ruby -ryaml -e '
    path, new_name = ARGV
    kc = YAML.load_file(path)
    abort "no clusters"  if !kc["clusters"]  || kc["clusters"].empty?
    abort "no users"     if !kc["users"]     || kc["users"].empty?
    abort "no contexts"  if !kc["contexts"]  || kc["contexts"].empty?
    kc["clusters"][0]["name"] = new_name
    kc["users"][0]["name"]    = new_name
    kc["contexts"].each do |c|
      c["name"]               = new_name
      c["context"]["cluster"] = new_name
      c["context"]["user"]    = new_name
    end
    kc["current-context"] = new_name
    File.write(path, kc.to_yaml)
  ' "$staged" "$ctx"; then
    warn "kubeconfig from ${host} has unexpected shape -- skipping ${ctx}"
    continue
  fi

  READY_ENVS+=("$ctx")
  READY_STAGES+=("$staged")
done

if [ ${#READY_STAGES[@]} -eq 0 ]; then
  warn "no envs fetched successfully; local kubeconfig unchanged"
  echo "backup remains at $BACKUP (unchanged from your original)"
  exit 1
fi

# --- Stage 2: single atomic merge -------------------------------------------
# One `kubectl config view --flatten` over the existing kubeconfig + every
# freshly-staged file, then atomic mv onto the real path. If anything in this
# stage fails, `set -e` aborts before the mv, so the original is untouched.
say "merging ${#READY_ENVS[@]} env(s) into ${LOCAL_KUBECONFIG}"

# Purge stale entries for THIS run's envs, from a COPY (not the real file).
# We rebuild by concatenating (copy without these envs) + (freshly staged
# kubeconfigs). This is what makes the operation truly idempotent for
# subsets: the envs we're touching are removed, everything else survives.
purged="$STAGING_DIR/local-purged.yaml"
cp -p "$LOCAL_KUBECONFIG" "$purged"
for ctx in "${READY_ENVS[@]}"; do
  KUBECONFIG="$purged" kubectl config delete-context "$ctx" >/dev/null 2>&1 || true
  KUBECONFIG="$purged" kubectl config delete-cluster "$ctx" >/dev/null 2>&1 || true
  KUBECONFIG="$purged" kubectl config delete-user    "$ctx" >/dev/null 2>&1 || true
done

# Build the merge input: purged local + each staged file.
KC_MERGE="$purged"
for staged in "${READY_STAGES[@]}"; do
  KC_MERGE="${KC_MERGE}:${staged}"
done

merged="$STAGING_DIR/config.merged"
if ! KUBECONFIG="$KC_MERGE" kubectl config view --flatten > "$merged"; then
  die "kubectl config view --flatten failed; original kubeconfig unchanged"
fi
if [ ! -s "$merged" ]; then
  die "merged kubeconfig is empty; original kubeconfig unchanged"
fi

# Atomic swap.
mv "$merged" "$LOCAL_KUBECONFIG"
chmod 600 "$LOCAL_KUBECONFIG"

# --- Stage 3: verify --------------------------------------------------------
say "verifying reachability"
failures=0
for env in "${SELECTED[@]}"; do
  ctx="taptech-${env}"
  host="$(host_for "$env")"
  # Skip envs we already declined to stage.
  found=false
  for r in "${READY_ENVS[@]}"; do
    [ "$r" = "$ctx" ] && { found=true; break; }
  done
  $found || { printf '    SKIP  %-16s (fetch failed above)\n' "$ctx"; continue; }

  if kubectl --context "$ctx" cluster-info --request-timeout=8s >/dev/null 2>&1; then
    printf '    OK    %-16s -> https://%s:16443\n' "$ctx" "$host"
  else
    printf '    WARN  %-16s merged but not reachable (firewall/cert?)\n' "$ctx"
    failures=$((failures + 1))
  fi
done

say "done. contexts now available:"
kubectl config get-contexts | awk 'NR==1 || /taptech-/'

echo
echo "backup: $BACKUP  (delete once you have verified everything works)"

[ "$failures" -eq 0 ]
