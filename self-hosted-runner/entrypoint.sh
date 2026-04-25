#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────────────
#  Banner
# ────────────────────────────────────────────────────────────────
echo ""
echo "                       ╔╦╦╗  ╔═╗                         "
echo "▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ ║╠╣╚╦═╬╝╠═╗ ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁"
echo "══════════════════════ ║║║║║║║╔╣║║ ══════════════════════"
echo "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ ╚╩╩═╣╔╩═╣╔╝ ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
echo "                           ╚╝  ╚╝                        "
echo ""

# ────────────────────────────────────────────────────────────────
#  Validate environment
# ────────────────────────────────────────────────────────────────
if [[ -z "${GITHUB_URL:-}" && -z "${REPO_URL:-}" && -z "${ORG_NAME:-}" ]]; then
  echo "ERROR: You must set REPO_URL=https://github.com/owner/repo or ORG_NAME=org + RUNNER_SCOPE=org"
  exit 1
fi

if [[ -z "${ACCESS_TOKEN:-}" ]]; then
  echo "ERROR: ACCESS_TOKEN (a PAT) is required"
  exit 1
fi

# ────────────────────────────────────────────────────────────────
#  Build API URL and Runner URL
# ────────────────────────────────────────────────────────────────
TOKEN_API=""
RUNNER_URL=""

if [[ -n "${REPO_URL:-}" ]]; then
  owner=$(echo "$REPO_URL" | awk -F/ '{print $(NF-1)}')
  repo=$(echo "$REPO_URL" | awk -F/ '{print $NF}')
  TOKEN_API="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
  RUNNER_URL="$REPO_URL"
elif [[ "${RUNNER_SCOPE:-}" == "org" && -n "${ORG_NAME:-}" ]]; then
  TOKEN_API="https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token"
  RUNNER_URL="https://github.com/${ORG_NAME}"
fi

# ────────────────────────────────────────────────────────────────
#  Obtain a short-lived registration token
# ────────────────────────────────────────────────────────────────
echo "Requesting registration token from GitHub..."
reg_token=$(curl -fsSL -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${TOKEN_API}" | jq -r .token)

if [[ -z "$reg_token" || "$reg_token" == "null" ]]; then
  echo "ERROR: Failed to get registration token from GitHub."
  exit 1
fi
echo "Successfully obtained registration token."

# ────────────────────────────────────────────────────────────────
#  Configure and start the runner
# ────────────────────────────────────────────────────────────────
name="${RUNNER_NAME:-ephemeral-$(hostname)-$RANDOM}"

echo ""
echo "Registering runner:"
echo "  Name:   $name"
echo "  URL:    $RUNNER_URL"
echo "  Labels: ${LABELS:-none}"
echo ""

cd /actions-runner

# Remove any leftover config from a previous run in the same container
# (happens on restart: container filesystem persists, but runner already exited)
rm -f .runner .credentials .credentials_rsaparams

./config.sh \
  --url "${RUNNER_URL}" \
  --token "${reg_token}" \
  --name "${name}" \
  --ephemeral \
  --unattended \
  --replace \
  --disableupdate \
  ${LABELS:+--labels "${LABELS}"}

echo ""
echo "Runner configured successfully. Launching... 🚀"
echo ""

exec ./run.sh
