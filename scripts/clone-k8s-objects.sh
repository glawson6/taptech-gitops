#!/usr/bin/env bash
# Clone Kubernetes objects from one cluster context to another. Used as
# Phase 1 of the temp-VPS bridge migration (docs/temp-vps-migration.md).
#
# Copies namespaces, CRDs, cluster-scoped RBAC/policy, all namespaced
# resources including Helm-release-tracking secrets, and workloads (scaled
# to 0 replicas so nothing starts before PVC data is rsync'd separately by
# scripts/rsync-pvc.sh).
#
# Defaults to --dry-run: writes every manifest to /tmp/clone-<ts>/ for
# review, applies nothing. Pass --live to actually apply on dest.
#
# Usage:
#   ./scripts/clone-k8s-objects.sh <src-context> <dest-context> [--live] \
#       [--skip-namespaces ns1,ns2] [--only-namespaces ns1,ns2]
set -euo pipefail

SRC="${1:?usage: clone-k8s-objects.sh <src-context> <dest-context> [--live]}"
DEST="${2:?usage: clone-k8s-objects.sh <src-context> <dest-context> [--live]}"
shift 2 || true

LIVE=0
SKIP_NAMESPACES="kube-system,kube-public,kube-node-lease,argocd,external-secrets,reloader"
ONLY_NAMESPACES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --live)              LIVE=1;                shift ;;
    --skip-namespaces)   SKIP_NAMESPACES="$2";  shift 2 ;;
    --only-namespaces)   ONLY_NAMESPACES="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m--  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# --- Preflight ------------------------------------------------------------
command -v kubectl >/dev/null || die "kubectl not found"
command -v jq      >/dev/null || die "jq not found (brew install jq)"

kubectl --context "$SRC"  cluster-info >/dev/null 2>&1 || die "cannot reach src context '${SRC}'"
kubectl --context "$DEST" cluster-info >/dev/null 2>&1 || die "cannot reach dest context '${DEST}'"

if [ "$SRC" = "$DEST" ]; then die "src and dest are the same context"; fi

TS=$(/bin/date +%Y%m%d-%H%M%S)
OUT="/tmp/clone-${TS}"
mkdir -p "$OUT"

MODE=$([ "$LIVE" -eq 1 ] && echo LIVE || echo DRY-RUN)
say "cloning ${SRC} -> ${DEST}  [mode: ${MODE}]  [output dir: ${OUT}]"

# --- Sanitizer ------------------------------------------------------------
# Strip server-set fields that would confuse the destination cluster.
# Any per-cluster identity (uid, resourceVersion), timestamps, cached
# last-applied annotations, and the whole .status subtree get zapped.
# Also drops managedFields so server-side-apply on dest starts clean.
sanitize() {
  jq '
    .items |= map(
      del(
        .metadata.uid,
        .metadata.resourceVersion,
        .metadata.generation,
        .metadata.creationTimestamp,
        .metadata.deletionTimestamp,
        .metadata.deletionGracePeriodSeconds,
        .metadata.selfLink,
        .metadata.managedFields,
        .metadata.ownerReferences,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.annotations["deployment.kubernetes.io/revision"],
        .status
      )
      # Empty annotations map after delete looks noisy; drop it if empty.
      | if .metadata.annotations == {} then del(.metadata.annotations) else . end
    )
  '
}

# For Deployments/StatefulSets: force replicas: 0 so nothing starts on dest
# before PVC data is populated. User scales up per workload after rsync.
force_replicas_zero() {
  jq '
    .items |= map(
      if .spec then .spec.replicas = 0 else . end
    )
  '
}

