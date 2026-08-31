#!/usr/bin/env bash
#
# jenkins-bootstrap-seed.sh
#
# Provision the JobDSL seed job on Jenkins via the REST API. Run ONCE per
# cluster (idempotent — POST /createItem returns HTTP 400 if the job
# already exists, which is treated as success here).
#
# After this runs:
#   - Jenkins has one job named `seed-jobs`, checked out from
#     https://github.com/glawson6/taptech-gitops.git @ main
#   - It executes scripts/jenkins-seed.Jenkinsfile on every SCM poll
#   - Which reads platform/jenkins/jobs/*.groovy and creates/updates
#     the mcp-client-deploy / mcp-calendar-deploy / taptech-crm-deploy jobs
#
# Every subsequent job change is a git commit. Nothing is clicked.
#
# ── Requirements ──────────────────────────────────────────────────────────
#   * Jenkins reachable at $JENKINS_URL (default https://jenkins.taptech.net)
#   * User $JENKINS_USER (default 'ai-agent') with Job.Create — already
#     wired via JCasC (platform/jenkins/values.yaml). Password comes from
#     1Password item op://taptech-mgmt/jenkins-ai-agent/password.
#   * `curl` and `op` (1Password CLI) on PATH. If `op` is unavailable, set
#     JENKINS_TOKEN in the env before running.
#   * Plugins installed on Jenkins: job-dsl, workflow-aggregator, git.
#     (workflow-aggregator ships with the Helm chart default; job-dsl is
#     added via controller.installPlugins in values.yaml if not already.)
#
# ── Usage ─────────────────────────────────────────────────────────────────
#   $ scripts/jenkins-bootstrap-seed.sh
#   $ JENKINS_URL=https://jenkins.example.net scripts/jenkins-bootstrap-seed.sh
#   $ JENKINS_TOKEN=xxxx scripts/jenkins-bootstrap-seed.sh   # skip 1Password lookup
#

set -euo pipefail

JENKINS_URL=${JENKINS_URL:-https://jenkins.taptech.net}
JENKINS_USER=${JENKINS_USER:-ai-agent}
SEED_JOB_NAME=${SEED_JOB_NAME:-seed-jobs}
CONFIG_XML=${CONFIG_XML:-"$(dirname "$0")/jenkins-seed-config.xml"}

if [[ -z "${JENKINS_TOKEN:-}" ]]; then
  if command -v op >/dev/null 2>&1; then
    echo "[bootstrap] Reading Jenkins credential from 1Password"
    JENKINS_TOKEN=$(op read "op://taptech-mgmt/jenkins-ai-agent/password")
  else
    echo "ERROR: JENKINS_TOKEN not set and 'op' CLI not available." >&2
    echo "       Either export JENKINS_TOKEN or install the 1Password CLI." >&2
    exit 2
  fi
fi

if [[ ! -f "$CONFIG_XML" ]]; then
  echo "ERROR: config.xml not found at $CONFIG_XML" >&2
  exit 2
fi

echo "[bootstrap] Target: $JENKINS_URL"
echo "[bootstrap] Auth user: $JENKINS_USER"
echo "[bootstrap] Seed job name: $SEED_JOB_NAME"

# Fetch the CSRF crumb (Jenkins default) AND keep the JSESSIONID Jenkins
# binds it to. Modern Jenkins (2.x LTS with the crumb-per-session policy)
# validates the crumb against the session cookie, so a fresh cookie jar
# on the follow-up POST would 403 with "No valid crumb". We store cookies
# in $COOKIE_JAR and reuse them across every subsequent authenticated call.
COOKIE_JAR=$(mktemp -t jenkins-bootstrap-cookies.XXXXXX)
trap 'rm -f "$COOKIE_JAR" /tmp/jenkins-create.out' EXIT

CRUMB=$(curl -sSf \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  --cookie-jar "$COOKIE_JAR" --cookie "$COOKIE_JAR" \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
if [[ -z "$CRUMB" ]]; then
  echo "ERROR: failed to obtain CSRF crumb. Is CSRF disabled? Check /manage/configureSecurity" >&2
  exit 3
fi

# Create the seed job. Treat "already exists" as success (Jenkins returns
# HTTP 400 with 'A job already exists with the name ...' when the job
# is present — we detect that below and continue to update+build).
create_http_code=$(curl -sS -o /tmp/jenkins-create.out -w '%{http_code}' \
  -X POST --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  --cookie-jar "$COOKIE_JAR" --cookie "$COOKIE_JAR" \
  -H "${CRUMB}" \
  -H 'Content-Type: application/xml' \
  --data-binary "@${CONFIG_XML}" \
  "${JENKINS_URL}/createItem?name=${SEED_JOB_NAME}")

case "$create_http_code" in
  2??)
    echo "[bootstrap] Seed job created."
    ;;
  400)
    if grep -qi 'already exists' /tmp/jenkins-create.out; then
      echo "[bootstrap] Seed job already exists — updating its config."
      curl -sSf -X POST --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        --cookie-jar "$COOKIE_JAR" --cookie "$COOKIE_JAR" \
        -H "${CRUMB}" \
        -H 'Content-Type: application/xml' \
        --data-binary "@${CONFIG_XML}" \
        "${JENKINS_URL}/job/${SEED_JOB_NAME}/config.xml"
    else
      echo "ERROR: createItem returned 400:" >&2
      cat /tmp/jenkins-create.out >&2
      exit 4
    fi
    ;;
  *)
    echo "ERROR: createItem returned HTTP $create_http_code:" >&2
    cat /tmp/jenkins-create.out >&2
    exit 4
    ;;
esac

echo "[bootstrap] Triggering an initial build of ${SEED_JOB_NAME} to materialize downstream jobs..."
curl -sSf -X POST --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  --cookie-jar "$COOKIE_JAR" --cookie "$COOKIE_JAR" \
  -H "${CRUMB}" \
  "${JENKINS_URL}/job/${SEED_JOB_NAME}/build"

echo
echo "[bootstrap] Done."
echo "  Watch:   ${JENKINS_URL}/job/${SEED_JOB_NAME}/"
echo "  Then:    ${JENKINS_URL}/  (mcp-client-deploy, mcp-calendar-deploy, taptech-crm-deploy)"
