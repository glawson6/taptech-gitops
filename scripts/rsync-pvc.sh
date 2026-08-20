#!/usr/bin/env bash
# Migrate one PVC's data from one MicroK8s box to another via rsync.
# Used as Phase 2 of the temp-VPS bridge migration
# (docs/temp-vps-migration.md).
#
# Assumes both boxes use the microk8s-hostpath StorageClass. Data lives
# at /var/snap/microk8s/common/default-storage/<ns>-<pvc>-<uid>/.
#
# The workload on the SRC side is scaled to 0 (its pod must release the
# hostpath dir before rsync). The workload on DEST must already exist at
# replicas: 0 (the previous run of clone-k8s-objects.sh handled that).
# Data is rsync'd from src host to dest host directly, over the SSH key
# temp-vps-init.sh installed.
#
# Usage:
#   ./scripts/rsync-pvc.sh <src-context> <src-namespace> <workload> <dest-ip> [--dry-run]
# Example:
#   ./scripts/rsync-pvc.sh taptech-prod default elasticsearch-master 45.67.89.10
#
# The script does NOT scale the DEST workload up. That's a per-workload
# human decision you make after verifying the data landed.
set -euo pipefail

SRC_CTX="${1:?usage: rsync-pvc.sh <src-context> <src-ns> <workload> <dest-ip> [--dry-run]}"
SRC_NS="${2:?usage}"
WORKLOAD="${3:?usage}"
DEST_IP="${4:?usage}"
shift 4 || true

DRY_RUN=0
SRC_SSH_USER="tap"
DEST_SSH_USER="tap"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --src-user)     SRC_SSH_USER="$2";  shift 2 ;;
    --dest-user)    DEST_SSH_USER="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m--  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
command -v jq      >/dev/null || die "jq not found"

