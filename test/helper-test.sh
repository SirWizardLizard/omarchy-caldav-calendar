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
eds_status="$($ROOT/helper/omarchy-calendar-helper eds-status --provider evolution-data-server)"
jq -e '.status == "present" or .status == "missing"' <<<"$eds_status" >/dev/null
echo "ok - helper EDS status"

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
class ForbiddenRegistry:
    def ref_source(self, uid):
        raise AssertionError("must not look up " + str(uid))
    def commit_source_sync(self, source, cancellable):
        raise AssertionError("must not commit " + str(source))
class Scratch:
    def get_uid(self):
        return "system-calendar"
assert mod.commit_new_source(ForbiddenRegistry(), Scratch()) is None
mod.discard_committed_source(ForbiddenRegistry(), "system-calendar")
mod.discard_committed_source(ForbiddenRegistry(), "")
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

python3 -c 'from importlib.machinery import SourceFileLoader; import sys
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
assert mod.normalize_caldav_url("caldav.forwardemail.net") == "https://caldav.forwardemail.net"
fwd = mod.caldav_candidate_urls("https://caldav.forwardemail.net", "user@example.com")
assert fwd[0] == "https://caldav.forwardemail.net/dav/user@example.com/"
assert "https://caldav.forwardemail.net/dav/" in fwd
typed = mod.caldav_candidate_urls("https://caldav.forwardemail.net/dav/", "user@example.com")
assert typed == ["https://caldav.forwardemail.net/dav/"]
xml = b"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/dav/user@example.com/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <c:calendar-home-set><d:href>/dav/user@example.com/</d:href></c:calendar-home-set>
      </d:prop>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/user@example.com/default/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Personal</d:displayname>
        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>"""
calendars, homes, _principals = mod.parse_caldav_multistatus(xml, "https://caldav.forwardemail.net/dav/user@example.com/")
assert any(item["name"] == "Personal" and item["href"].endswith("/default/") for item in calendars)
assert any(item.endswith("/dav/user@example.com/") for item in homes)
print("ok - helper forwardemail propfind parse")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
probe = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop>
<d:sync-token>http://example.com/ns/sync/1</d:sync-token>
<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>
</d:prop></d:propstat></d:response></d:multistatus>"""
supported, token = mod.parse_sync_support(probe)
assert supported is True
assert token.endswith("/1")
xml = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response><d:href>/dav/cal/abc.ics</d:href><d:propstat><d:prop><d:getetag>1</d:getetag><c:calendar-data>BEGIN:VCALENDAR</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/dav/cal/gone.ics</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
  <d:sync-token>http://example.com/ns/sync/2</d:sync-token>
