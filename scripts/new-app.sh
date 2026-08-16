#!/usr/bin/env bash
# Scaffold a new service from the customer-service layout.
#   ./scripts/new-app.sh notifications
set -euo pipefail
APP="${1:?usage: new-app.sh <service-name>}"
cd "$(dirname "$0")/../applications"
[ -d "$APP" ] && { echo "$APP already exists"; exit 1; }

cp -r customer-service "$APP"
grep -rl 'customer-service' "$APP" | while read -r f; do
  python3 - "$f" "$APP" <<'PY'
import sys
p, app = sys.argv[1:3]
open(p, 'w').write(open(p).read().replace('customer-service', app))
PY
done
echo "created applications/$APP"
echo "commit it -- the ApplicationSet discovers the overlay on its next refresh."
