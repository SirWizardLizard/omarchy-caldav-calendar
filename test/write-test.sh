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

python3 - "$ROOT/helper/omarchy-calendar-helper" <<'PY'
import importlib.machinery
import importlib.util
import sys
from uuid import uuid4

spec = importlib.util.spec_from_loader("helper", importlib.machinery.SourceFileLoader("helper", sys.argv[1]))
helper = importlib.util.module_from_spec(spec)
sys.modules["helper"] = helper
spec.loader.exec_module(helper)

modules = helper.load_eds_modules()
registry = modules.EDataServer.SourceRegistry.new_sync(None)
uid = f"omarchy-calendar-caldav-{uuid4()}"
scratch = modules.EDataServer.Source.new_with_uid(uid, None)
scratch.set_display_name("Omarchy Calendar Temporary Commit Test")
scratch.set_enabled(True)
collection = scratch.get_extension(modules.EDataServer.SOURCE_EXTENSION_COLLECTION)
collection.set_backend_name("webdav")
collection.set_identity("omarchy-test")
collection.set_calendar_enabled(True)

try:
    source = helper.commit_new_source(registry, scratch)
    assert source is not None, "commit_new_source returned None"
    assert source.ref_dbus_object() is not None, "commit_new_source returned a detached source"
    helper.quiet_omarchy_collection(source, registry, modules)
    helper.quiet_omarchy_collection(scratch, registry, modules)
finally:
    helper.discard_committed_source(registry, uid)

assert registry.ref_source(uid) is None, "rollback left the source behind"
PY

echo "ok - EDS commit returns a registry-backed source"