# --- Resolve src host IP from kubeconfig ---------------------------------
SRC_SERVER=$(kubectl config view --minify --context "$SRC_CTX" \
              -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
[ -n "$SRC_SERVER" ] || die "cannot find server for context '${SRC_CTX}'"
SRC_IP=$(echo "$SRC_SERVER" | sed -E 's|https?://([^:/]+).*|\1|')
[ -n "$SRC_IP" ] || die "cannot parse src IP from server URL '${SRC_SERVER}'"
SRC_SSH="${SRC_SSH_USER}@${SRC_IP}"
DEST_SSH="${DEST_SSH_USER}@${DEST_IP}"

say "src cluster: ${SRC_CTX} (host ${SRC_IP}) / dest host: ${DEST_IP}"

# --- Determine workload kind (StatefulSet or Deployment) -----------------
KIND=""
for k in statefulset deployment; do
  if kubectl --context "$SRC_CTX" -n "$SRC_NS" get "$k" "$WORKLOAD" >/dev/null 2>&1; then
    KIND="$k"; break
  fi
done
[ -n "$KIND" ] || die "no StatefulSet or Deployment '${WORKLOAD}' in ${SRC_CTX}/${SRC_NS}"
say "workload: ${KIND}/${WORKLOAD} in namespace ${SRC_NS}"

# --- Discover PVC(s) referenced by this workload -------------------------
# For a StatefulSet with volumeClaimTemplates, PVCs are named
# <template>-<workload>-<ordinal>. For plain Deployments, we read
# spec.template.spec.volumes[].persistentVolumeClaim.claimName.
if [ "$KIND" = "statefulset" ]; then
  PVCS=$(kubectl --context "$SRC_CTX" -n "$SRC_NS" get pvc \
    -o json | jq -r --arg w "$WORKLOAD" '
      .items[]
      | select(
          .metadata.labels["app.kubernetes.io/instance"] == $w
          or .metadata.labels.app == $w
          or (.metadata.name | endswith("-" + $w + "-0"))
          or (.metadata.name | contains($w))
        )
      | .metadata.name
    ' | sort -u)
else
  PVCS=$(kubectl --context "$SRC_CTX" -n "$SRC_NS" get "$KIND" "$WORKLOAD" -o json \
    | jq -r '.spec.template.spec.volumes[]? | .persistentVolumeClaim.claimName? | select(.)')
fi
PVCS=$(echo "$PVCS" | grep -v '^$' || true)
[ -n "$PVCS" ] || die "no PVCs found for ${KIND}/${WORKLOAD}"
say "PVCs to migrate: $(echo "$PVCS" | tr '\n' ' ')"

# --- SecurityContext uid/gid (for chown on dest) -------------------------
POD_UID=$(kubectl --context "$SRC_CTX" -n "$SRC_NS" get "$KIND" "$WORKLOAD" -o json \
  | jq -r '.spec.template.spec.securityContext.runAsUser // .spec.template.spec.containers[0].securityContext.runAsUser // 0')
POD_GID=$(kubectl --context "$SRC_CTX" -n "$SRC_NS" get "$KIND" "$WORKLOAD" -o json \
  | jq -r '.spec.template.spec.securityContext.fsGroup // .spec.template.spec.securityContext.runAsGroup // 0')
say "pod runAsUser: ${POD_UID}, fsGroup: ${POD_GID}"

# --- Scale src to 0 (destructive; needs confirmation unless --dry-run) --
CURRENT_REPLICAS=$(kubectl --context "$SRC_CTX" -n "$SRC_NS" get "$KIND" "$WORKLOAD" \
  -o jsonpath='{.spec.replicas}')
[ "$CURRENT_REPLICAS" = "0" ] && die "src ${KIND}/${WORKLOAD} already at replicas=0 (someone else migrating?)"

if [ "$DRY_RUN" -eq 0 ]; then
  echo
  warn "About to scale SRC ${SRC_CTX}/${SRC_NS}/${KIND}/${WORKLOAD} from ${CURRENT_REPLICAS} to 0."
  warn "This makes the workload UNAVAILABLE on src until you scale it back up."
  read -r -p "Type 'yes' to proceed: " OK
  [ "$OK" = "yes" ] || die "aborted at user request"

  say "scaling src ${KIND}/${WORKLOAD} to 0"
  kubectl --context "$SRC_CTX" -n "$SRC_NS" scale "$KIND" "$WORKLOAD" --replicas=0 >/dev/null
  say "waiting for src pods to terminate (max 120s)"
  kubectl --context "$SRC_CTX" -n "$SRC_NS" wait --for=delete pod \
    -l "app.kubernetes.io/instance=${WORKLOAD}" --timeout=120s 2>/dev/null || \
  kubectl --context "$SRC_CTX" -n "$SRC_NS" wait --for=delete pod \
    -l "app=${WORKLOAD}" --timeout=120s 2>/dev/null || true
fi

# --- Rsync per PVC -------------------------------------------------------
HOSTPATH_ROOT="/var/snap/microk8s/common/default-storage"

for PVC in $PVCS; do
  say "PVC: ${PVC}"

  # Resolve src hostpath dir (needs sudo -- hostpath-provisioner owns it as root)
  SRC_DIR=$(ssh -o BatchMode=yes "$SRC_SSH" "sudo ls -d ${HOSTPATH_ROOT}/${SRC_NS}-${PVC}-* 2>/dev/null" | head -1)
  [ -n "$SRC_DIR" ] || die "no hostpath dir on src for ${SRC_NS}/${PVC} under ${HOSTPATH_ROOT}"
  echo "    src:  ${SRC_SSH}:${SRC_DIR}/"

  DEST_DIR=$(ssh -o BatchMode=yes "$DEST_SSH" "sudo ls -d ${HOSTPATH_ROOT}/${SRC_NS}-${PVC}-* 2>/dev/null" | head -1)
  if [ -z "$DEST_DIR" ]; then
    die "no hostpath dir on dest for ${SRC_NS}/${PVC}. Confirm the dest PVC
        exists (clone-k8s-objects.sh --live must have run) and its workload
        is at replicas: 0 so hostpath-provisioner allocated the dir. Check:
          kubectl --context <dest> -n ${SRC_NS} get pvc ${PVC}"
  fi
  echo "    dest: ${DEST_SSH}:${DEST_DIR}/"

  RSYNC_CMD="sudo rsync -avzP --delete --numeric-ids -e 'ssh -o StrictHostKeyChecking=accept-new' '${SRC_DIR}/' '${DEST_SSH}:${DEST_DIR}/'"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    would run on ${SRC_SSH}: ${RSYNC_CMD} --dry-run"
    ssh -o BatchMode=yes "$SRC_SSH" "${RSYNC_CMD} --dry-run 2>&1 | tail -20"
  else
    say "running rsync (may take a while for large PVCs)"
    ssh -o BatchMode=yes "$SRC_SSH" "$RSYNC_CMD"
    say "fixing ownership on dest: ${POD_UID}:${POD_GID}"
    ssh -o BatchMode=yes "$DEST_SSH" "sudo chown -R ${POD_UID}:${POD_GID} '${DEST_DIR}'"
  fi
done

# --- Done ----------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
cat <<MSG

$(printf '\033[1;33m==> DRY-RUN: nothing was changed\033[0m')

Re-run without --dry-run to actually migrate. Note: real run will scale
src to 0 (with confirmation prompt).

MSG
else
cat <<MSG

$(printf '\033[1;32m==> data copied; src stays at replicas: 0\033[0m')

Next: scale up on DEST when ready. Not automated -- decide per workload.

  # Replicas count from the src (before we scaled it down) was: ${CURRENT_REPLICAS}
  # To scale dest up, get the target dest context name from your kubeconfig:
  kubectl --context <dest-context> -n ${SRC_NS} scale ${KIND} ${WORKLOAD} --replicas=${CURRENT_REPLICAS}

  # Verify the pod starts and mounts the migrated data:
  kubectl --context <dest-context> -n ${SRC_NS} get pods -l app.kubernetes.io/instance=${WORKLOAD}
  kubectl --context <dest-context> -n ${SRC_NS} logs <pod> --tail=50

  # If everything looks good, LEAVE src at replicas: 0. You'll scale
  # it back only if you roll back to src at cutover time.

MSG
fi
