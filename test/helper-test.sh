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
eds_status="$($ROOT/helper/omarchy-calendar-helper eds-status --provider evolution-data-server || true)"
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

python3 -c 'from importlib.machinery import SourceFileLoader; import sys; mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module(); assert mod.normalize_rrule("never") == ""; assert mod.normalize_rrule("weekly") == "FREQ=WEEKLY"; assert mod.normalize_rrule("FREQ=WEEKLY;BYDAY=TU,TH") == "FREQ=WEEKLY;BYDAY=TU,TH"; assert mod.normalize_rrule("RRULE:FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1") == "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1"; assert mod.normalize_rrule("FREQ=DAILY;COUNT=1\r\nATTENDEE:mailto:other@example.com") == ""; assert mod.ics_escape("first\rsecond") == "first\\nsecond"; print("ok - helper rrule normalize")' "$ROOT/helper/omarchy-calendar-helper"

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

python3 -c 'from importlib.machinery import SourceFileLoader; import json, os, sys, tempfile, threading
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

python3 -c 'from importlib.machinery import SourceFileLoader; import json, os, sys, tempfile, threading
from pathlib import Path
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
folder = Path(tempfile.mkdtemp())
os.environ["OMARCHY_CALENDAR_CACHE"] = str(folder)
mod = SourceFileLoader("omarchy_calendar_helper_limits", sys.argv[1]).load_module()
huge = folder / "cache.json"
huge.write_bytes(b"{" + (b"x" * (mod.MAX_CACHE_BYTES + 10)))
assert mod.read_cache() is None
huge.unlink()
baseline = mod.write_cache({"ok": True, "calendars": [{"id": "old"}], "events": [{"id": "old", "title": "kept"}]})
assert baseline is not None
events = [{"id": str(i), "title": "t", "start": "2026-08-01T00:00:00Z", "end": "2026-08-01T01:00:00Z"} for i in range(mod.MAX_EVENTS + 50)]
assert mod.write_cache({"ok": True, "calendars": [{"id": "c"}] * (mod.MAX_CALENDARS + 5), "events": events}) is None
cache = mod.read_cache()
assert cache is not None and cache["events"][0]["id"] == "old" and cache["calendars"][0]["id"] == "old"
assert mod.write_cache({"ok": True, "calendars": [], "events": [{"id": "large", "title": "x" * mod.MAX_CACHE_BYTES}]}) is None
assert mod.read_cache()["events"][0]["id"] == "old"
saved = mod.write_reminders({"minutes": 10, "fired": [f"id|{i}" for i in range(mod.MAX_FIRED + 20)]})
assert saved["ok"] is True
assert len(saved["fired"]) <= mod.MAX_FIRED
too_big = {"ok": True, "provider": "mock", "events": [{"id": "x", "title": "y" * 200} for _ in range(mod.MAX_EVENTS)]}
bounded = mod.bound_payload(too_big)
assert len(bounded["events"]) == mod.MAX_EVENTS
race_folder = Path(tempfile.mkdtemp())
os.environ["OMARCHY_CALENDAR_CACHE"] = str(race_folder)
failures = []
def add(index):
  try:
    mod.merge_cache_event({"id": f"event-{index}", "uid": f"uid-{index}", "calendarId": "cal", "rid": "", "title": str(index)})
  except Exception as error:
    failures.append(error)
threads = [threading.Thread(target=add, args=(index,)) for index in range(12)]
for thread in threads: thread.start()
for thread in threads: thread.join()
assert failures == []
assert {event["id"] for event in mod.read_cache()["events"]} == {f"event-{index}" for index in range(12)}
journal_folder = Path(tempfile.mkdtemp())
os.environ["OMARCHY_CALENDAR_CACHE"] = str(journal_folder)
old_event_limit = mod.MAX_EVENTS
mod.MAX_EVENTS = 1
try:
  assert mod.write_cache({"ok": True, "calendars": [], "events": [{"id": "old", "uid": "old", "calendarId": "cal"}]}) is not None
  mod.merge_cache_event({"id": "new", "uid": "new", "calendarId": "cal", "rid": ""})
  journal_cache = mod.read_cache()
  assert [event["id"] for event in journal_cache["events"]] == ["old"]
  assert mod.deleted_touch_keys(journal_cache, "cal") == [] and mod.local_touch_map(journal_cache)["cal"]
  assert journal_cache["rev"] >= max(record["rev"] for record in mod.local_touch_map(journal_cache)["cal"].values())
  assert mod.dirty_touches_file().is_file()
