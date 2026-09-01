#!/usr/bin/env bash
#
# jenkins-approve-pending-scripts.sh
#
# One-shot helper to approve every pending unsandboxed script sitting in
# Jenkins' Script Approval queue. Needed because the JobDSL step runs
# outside the Groovy sandbox (see scripts/jenkins-seed.Jenkinsfile) and
# every unique DSL "signature" requires manual approval before it can run.
#
# Run this once after a seed-jobs FAILURE with the error
#   "script not yet approved for use"
# then re-trigger seed-jobs.
#
# Auth: same as jenkins-bootstrap-seed.sh — reads
#   op://taptech-mgmt/jenkins-ai-agent/password
# or picks up $JENKINS_TOKEN from the env.
#
# NOTE: the `ai-agent` user must have Overall/Administer to approve
# scripts. `loggedInUsersCanDoAnything` in JCasC gives it exactly that.

set -euo pipefail

JENKINS_URL=${JENKINS_URL:-https://jenkins.taptech.net}
JENKINS_USER=${JENKINS_USER:-ai-agent}

if [[ -z "${JENKINS_TOKEN:-}" ]]; then
  if command -v op >/dev/null 2>&1; then
    JENKINS_TOKEN=$(op read "op://taptech-mgmt/jenkins-ai-agent/password")
  else
    echo "ERROR: JENKINS_TOKEN not set and 'op' CLI not available." >&2
    exit 2
  fi
fi

COOKIE_JAR=$(mktemp -t jenkins-approve-cookies.XXXXXX)
trap 'rm -f "$COOKIE_JAR"' EXIT

CRUMB=$(curl -sSf -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
  --cookie-jar "$COOKIE_JAR" --cookie "$COOKIE_JAR" \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")

# List pending scripts. Jenkins renders the queue as HTML; the fastest
# machine-parseable path is the Script Console.
GROOVY='jenkins.model.Jenkins.instance
  .getExtensionList(org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval)
  .get(0).getPendingScripts()
  .collect { it.getHash() }
  .each { println(it) }'

# Use a temp file to avoid quoting nightmares with the multi-line Groovy.
GROOVY_TMP=$(mktemp -t jenkins-list-pending.XXXXXX)
trap 'rm -f "$COOKIE_JAR" "$GROOVY_TMP"' EXIT
printf '%s' "$GROOVY" > "$GROOVY_TMP"

echo "[approve] Fetching pending script hashes..."
PENDING=$(curl -sSf -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
  --cookie-jar "$COOKIE_JAR" --cookie "$COOKIE_JAR" \
  -H "$CRUMB" \
  --data-urlencode "script@${GROOVY_TMP}" \
  "${JENKINS_URL}/scriptText" || true)

if [[ -z "$PENDING" ]]; then
  echo "[approve] Nothing pending."
  exit 0
fi

echo "[approve] Pending script hashes:"
echo "$PENDING" | sed 's/^/  /'

# Approve each hash. The Script Console call is the officially-supported
# path (the /scriptApproval/approve web endpoint isn't stable across
# plugin versions).
APPROVE_GROOVY='def approver = jenkins.model.Jenkins.instance
  .getExtensionList(org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval).get(0)
approver.getPendingScripts().collect { it.getHash() }.each { hash ->
  println "approving " + hash
  approver.approveScript(hash)
}'
APPROVE_TMP=$(mktemp -t jenkins-approve-all.XXXXXX)
trap 'rm -f "$COOKIE_JAR" "$GROOVY_TMP" "$APPROVE_TMP"' EXIT
printf '%s' "$APPROVE_GROOVY" > "$APPROVE_TMP"

echo "[approve] Approving..."
curl -sSf -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
  --cookie-jar "$COOKIE_JAR" --cookie "$COOKIE_JAR" \
  -H "$CRUMB" \
  --data-urlencode "script@${APPROVE_TMP}" \
  "${JENKINS_URL}/scriptText"

echo "[approve] Done. Re-trigger seed-jobs:"
echo "  curl -u ${JENKINS_USER}:\$TOKEN -H \"\$CRUMB\" -X POST ${JENKINS_URL}/job/seed-jobs/build"
