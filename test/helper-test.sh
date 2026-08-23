#!/bin/bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp)"
cache_dir="$(mktemp -d)"
trap 'rm -rf "$cache_dir" "$tmp"' EXIT
export OMARCHY_CALENDAR_CACHE="$cache_dir"
payload="$($ROOT/helper/omarchy-calendar-helper snapshot --provider mock --from 2026-08-01T00:00:00Z --to 2026-09-01T00:00:00Z)"
jq -e '.ok == true and .provider == "mock" and (.events | length) >= 1 and (.calendars | length) == 1' <<<"$payload" >/dev/null
echo "ok - helper mock snapshot"
cached="$($ROOT/helper/omarchy-calendar-helper snapshot --from-cache --provider mock --from 2026-08-01T00:00:00Z --to 2026-09-01T00:00:00Z)"
jq -e '.ok == true and .cached == true and (.events | length) >= 1' <<<"$cached" >/dev/null
echo "ok - helper cache snapshot"
printf '{"calendars":[{"id":"personal","name":"Home","color":"#f38ba8"}]}' | "$ROOT/helper/omarchy-calendar-helper" update-calendars --provider mock >/dev/null
renamed="$($ROOT/helper/omarchy-calendar-helper snapshot --from-cache --provider mock --from 2026-08-01T00:00:00Z --to 2026-09-01T00:00:00Z)"
jq -e '.ok == true and (.calendars[] | select(.id == "personal") | .name == "Home" and .color == "#f38ba8")' <<<"$renamed" >/dev/null
echo "ok - helper calendar rename and color"

if eds_payload="$($ROOT/helper/omarchy-calendar-helper list-calendars --provider evolution-data-server 2>/dev/null)"; then
  jq -e '.ok == true and .provider == "evolution-data-server" and (.calendars | type) == "array"' <<<"$eds_payload" >/dev/null
  echo "ok - helper EDS calendar listing"
else
  echo "ok - helper EDS calendar listing skipped"
fi

if "$ROOT/helper/omarchy-calendar-helper" snapshot --provider unknown >"$tmp" 2>/dev/null; then
  echo "not ok - unknown provider should fail" >&2
  exit 1
fi
jq -e '.ok == false and .error.code == "unknown-provider"' "$tmp" >/dev/null
echo "ok - helper unknown provider failure"

if printf '{}' | "$ROOT/helper/omarchy-calendar-helper" setup-caldav --provider evolution-data-server >"$tmp" 2>/dev/null; then
  echo "not ok - setup-caldav without fields should fail" >&2
  exit 1
fi
jq -e '.ok == false and .error.code == "operation-failed"' "$tmp" >/dev/null
echo "ok - helper setup-caldav validates required fields"

if "$ROOT/helper/omarchy-calendar-helper" remove-calendar --provider evolution-data-server >"$tmp" 2>/dev/null; then
  echo "not ok - remove-calendar without id should fail" >&2
  exit 1
fi
jq -e '.ok == false and .error.code == "operation-failed"' "$tmp" >/dev/null
echo "ok - helper remove-calendar validates id"

if "$ROOT/helper/omarchy-calendar-helper" update-event --provider evolution-data-server --calendar-id missing --from 2026-08-20T09:00:00Z --to 2026-08-20T10:00:00Z >"$tmp" 2>/dev/null; then
  echo "not ok - update-event without uid should fail" >&2
  exit 1
fi
jq -e '.ok == false and .error.code == "operation-failed"' "$tmp" >/dev/null
echo "ok - helper update-event validates uid"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys; mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module(); assert mod.normalize_rrule("never") == ""; assert mod.normalize_rrule("weekly") == "FREQ=WEEKLY"; assert mod.normalize_rrule("FREQ=WEEKLY;BYDAY=TU,TH") == "FREQ=WEEKLY;BYDAY=TU,TH"; assert mod.normalize_rrule("RRULE:FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1") == "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1"; print("ok - helper rrule normalize")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys; mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
class C:
    def as_ical_string(self):
        return "BEGIN:VEVENT\r\nRRULE:FREQ=WEEKLY;BYDAY=TU,TH\r\nEND:VEVENT\r\n"