finally:
  mod.MAX_EVENTS = old_event_limit
snapshot = {"events": [{"id": "old", "uid": "old", "calendarId": "cal"}, {"id": "new", "uid": "new", "hrefUid": "new-href", "calendarId": "cal"}], "syncState": {"cal": {"token": "new"}}}
acknowledged = mod.reconcile_snapshot_with_cache(snapshot, journal_cache, journal_cache["rev"], {"cal": "updated"}, {"cal": ["new", "new-href"]}, {}, {})
assert acknowledged["localTouches"] == {} and any(event.get("hrefUid") == "new-href" for event in acknowledged["events"])
assert mod.write_cache(acknowledged) is not None
assert not mod.dirty_touches_file().exists()
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
assert mod.normalize_caldav_url("HTTPS://caldav.example.com") == "HTTPS://caldav.example.com"
fwd = mod.caldav_candidate_urls("https://caldav.forwardemail.net", "user@example.com")
assert fwd[0] == "https://caldav.forwardemail.net/dav/user@example.com/"
assert "https://caldav.forwardemail.net/dav/" in fwd
typed = mod.caldav_candidate_urls("https://caldav.forwardemail.net/dav/", "user@example.com")
assert typed == ["https://caldav.forwardemail.net/dav/"]
try:
    mod.eds_setup_caldav({"url": "https://user:secret@caldav.example.com/", "username": "user", "password": "secret"})
except ValueError as error:
    assert "embedded credentials" in str(error)
else:
    raise AssertionError("embedded URL credentials should be rejected")
xml = b"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/dav/user@example.com/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <c:calendar-home-set><d:href>/dav/user@example.com/</d:href></c:calendar-home-set>
      </d:prop><d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/user@example.com/default/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Personal</d:displayname>
        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      </d:prop><d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"""
calendars, homes, _principals = mod.parse_caldav_multistatus(xml, "https://caldav.forwardemail.net/dav/user@example.com/")
assert any(item["name"] == "Personal" and item["href"].endswith("/default/") for item in calendars)
assert any(item.endswith("/dav/user@example.com/") for item in homes)
rejected, rejected_homes, _principals = mod.parse_caldav_multistatus(xml.replace(b"200 OK", b"404 Not Found"), "https://caldav.forwardemail.net/dav/user@example.com/")
assert rejected == [] and rejected_homes == []
try:
    mod.parse_caldav_multistatus(b"<root xmlns:d=\"DAV:\"><d:response/></root>", "https://caldav.forwardemail.net/")
except mod.ET.ParseError:
    pass
else:
    raise AssertionError("non-DAV discovery root was accepted")
print("ok - helper forwardemail propfind parse")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys
from datetime import UTC, datetime
mod = SourceFileLoader("omarchy_calendar_helper", sys.argv[1]).load_module()
probe = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop>
<d:sync-token>http://example.com/ns/sync/1</d:sync-token>
<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"""
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
def parse_fails(payload, base="https://caldav.example.com/dav/cal/"):
  try:
    mod.parse_sync_collection(payload, base)
  except mod.ET.ParseError:
    return True
  return False
unsafe = b"""<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>https://attacker.invalid/x.ics</d:href><d:propstat><d:prop><c:calendar-data>BEGIN:VCALENDAR</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:sync-token>next</d:sync-token></d:multistatus>"""
assert parse_fails(unsafe)
sibling = unsafe.replace(b"https://attacker.invalid/x.ics", b"/dav/other/x.ics")
assert parse_fails(sibling)
duplicate_token = xml.replace(b"</d:multistatus>", b"<d:sync-token>duplicate</d:sync-token></d:multistatus>")
assert parse_fails(duplicate_token)
entity_xml = b"""<!DOCTYPE d:multistatus [<!ENTITY token "expanded">]><d:multistatus xmlns:d="DAV:"><d:sync-token>&token;</d:sync-token></d:multistatus>"""
assert parse_fails(entity_xml)
utf16_entity = """<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE d:multistatus [<!ENTITY token "expanded">]><d:multistatus xmlns:d="DAV:"><d:sync-token>&token;</d:sync-token></d:multistatus>""".encode("utf-16")
assert parse_fails(utf16_entity)
old_xml_limit = mod.MAX_DAV_XML_ELEMENTS
mod.MAX_DAV_XML_ELEMENTS = 3
try:
  assert parse_fails(xml)