# For Services: drop clusterIP + clusterIPs + nodePort so dest allocates fresh.
sanitize_service() {
  jq '
    .items |= map(
      .spec.clusterIP = null
      | .spec.clusterIPs = null
      | (.spec.ports // []) |= map(del(.nodePort))
    )
  '
}

# For PVCs: keep spec.storageClassName + resources.requests.storage;
# clear volumeName so dest re-provisions. Without this the PVC binds to a
# non-existent PV name from the src cluster.
sanitize_pvc() {
  jq '
    .items |= map(
      .spec.volumeName = null
    )
  '
}

apply_or_save() {
  local file="$1" label="$2"
  # Skip if the file has no items (kubectl errors 'no objects passed to apply')
  # or is missing entirely (dry-run path returns nothing).
  [ -f "$file" ] || return 0
  # Two shapes appear in this pipeline: List objects (from `kubectl get -o
  # json`, have .items[]) and single objects (from `kubectl get <name> -o
  # json`, no .items). Only skip the file when it IS a List AND its items
  # array is empty. A single object doesn't have .items so we should never
  # skip it.
  local kind n_items
  kind=$(jq -r '.kind // ""' "$file" 2>/dev/null)
  if [ "$kind" = "List" ] || echo "$kind" | grep -q List$; then
    n_items=$(jq '.items // [] | length' "$file" 2>/dev/null)
    if [ -z "$n_items" ] || [ "$n_items" -eq 0 ]; then
      # Delete the empty file so /tmp/clone-* stays uncluttered.
      rm -f "$file"
      return 0
    fi
  fi
  if [ "$LIVE" -eq 1 ]; then
    kubectl --context "$DEST" apply --server-side --force-conflicts -f "$file" >/dev/null \
      || warn "apply failed for ${label} (see ${file})"
  fi
}

# --- 1. Namespaces --------------------------------------------------------
say "namespaces"
ALL_NS=$(kubectl --context "$SRC" get ns -o json | jq -r '.items[].metadata.name')
# --only-namespaces takes precedence: if set, only those are included.
if [ -n "$ONLY_NAMESPACES" ]; then
  ONLY_PATTERNS=$(echo "$ONLY_NAMESPACES" | tr ',' '\n')
  NS_LIST=$(echo "$ALL_NS" | grep -Fxf <(echo "$ONLY_PATTERNS"))
else
  SKIP_PATTERNS=$(echo "$SKIP_NAMESPACES" | tr ',' '\n')
  NS_LIST=$(echo "$ALL_NS" | grep -vFxf <(echo "$SKIP_PATTERNS"))
fi

if [ -z "$NS_LIST" ]; then
  die "no namespaces to clone after filtering (--skip='${SKIP_NAMESPACES}' --only='${ONLY_NAMESPACES}')"
fi
say "namespaces to clone: $(echo "$NS_LIST" | tr '\n' ' ')"
echo "$NS_LIST" | while read -r ns; do
  [ -z "$ns" ] && continue
  kubectl --context "$SRC" get ns "$ns" -o json \
    | jq '. | del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .status)' \
    > "$OUT/00-ns-${ns}.json"
  apply_or_save "$OUT/00-ns-${ns}.json" "namespace/${ns}"
done

# --- 2. Cluster-scoped ----------------------------------------------------
CLUSTER_KINDS=(customresourcedefinitions clusterroles clusterrolebindings storageclasses ingressclasses)
for kind in "${CLUSTER_KINDS[@]}"; do
  say "cluster-scoped: ${kind}"
  kubectl --context "$SRC" get "$kind" -o json | sanitize > "$OUT/10-${kind}.json"
  apply_or_save "$OUT/10-${kind}.json" "$kind"
done

# ClusterIssuers may not exist (cert-manager may be installed differently).
# Best-effort.
if kubectl --context "$SRC" api-resources 2>/dev/null | grep -qE '^clusterissuers\b'; then
  say "cluster-scoped: clusterissuers"
  kubectl --context "$SRC" get clusterissuers -o json | sanitize > "$OUT/10-clusterissuers.json" 2>/dev/null || true
  apply_or_save "$OUT/10-clusterissuers.json" "clusterissuers"
fi

# --- 3. Namespaced resources ---------------------------------------------
# Order matters: Secrets/ConfigMaps/RBAC first (workloads reference them),
# then PVCs (workloads mount them), then Services + Ingresses + workloads.
NAMESPACED_EARLY=(secrets configmaps serviceaccounts roles rolebindings)
NAMESPACED_MID=(persistentvolumeclaims services ingresses)
# NOTE: DaemonSets NOT in this list. DaemonSet.spec has no .replicas field
# (kubectl rejects the manifest if we set it), and DaemonSets on the temp box
# are already provided by MicroK8s addons (calico-node, ingress). Copying a
# DaemonSet with `sanitize` still fails to apply because the ownership
# references and node-scoped tolerations rarely translate.
NAMESPACED_WORKLOADS=(deployments statefulsets)
NAMESPACED_JOBS=(cronjobs)

# ExternalSecret + OnePasswordItem CRs may or may not exist.
if kubectl --context "$SRC" api-resources 2>/dev/null | grep -qE '^externalsecrets\b'; then
  NAMESPACED_MID+=(externalsecrets)
fi
if kubectl --context "$SRC" api-resources 2>/dev/null | grep -qE '^onepassworditems\b'; then
  NAMESPACED_MID+=(onepassworditems)
fi
if kubectl --context "$SRC" api-resources 2>/dev/null | grep -qE '^certificates\b'; then
  NAMESPACED_MID+=(certificates)
fi

echo "$NS_LIST" | while read -r ns; do
  [ -z "$ns" ] && continue
  say "namespace: ${ns}"

  for kind in "${NAMESPACED_EARLY[@]}"; do
    kubectl --context "$SRC" -n "$ns" get "$kind" -o json 2>/dev/null \
      | jq --arg ns "$ns" '
          .items |= map(select(
            # skip service-account tokens (K8s regenerates them per SA on dest)
            .type != "kubernetes.io/service-account-token"
            # skip helm auto-generated Kubernetes tokens
            and (.metadata.name | startswith("default-token-") | not)
          ))
        ' | sanitize > "$OUT/20-${ns}-${kind}.json"
    apply_or_save "$OUT/20-${ns}-${kind}.json" "${ns}/${kind}"
  done

  for kind in "${NAMESPACED_MID[@]}"; do
    RAW=$(kubectl --context "$SRC" -n "$ns" get "$kind" -o json 2>/dev/null)
    [ -z "$RAW" ] && continue

    if [ "$kind" = "services" ]; then
      echo "$RAW" | sanitize_service | sanitize > "$OUT/30-${ns}-${kind}.json"
    elif [ "$kind" = "persistentvolumeclaims" ]; then
      echo "$RAW" | sanitize_pvc | sanitize > "$OUT/30-${ns}-${kind}.json"
    else
      echo "$RAW" | sanitize > "$OUT/30-${ns}-${kind}.json"
    fi
    apply_or_save "$OUT/30-${ns}-${kind}.json" "${ns}/${kind}"
  done

  # Workloads: at replicas 0.
  for kind in "${NAMESPACED_WORKLOADS[@]}"; do
    kubectl --context "$SRC" -n "$ns" get "$kind" -o json 2>/dev/null \
      | force_replicas_zero | sanitize > "$OUT/40-${ns}-${kind}.json"
    apply_or_save "$OUT/40-${ns}-${kind}.json" "${ns}/${kind}"
  done

  for kind in "${NAMESPACED_JOBS[@]}"; do
    kubectl --context "$SRC" -n "$ns" get "$kind" -o json 2>/dev/null \
      | sanitize > "$OUT/40-${ns}-${kind}.json"
    apply_or_save "$OUT/40-${ns}-${kind}.json" "${ns}/${kind}"
  done
done

# --- Done -----------------------------------------------------------------
say "wrote $(find "$OUT" -name '*.json' | wc -l | tr -d ' ') manifest files to ${OUT}"

if [ "$LIVE" -eq 0 ]; then
cat <<MSG

$(printf '\033[1;33m==> DRY-RUN: nothing was applied\033[0m')

Review the manifests in ${OUT} for anything unexpected:
  ls ${OUT}/
  # Look at Secrets in particular; they'll include cluster-generated data
  # you may not want on dest (e.g., service-account tokens got filtered,
  # but old CA bundles or webhook secrets stay).

When happy, re-run with --live:
  $0 ${SRC} ${DEST} --live

MSG
else
cat <<MSG

$(printf '\033[1;32m==> LIVE: applied to ${DEST}\033[0m')

Every workload is at replicas: 0. Next: migrate PVC data per workload
with scripts/rsync-pvc.sh, then scale up.

Verify shape parity:
  kubectl --context ${SRC}  get all -A --no-headers | wc -l
  kubectl --context ${DEST} get all -A --no-headers | wc -l

MSG
fi