assert mod.extract_rrule(C()) == "FREQ=WEEKLY;BYDAY=TU,TH"
print("ok - helper extract rrule")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys; mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
assert mod.apply_meeting("none", "", "Office") == "Office"
assert mod.apply_meeting("link", "https://zoom.us/j/123", "") == "https://zoom.us/j/123"
assert "meet.google.com" in mod.apply_meeting("link", "https://meet.google.com/abc-defg-hij", "Home")
assert mod.apply_meeting("link", "meet.google.com/moy-mhcz-ogi", "") == "https://meet.google.com/moy-mhcz-ogi"
assert "teams.microsoft.com" in mod.apply_meeting("link", "https://teams.microsoft.com/l/meetup-join/x", "")
try:
    mod.apply_meeting("link", "not-a-url", "")
except ValueError:
    pass
else:
    raise SystemExit("expected missing meeting link to fail")
print("ok - helper apply meeting")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
empty = mod.read_reminders()
assert empty["ok"] is True and empty["minutes"] == 10
saved = mod.write_reminders({"minutes": 5, "fired": ["a|2026-08-21T15:00:00Z|5"]})
assert saved["minutes"] == 5 and saved["fired"] == ["a|2026-08-21T15:00:00Z|5"]
loaded = mod.read_reminders()
assert loaded["minutes"] == 5 and loaded["fired"] == ["a|2026-08-21T15:00:00Z|5"]
print("ok - helper reminders state")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import json, os, sys, tempfile
from pathlib import Path
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
folder = Path(tempfile.mkdtemp())
config = folder / "shell.json"
config.write_text(json.dumps({"bar": {"centerAnchor": "omarchy.clock", "layout": {"center": [{"id": "sirwizardlizard.calendar"}]}}}))
os.environ["OMARCHY_SHELL_CONFIG"] = str(config)
result = mod.ensure_center_anchor("sirwizardlizard.calendar")
assert result["changed"] is True
assert json.loads(config.read_text())["bar"]["centerAnchor"] == "sirwizardlizard.calendar"
again = mod.ensure_center_anchor("sirwizardlizard.calendar")
assert again["changed"] is False
print("ok - helper center anchor")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import json, os, sys, tempfile
from pathlib import Path
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
folder = Path(tempfile.mkdtemp())
os.environ["OMARCHY_CALENDAR_CACHE"] = str(folder)
mod = SourceFileLoader("omarchy_calendar_helper_limits", sys.argv[1]).load_module()
huge = folder / "cache.json"
huge.write_bytes(b"{" + (b"x" * (mod.MAX_CACHE_BYTES + 10)))
assert mod.read_cache() is None
events = [{"id": str(i), "title": "t", "start": "2026-08-01T00:00:00Z", "end": "2026-08-01T01:00:00Z"} for i in range(mod.MAX_EVENTS + 50)]
mod.write_cache({"ok": True, "calendars": [{"id": "c"}] * (mod.MAX_CALENDARS + 5), "events": events})
cache = mod.read_cache()
assert cache is not None
assert len(cache["events"]) <= mod.MAX_EVENTS
assert len(cache["calendars"]) <= mod.MAX_CALENDARS
saved = mod.write_reminders({"minutes": 10, "fired": [f"id|{i}" for i in range(mod.MAX_FIRED + 20)]})
assert saved["ok"] is True
assert len(saved["fired"]) <= mod.MAX_FIRED
too_big = {"ok": True, "provider": "mock", "events": [{"id": "x", "title": "y" * 200} for _ in range(mod.MAX_EVENTS)]}
bounded = mod.bound_payload(too_big)
assert len(bounded["events"]) == mod.MAX_EVENTS
print("ok - helper bounds cache reminders and snapshots")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
assert mod.is_omarchy_source_uid("omarchy-calendar-caldav-9fb4ee14-4efd-4564-a7dd-adc2f704d525")
assert not mod.is_omarchy_source_uid("c3742f32c586dbe48f75eeb097fe4ed289f3bc2b")
class Child:
    def __init__(self, uid, parent):
        self._uid = uid
        self._parent = parent
    def get_uid(self):
        return self._uid
    def get_parent(self):
        return self._parent
assert mod.is_omarchy_collection_child(Child("c3742f32c586dbe48f75eeb097fe4ed289f3bc2b", "omarchy-calendar-caldav-parent"))
assert not mod.is_omarchy_collection_child(Child("evolution-icloud", None))
assert not mod.is_omarchy_collection_child(Child("omarchy-calendar-caldav-own", "omarchy-calendar-caldav-parent"))
print("ok - helper omarchy calendar uid")' "$ROOT/helper/omarchy-calendar-helper"