finally:
  mod.MAX_DAV_XML_ELEMENTS = old_xml_limit
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
invalid_revision = mod.local_touch_map({"localTouches": {"cal": {"uid": {"op": "create", "uid": "uid", "rev": "invalid"}}}})
assert invalid_revision["cal"]["uid"]["rev"] == 0
legacy = mod.local_touch_map(cache)
assert mod.prune_local_touches(legacy, {}, None)["cal"]
assert mod.prune_local_touches(legacy, {}, {"cal": set()})["cal"]
assert mod.prune_local_touches(legacy, {}, None, None, 0, {"cal"}) == {}
event = {"uid": "08749FFE", "hrefUid": "A5C7D016", "calendarId": "cal", "rid": ""}
disk_del = {"events": []}
mod.note_event_touch(disk_del, event, "delete", "series")
records = list(disk_del["localTouches"]["cal"].values())
assert len(records) == 1 and mod.touch_record_aliases(records[0]) == {"08749FFE", "A5C7D016"}
assert mod.prune_local_touches(disk_del["localTouches"], {}, None).get("cal")
assert mod.prune_local_touches(disk_del["localTouches"], {"cal": ["A5C7D016"]}, None) == {}
assert mod.prune_local_touches(disk_del["localTouches"], {}, {"cal": ["08749FFE", "A5C7D016"]}, None, None, {"cal"}).get("cal")
assert mod.prune_local_touches(disk_del["localTouches"], {}, {"cal": []}, None, None, {"cal"}) == {}
created = {"events": []}
mod.note_event_touch(created, event, "create", "series")
created_key = next(iter(created["localTouches"]["cal"]))
assert mod.prune_local_touches(created["localTouches"], {}, None, {"cal": [created_key]}) == {}
instances = {"events": []}
mod.note_event_touch(instances, {**event, "rid": "20260801T100000Z"}, "delete")
mod.note_event_touch(instances, {**event, "rid": "20260802T100000Z"}, "delete")
assert len(instances["localTouches"]["cal"]) == 2
instance_events = [{**event, "rid": "20260801T100000Z"}, {**event, "rid": "20260802T100000Z"}]
remote = set(mod.event_sync_keys(instance_events[0])) | mod.event_occurrence_keys(instance_events[0])
instance_state = {"cal": {"token": "new"}}
assert mod.merge_snapshot_with_local(instance_events, instances, {"cal": "updated"}, {"cal": remote}, instance_state, {"cal": {"token": "old"}}) == []
assert instance_state["cal"]["token"] == "old"
first_key = next(key for key, record in instances["localTouches"]["cal"].items() if record["rid"] == "20260801T100000Z")
remaining_instances = mod.prune_local_touches(instances["localTouches"], {}, None, {"cal": [first_key]})
assert len(remaining_instances["cal"]) == 1
mod.note_event_touch(instances, event, "delete", "series")
assert len(instances["localTouches"]["cal"]) == 1
snap_back = [{"uid": "08749FFE", "hrefUid": "A5C7D016", "calendarId": "cal", "title": "back"}]
held = {}
merged_del = mod.merge_snapshot_with_local(snap_back, disk_del, {"cal": "updated"}, {"cal": ["A5C7D016", "08749FFE"]}, held, {"cal": {"token": "old"}})
assert merged_del == []
assert held["cal"]["token"] == "old"
remote_event = {"id": "cal:uid", "uid": "uid", "hrefUid": "href", "calendarId": "cal", "title": "remote"}
local_event = {"id": "cal:uid", "uid": "uid", "calendarId": "cal", "title": "local"}
concurrent_disk = {"rev": 3, "events": [local_event], "syncState": {"cal": {"token": "old"}}, "localTouches": {"cal": {"series:href": {"op": "create", "uid": "uid", "hrefUid": "href", "rid": "", "scope": "series", "rev": 3}}}}
concurrent = mod.reconcile_snapshot_with_cache({"events": [remote_event], "syncState": {"cal": {"token": "new"}}}, concurrent_disk, 2, {"cal": "updated"}, {"cal": ["uid", "href"]}, concurrent_disk["syncState"], {})
assert concurrent["events"][0]["title"] == "local" and concurrent["localTouches"]["cal"]
assert concurrent["syncState"]["cal"]["token"] == "old"
__import__("os").environ["OMARCHY_CALENDAR_CACHE"] = __import__("tempfile").mkdtemp()
persisted_concurrent = mod.write_cache_locked(concurrent, False, concurrent_disk)
assert persisted_concurrent["events"][0]["title"] == "local" and persisted_concurrent["localTouches"]["cal"]
assert persisted_concurrent["syncState"]["cal"]["token"] == "old"
older_disk = {**concurrent_disk, "rev": 2, "localTouches": {"cal": {"series:href": {**concurrent_disk["localTouches"]["cal"]["series:href"], "rev": 1}}}}
acknowledged = mod.reconcile_snapshot_with_cache({"events": [remote_event], "syncState": {"cal": {"token": "new"}}}, older_disk, 2, {"cal": "updated"}, {"cal": ["uid", "href"]}, older_disk["syncState"], {})
assert acknowledged["events"] == [remote_event] and acknowledged["localTouches"] == {}
assert acknowledged["events"][0]["hrefUid"] == "href"
removed_disk = {"rev": 3, "calendars": [], "events": [], "syncState": {}}
stale_calendar = {"id": "cal", "name": "Removed"}
removed_race = mod.reconcile_snapshot_with_cache({"calendars": [stale_calendar], "events": [remote_event], "syncState": {"cal": {"token": "new"}}}, removed_disk, 2, {"cal": "updated"}, {"cal": ["uid", "href"]}, {}, {})
assert removed_race["calendars"] == [] and removed_race["events"] == [] and removed_race["syncState"] == {}
full_deleted_disk = {"rev": 2, "calendars": [stale_calendar], "events": [], "localTouches": disk_del["localTouches"]}
full_deleted = mod.reconcile_snapshot_with_cache({"calendars": [stale_calendar], "events": [], "syncState": {"cal": {"token": "new"}}, "_full": {"cal": True}}, full_deleted_disk, 2, {"cal": "updated"}, {"cal": []}, {}, {})
assert full_deleted["events"] == [] and full_deleted["localTouches"] == {}
created_folder = __import__("tempfile").mkdtemp()
__import__("os").environ["OMARCHY_CALENDAR_CACHE"] = created_folder
created_master = {"id": "cal:created", "uid": "created", "calendarId": "cal", "rid": "", "title": "Created series"}
created_occurrences = [{**created_master, "id": "cal:created:1", "rid": "1"}, {**created_master, "id": "cal:created:2", "rid": "2"}]
mod.write_cache({"ok": True, "calendars": [{"id": "cal"}], "events": [], "syncState": {"cal": {"token": "old"}}, "rev": 2})
mod.merge_cache_created_series(created_occurrences, created_master)
created_cache = mod.read_cache()
assert [item["rid"] for item in created_cache["events"]] == ["1", "2"]
created_touches = list(created_cache["localTouches"]["cal"].values())
assert len(created_touches) == 1 and created_touches[0]["scope"] == "series" and created_touches[0]["op"] == "create"
assert [item["rid"] for item in mod.merge_snapshot_with_local([], created_cache, {"cal": "unchanged"}, {}, created_cache["syncState"], created_cache["syncState"])] == ["1", "2"]
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
assert [record.get("op") for record in kept.get("localTouches", {}).get("fe", {}).values()] == ["delete"]
mod.write_cache({"ok": True, "calendars": [], "events": [{"id": "gone"}], "syncState": {"fe": {"token": "old"}}, "rev": 2, "localTouches": {"fe": {"local": "delete"}}}, bump=True)
stale = {"ok": True, "calendars": [], "events": [{"id": "stale-snap", "uid": "local", "calendarId": "fe"}], "syncState": {"fe": {"token": "new"}}, "rev": 2, "_modes": {"fe": "updated"}, "_remote": {"fe": ["local"]}}
mod.write_cache(stale)
after = mod.read_cache()
assert not any(event.get("id") == "stale-snap" for event in after["events"])
assert after["syncState"]["fe"]["token"] == "old"
assert mod.href_event_uid("/dav/user/cal/meet%40ing.ics") == "meet@ing"
probe = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:response><d:propstat><d:prop>
<cs:getctag>abc</cs:getctag>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"""
supported, token, ctag = mod.parse_sync_probe(probe)
assert supported is False and ctag == "abc"
oversized_ctag = probe.replace(b"abc", b"x" * (mod.MAX_DAV_TOKEN_BYTES + 1))
assert mod.parse_sync_probe(oversized_ctag) == (False, "", "")
state = {}
assert mod.ctag_decision(state, "cal", "abc", True) == "eds"
state["cal"] = {"supported": False, "ctag": "abc", "filled": True}
assert mod.ctag_decision(state, "cal", "abc", True) == "unchanged"
assert mod.ctag_decision(state, "cal", "xyz", True) == "eds"
covered = {"range": {"start": "2026-01-01T00:00:00Z", "end": "2027-01-01T00:00:00Z"}}
assert mod.cache_covers_range(covered, datetime(2026, 8, 1, tzinfo=UTC), datetime(2026, 9, 1, tzinfo=UTC))
assert not mod.cache_covers_range(covered, datetime(2025, 12, 31, tzinfo=UTC), datetime(2026, 9, 1, tzinfo=UTC))
assert not mod.cache_covers_range(covered, datetime(2026, 8, 1, tzinfo=UTC), datetime(2027, 1, 2, tzinfo=UTC))
covered["syncState"] = {"cal": {"supported": True, "token": "token", "filled": True}}
assert not mod.invalidate_out_of_range_sync_state(covered, datetime(2026, 8, 1, tzinfo=UTC), datetime(2026, 9, 1, tzinfo=UTC))
assert covered["syncState"]["cal"]["filled"] is True
assert mod.invalidate_out_of_range_sync_state(covered, datetime(2026, 8, 1, tzinfo=UTC), datetime(2027, 1, 2, tzinfo=UTC))
assert covered["syncState"]["cal"]["filled"] is False
print("ok - helper rfc6578 sync-collection parse")' "$ROOT/helper/omarchy-calendar-helper"

python3 -c 'from importlib.machinery import SourceFileLoader; import sys
from datetime import UTC, datetime, timedelta
mod = SourceFileLoader("omarchy_calendar_helper_recurrence", sys.argv[1]).load_module()
class Value:
  def get_tzid(self): return ""
  def is_date(self): return False
  def get_year(self): return 2026
  def get_month(self): return 8
  def get_day(self): return 1
class Stamp:
  def convert_to_zone(self, zone): return self
  def set_timezone(self, zone): pass
  def set_year(self, value): pass
  def set_month(self, value): pass
  def set_day(self, value): pass
class Existing:
  def __init__(self): self.recurrence_id = None
  def get_dtstart(self): return Value()
  def get_dtend(self): return Value()
  def set_summary(self, value): pass
  def set_location(self, value): pass
  def set_dtstart(self, value): pass
  def set_dtend(self, value): pass
  def set_recurrenceid(self, value): self.recurrence_id = value
  def clone(self): return self
class Client:
  def __init__(self): self.get_rids = []; self.mods = []
  def is_readonly(self): return False
  def get_object_sync(self, uid, rid, cancel): self.get_rids.append(rid); return True, Existing()
  def modify_object_sync(self, existing, scope, flags, cancel): self.mods.append(scope); return True
class Source:
  def get_display_name(self): return "Calendar"
class Component:
  @staticmethod
  def new_from_icalcomponent(value): return value
class ObjModType:
  THIS = "this"
  ALL = "all"
class OperationFlags:
  DISABLE_ITIP_MESSAGE = 0
class ECal:
  Component = Component
  ObjModType = ObjModType
  OperationFlags = OperationFlags
class Time:
  @staticmethod
  def new_from_string(value): return Stamp()
  @staticmethod
  def new_from_timet_with_zone(value, is_date, zone): return Stamp()
class Timezone:
  @staticmethod
  def get_utc_timezone(): return object()
class ICalGLib:
  Time = Time
  Timezone = Timezone
class Modules:
  ECal = ECal
  ICalGLib = ICalGLib
modules = Modules()
class LocalInstanceStamp:
  def is_date(self): return False
  def is_utc(self): return False
  def get_year(self): return 2026
  def get_month(self): return 8
  def get_day(self): return 1
  def get_hour(self): return 10
  def get_minute(self): return 30
  def get_second(self): return 0
assert mod.ical_time_rid(LocalInstanceStamp()) == "20260801T103000"
assert mod.recurrence_id_time(modules, "20260801T103000", Value()) is not None
clients = []
def client_for(calendar_id):
  client = Client(); clients.append(client); return modules, object(), Source(), client
mod.eds_client_for_calendar = client_for
mod.source_calendar = lambda source, registry, loaded: {"id": "cal", "name": "Calendar", "color": "", "provider": "caldav", "source": "EDS"}
mod.component_event = lambda component, calendar, loaded, client: {"id": "cal:uid", "uid": "uid", "rid": "", "calendarId": "cal"}
merged = []
mod.merge_cache_event = lambda event, series=False: merged.append((dict(event), series))
start = datetime(2026, 8, 1, 10, tzinfo=UTC); end = start + timedelta(hours=1)
mod.eds_update_event("cal", "uid", "20260801T100000Z", "One", start, end, False, "", "", "this", "cal")
assert clients[-1].get_rids == ["20260801T100000Z"] and clients[-1].mods == ["this"]
assert merged[-1][0]["rid"] == "20260801T100000Z" and merged[-1][1] is False
mod.eds_update_event("cal", "uid", "20260801T100000Z", "All", start, end, False, "", "", "all", "cal")
assert clients[-1].get_rids == [None] and clients[-1].mods == ["all"] and merged[-1][1] is True
class MissingInstanceClient(Client):
  def get_object_sync(self, uid, rid, cancel):
    self.get_rids.append(rid)
    if rid: raise RuntimeError("generated instance is not a detached object")
    self.existing = Existing(); return True, self.existing
def fallback_client_for(calendar_id):
  client = MissingInstanceClient(); clients.append(client); return modules, object(), Source(), client
mod.eds_client_for_calendar = fallback_client_for
mod.eds_update_event("cal", "uid", "20260801T100000Z", "One", start, end, False, "", "", "this", "cal")
assert clients[-1].get_rids == ["20260801T100000Z", None] and clients[-1].mods == ["this"]
assert clients[-1].existing.recurrence_id is not None
class Instance:
  def clone(self): return self
class InstanceStamp:
  def __init__(self, value): self.value = value
  def is_date(self): return False
  def is_utc(self): return False
  def get_year(self): return 2026
  def get_month(self): return 8
  def get_day(self): return 2
  def get_hour(self): return 12 if "12:00" in self.value else 13
  def get_minute(self): return 0
  def get_second(self): return 0
class Recurring:
  def has_recurrences(self): return True
  def get_icalcomponent(self): return self
class ExpandClient:
  def generate_instances_for_object_sync(self, ical, first, last, cancel, callback, data):
    callback(Instance(), InstanceStamp("2026-08-02T12:00:00Z"), InstanceStamp("2026-08-02T13:00:00Z"), data)
original_component_event = mod.component_event
original_time_iso = mod.ical_time_iso
mod.component_event = lambda component, calendar, loaded=None, client=None: ({"id": "cal:uid:20260802T100000Z", "uid": "uid", "rid": "20260802T100000Z", "calendarId": "cal", "title": "Exception", "start": "2026-08-02T12:00:00Z", "end": "2026-08-02T13:00:00Z", "allDay": False} if isinstance(component, Instance) else {"id": "cal:uid", "uid": "uid", "rid": "", "calendarId": "cal", "title": "Master", "start": "2026-08-01T10:00:00Z", "end": "2026-08-01T11:00:00Z", "allDay": False})
mod.ical_time_iso = lambda value, loaded=None, client=None: (value.value, False)
expanded = []
assert mod.append_component_events(ExpandClient(), Recurring(), {"id": "cal"}, start, end + timedelta(days=3), expanded, modules)
assert expanded == [{"id": "cal:uid:20260802T100000Z", "uid": "uid", "rid": "20260802T100000Z", "calendarId": "cal", "title": "Exception", "start": "2026-08-02T12:00:00Z", "end": "2026-08-02T13:00:00Z", "allDay": False, "recurring": True}]
assert mod.append_component_events(None, Instance(), {"id": "cal"}, start, end, expanded, modules)
assert len(expanded) == 1
def local_generate(ical, first, last, callback, data, get_timezone, timezone_data, default_timezone, cancel):
  callback(None, InstanceStamp("2026-08-02T12:00:00Z"), InstanceStamp("2026-08-02T13:00:00Z"), data)
  return True
ECal.recur_generate_instances_sync = staticmethod(local_generate)
local_expanded = []
assert mod.append_component_events(None, Recurring(), {"id": "cal"}, start, end + timedelta(days=3), local_expanded, modules)
assert local_expanded[0]["rid"] == "20260802T120000"
mod.read_cache = lambda: {"range": {"start": "2026-08-01T00:00:00Z", "end": "2026-08-05T00:00:00Z"}}
created_expanded = mod.created_event_instances(modules, None, Recurring(), {"id": "cal"}, {"id": "cal:uid", "uid": "uid", "calendarId": "cal"}, start, end, "FREQ=DAILY")
assert len(created_expanded) == 1 and created_expanded[0]["rid"] == "20260802T120000"
del ECal.recur_generate_instances_sync
mod.component_event = original_component_event
mod.ical_time_iso = original_time_iso
print("ok - helper recurrence update scope")' "$ROOT/helper/omarchy-calendar-helper"

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
