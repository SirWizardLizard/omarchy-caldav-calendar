#!/bin/bash

set -euo pipefail

VERSION="$(python3 -c 'import json; print(json.load(open("manifest.json"))["version"])')"
TAG="v${VERSION}"
SHA="$(git rev-parse HEAD)"

if [[ "${GITHUB_EVENT_NAME:-}" == "push" ]] && git rev-parse HEAD^ >/dev/null 2>&1; then
  previous="$(git show HEAD^:manifest.json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' || true)"
  if [[ -n "${previous}" && "${previous}" == "${VERSION}" ]]; then
    echo "manifest version ${VERSION} did not change; skipping"
    exit 0
  fi
fi

if gh release view "${TAG}" >/dev/null 2>&1; then
  echo "release ${TAG} already exists; skipping"
  exit 0
fi

gh release create "${TAG}" \
  --target "${SHA}" \
  --title "CalDav Calendar ${VERSION}" \
  --generate-notes

echo "Created ${TAG} at ${SHA}"
