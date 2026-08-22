#!/bin/bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ${OMARCHY_CALENDAR_WRITE_TEST:-} != "1" ]]; then
  echo "ok - EDS write test skipped"
  exit 0
fi

created=$("$ROOT/helper/omarchy-calendar-helper" create-event \
  --provider evolution-data-server \
  --calendar-id system-calendar \
  --title "Omarchy Calendar Temporary Test" \
  --from 2026-08-20T18:00:00Z \
  --to 2026-08-20T18:15:00Z \
  --description "Temporary event created and deleted by omarchy-calendar write test")
uid=$(jq -r '.uid' <<<"$created")

cleanup() {
  if [[ -n ${uid:-} ]]; then
    "$ROOT/helper/omarchy-calendar-helper" delete-event --provider evolution-data-server --calendar-id system-calendar --uid "$uid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

jq -e '.ok == true and .calendar.id == "system-calendar" and (.uid | length) > 0' <<<"$created" >/dev/null

"$ROOT/helper/omarchy-calendar-helper" snapshot --provider evolution-data-server --from 2026-08-20T00:00:00Z --to 2026-08-21T00:00:00Z |
  jq -e --arg uid "$uid" '.events[] | select(.uid == $uid and .title == "Omarchy Calendar Temporary Test")' >/dev/null

updated=$("$ROOT/helper/omarchy-calendar-helper" update-event \
  --provider evolution-data-server \
  --calendar-id system-calendar \
  --uid "$uid" \
  --title "Omarchy Calendar Temporary Test Updated" \
  --from 2026-08-20T19:00:00Z \
  --to 2026-08-20T19:30:00Z \
  --description "Temporary event updated and deleted by omarchy-calendar write test")
jq -e '.ok == true and .event.title == "Omarchy Calendar Temporary Test Updated"' <<<"$updated" >/dev/null

"$ROOT/helper/omarchy-calendar-helper" snapshot --provider evolution-data-server --from 2026-08-20T00:00:00Z --to 2026-08-21T00:00:00Z |
  jq -e --arg uid "$uid" '.events[] | select(.uid == $uid and .title == "Omarchy Calendar Temporary Test Updated")' >/dev/null

"$ROOT/helper/omarchy-calendar-helper" delete-event --provider evolution-data-server --calendar-id system-calendar --uid "$uid" >/dev/null
uid=""

echo "ok - EDS create/update/delete write test"
