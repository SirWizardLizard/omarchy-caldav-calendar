#!/bin/bash

set -euo pipefail

PLUGIN_ID="sirwizardlizard.calendar"
REPO_URL="https://github.com/SirWizardLizard/omarchy-caldav-calendar"
MARKETPLACE="HANCORE-linux/omarchy-plugin-marketplace"
SHA="$(git rev-parse HEAD)"
VERSION="$(python3 -c 'import json; print(json.load(open("manifest.json"))["version"])')"

if [[ "${GITHUB_EVENT_NAME:-}" == "push" ]] && git rev-parse HEAD^ >/dev/null 2>&1; then
  previous="$(git show HEAD^:manifest.json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' || true)"
  if [[ -n "${previous}" && "${previous}" == "${VERSION}" ]]; then
    echo "manifest version ${VERSION} did not change; skipping"
    exit 0
  fi
fi

title="[Verify]: ${PLUGIN_ID}"
body="$(cat <<EOF
### Verification action

Verify and publish a newer upstream commit

### Plugin ID

${PLUGIN_ID}

### Repository URL

${REPO_URL}

### Target commit

${SHA}

### Verification acknowledgment

- [x] I understand that only the exact target commit can become a verified marketplace snapshot and that verification is not a security audit.
EOF
)"

if [[ -n "${MARKETPLACE_TOKEN:-}" ]]; then
  existing="$(GH_TOKEN="${MARKETPLACE_TOKEN}" gh issue list --repo "${MARKETPLACE}" --state open --search "in:title ${title}" --json number,title --jq '.[0].number // empty')"
  if [[ -n "${existing}" ]]; then
    GH_TOKEN="${MARKETPLACE_TOKEN}" gh issue edit "${existing}" --repo "${MARKETPLACE}" --body "${body}"
    echo "Updated ${MARKETPLACE}#${existing} for ${VERSION} ${SHA}"
    exit 0
  fi
  url="$(GH_TOKEN="${MARKETPLACE_TOKEN}" gh issue create --repo "${MARKETPLACE}" --title "${title}" --body "${body}")"
  echo "Opened ${url}"
  exit 0
fi

echo "MARKETPLACE_TOKEN is not set; opening a reminder on this repo"
reminder="$(cat <<EOF
manifest.json is now ${VERSION} at \`${SHA}\`.

Add a \`MARKETPLACE_TOKEN\` repo secret (classic PAT with \`public_repo\`) to file this automatically, or open:

https://github.com/${MARKETPLACE}/issues/new?template=verify-plugin.yml

Use action **Verify and publish a newer upstream commit**, plugin id \`${PLUGIN_ID}\`, repo \`${REPO_URL}\`, commit \`${SHA}\`.
EOF
)"
gh issue create --title "File marketplace verify for ${VERSION}" --body "${reminder}"