</d:multistatus>"""
next_token, changed, removed, truncated = mod.parse_sync_collection(xml, "https://caldav.example.com/dav/cal/")
assert next_token.endswith("/2")
assert changed[0]["uid"] == "abc" and "BEGIN:VCALENDAR" in changed[0]["ics"]
assert removed == ["gone"]
coll = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response><d:href>/calendars/A5C7D016-D937-4041-A1FD-436D669B8EE3/</d:href><d:propstat><d:prop><d:getetag>1</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/calendars/meet.ics</d:href><d:propstat><d:prop><c:calendar-data>BEGIN:VCALENDAR</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:sync-token>http://example.com/ns/sync/9</d:sync-token>
</d:multistatus>"""
_tok, coll_changed, coll_removed, _tr = mod.parse_sync_collection(coll, "https://caldav.icloud.com/calendars/")
assert [item["uid"] for item in coll_changed] == ["meet"] and coll_removed == []
assert truncated is False
trunc = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/cal/x.ics</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response><d:sync-token>http://example.com/ns/sync/3</d:sync-token></d:multistatus>"""
_tok, _ch, _rm, truncated = mod.parse_sync_collection(trunc, "https://caldav.example.com/dav/cal/")
assert truncated is True
merged = mod.apply_sync_delta(
  [{"uid": "series", "rid": "1"}, {"uid": "series", "rid": "2"}, {"uid": "keep", "rid": ""}, {"uid": "gone", "rid": ""}],
  ["gone"],
  [{"uid": "series", "rid": "1"}, {"uid": "series", "rid": "3"}],
)
assert [event["uid"] + event["rid"] for event in merged] == ["keep", "series1", "series3"]
kept_failed = mod.apply_sync_delta(
  [{"uid": "series", "rid": "1"}, {"uid": "series", "rid": "2"}],
  [],
  [],
  keep_uids=["series"],
)
assert [event["rid"] for event in kept_failed] == ["1", "2"]
href_merged = mod.apply_sync_delta(
  [{"uid": "1787612053560@forwardemail.net", "hrefUid": "6a8ccb95dd03a22af4200787", "rid": ""}],
  ["6a8ccb95dd03a22af4200787"],
  [],
)
assert href_merged == []
dropped = mod.apply_sync_delta(
  [{"uid": "08749FFE", "hrefUid": "A5C7D016", "rid": ""}],
  [],
  [{"uid": "08749FFE", "hrefUid": "A5C7D016", "rid": ""}],
  keep_uids=["A5C7D016"],
  drop_uids=["08749FFE"],
)
assert dropped == []
cache = {"localTouches": {"cal": {"08749FFE": "delete", "A5C7D016": "delete"}}}
assert set(mod.deleted_touch_keys(cache, "cal")) == {"08749FFE", "A5C7D016"}
pruned = mod.prune_local_touches({"cal": {"08749FFE": "delete", "A5C7D016": "delete", "new": "create"}}, {"cal": ["A5C7D016"]}, {"cal": ["new"]})
assert "A5C7D016" not in pruned.get("cal", {})
assert "new" not in pruned.get("cal", {})
assert pruned["cal"]["08749FFE"] == "delete"
still = mod.prune_local_touches({"cal": {"08749FFE": "delete"}}, {}, None)
assert still["cal"]["08749FFE"] == "delete"
disk_del = {
  "events": [],
  "localTouches": {"cal": {"08749FFE": "delete", "A5C7D016": "delete"}},
}
snap_back = [{"uid": "08749FFE", "hrefUid": "A5C7D016", "calendarId": "cal", "title": "back"}]
held = {}
merged_del = mod.merge_snapshot_with_local(snap_back, disk_del, {"cal": "updated"}, {"cal": ["A5C7D016", "08749FFE"]}, held, {"cal": {"token": "old"}})
assert merged_del == []
assert held["cal"]["token"] == "old"
folder = __import__("tempfile").mkdtemp()
__import__("os").environ["OMARCHY_CALENDAR_CACHE"] = folder
disk_events = [
  {"id": "a1", "uid": "local", "calendarId": "fe", "title": "mine"},
  {"id": "b1", "uid": "keep", "calendarId": "icloud", "title": "old"},
]
mod.write_cache({"ok": True, "calendars": [], "events": disk_events, "rev": 2, "localTouches": {"fe": ["local"]}})
snap = [
  {"id": "a0", "uid": "gone-remote", "calendarId": "fe", "title": "stale"},
  {"id": "b2", "uid": "keep", "calendarId": "icloud", "title": "new"},
]
start_state = {"icloud": {"supported": True, "token": "old"}}
state = {"icloud": {"supported": True, "token": "new"}, "fe": {"supported": True, "token": "fe2"}}
merged_events = mod.merge_snapshot_with_local(snap, mod.read_cache(), {"fe": "updated", "icloud": "updated"}, {"fe": ["local"], "icloud": ["keep"]}, state, start_state)
assert any(event["uid"] == "local" and event["title"] == "mine" for event in merged_events)
assert any(event["uid"] == "keep" and event["title"] == "new" for event in merged_events)
assert state["icloud"]["token"] == "new"
# local UID conflict reverts that calendar token
state = {"fe": {"supported": True, "token": "fe2"}}
start_state = {"fe": {"supported": True, "token": "fe1"}}
mod.merge_snapshot_with_local(snap, mod.read_cache(), {"fe": "updated"}, {"fe": ["local"]}, state, start_state)
assert state["fe"]["token"] == "fe1"
kept = mod.adopt_newer_cache_events({"ok": True, "calendars": [], "events": [{"id": "stale", "uid": "x", "calendarId": "fe"}], "syncState": {}}, 1, {"fe": "unchanged"}, {}, {})
assert any(event["uid"] == "local" for event in kept["events"])
assert kept.get("localTouches", {}).get("fe", {}).get("local") == "delete"
mod.write_cache({"ok": True, "calendars": [], "events": [{"id": "gone"}], "rev": 2, "localTouches": {"fe": {"local": "delete"}}}, bump=True)
stale = {"ok": True, "calendars": [], "events": [{"id": "stale-snap", "uid": "local", "calendarId": "fe"}], "rev": 2, "_modes": {"fe": "updated"}, "_remote": {"fe": ["local"]}}
mod.write_cache(stale)
after = mod.read_cache()
assert not any(event.get("id") == "stale-snap" for event in after["events"])
assert mod.href_event_uid("/dav/user/cal/meet%40ing.ics") == "meet@ing"
probe = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:response><d:propstat><d:prop>
<cs:getctag>abc</cs:getctag>
</d:prop></d:propstat></d:response></d:multistatus>"""
supported, token, ctag = mod.parse_sync_probe(probe)
assert supported is False and ctag == "abc"
state = {}
assert mod.ctag_decision(state, "cal", "abc", True) == "unchanged"
assert mod.ctag_decision(state, "cal", "abc", True) == "unchanged"
assert mod.ctag_decision(state, "cal", "xyz", True) == "eds"
print("ok - helper rfc6578 sync-collection parse")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys
from datetime import UTC, datetime, timedelta
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
try:
    modules = mod.load_eds_modules()
except Exception:
    print("ok - helper forwardemail ics parse skipped")
    raise SystemExit(0)
ics = """BEGIN:VCALENDAR\r
VERSION:2.0\r
BEGIN:VTIMEZONE\r
TZID:America/Chicago\r
BEGIN:STANDARD\r
DTSTART:19701101T020000\r
TZOFFSETFROM:-0600\r
TZOFFSETTO:-0600\r
END:STANDARD\r
END:VTIMEZONE\r
BEGIN:VEVENT\r
UID:1787612053560@forwardemail.net\r
DTSTART;TZID=America/Chicago:20260824T000000\r
DTEND;TZID=America/Chicago:20260824T010000\r
SUMMARY:Test event creation in forwardemail\r
END:VEVENT\r
END:VCALENDAR\r
"""
calendar = {"id": "fe", "name": "Calendar", "color": "#000", "provider": "caldav", "host": "caldav.forwardemail.net", "source": "x"}
parsed, complete = mod.events_from_ics(ics, calendar, None, modules, datetime.now(UTC) - timedelta(days=400), datetime.now(UTC) + timedelta(days=400))
assert complete is True
assert parsed[0]["uid"] == "1787612053560@forwardemail.net"
assert parsed[0]["title"] == "Test event creation in forwardemail"
assert parsed[0]["start"] == "2026-08-24T05:00:00Z"
print("ok - helper forwardemail ics parse")' "$ROOT/helper/omarchy-calendar-helper"
