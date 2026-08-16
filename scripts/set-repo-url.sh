#!/usr/bin/env bash
# Rewrite the placeholder repoURL across every manifest.
#   ./scripts/set-repo-url.sh https://github.com/<org>/taptech-gitops.git
set -euo pipefail
NEW="${1:?usage: set-repo-url.sh <git-url>}"
OLD='https://github.com/taptech/taptech-gitops.git'
cd "$(dirname "$0")/.."
grep -rl "$OLD" argocd platform applications docs 2>/dev/null | while read -r f; do
  python3 - "$f" "$OLD" "$NEW" <<'PY'
import sys
p,o,n = sys.argv[1:4]
s = open(p).read()
open(p,'w').write(s.replace(o,n))
PY
  echo "updated $f"
done
echo "done. repoURL is now $NEW"
