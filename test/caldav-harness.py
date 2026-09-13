#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta
from importlib.machinery import SourceFileLoader
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "helper" / "omarchy-calendar-helper"
USER = "tester"
PASSWORD = "secret"


def load_helper():
    return SourceFileLoader("omarchy_calendar_helper", str(HELPER)).load_module()


def control(base: str, payload: dict) -> None:
    request = urllib.request.Request(
        base + "/_control/mutate",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        response.read()


def server_state(base: str) -> dict:
    with urllib.request.urlopen(base + "/_control/state", timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))


def start_server() -> tuple[subprocess.Popen, str]:
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "test" / "fake-caldav.py"), "--user", USER, "--password", PASSWORD],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert proc.stdout is not None
    line = proc.stdout.readline().strip()
    if not line:
        err = proc.stderr.read() if proc.stderr else ""
        raise SystemExit(f"not ok - fake caldav failed to start: {err}")
    return proc, f"http://127.0.0.1:{line}"


def report(mod, href: str, token: str = "") -> tuple[str, list, list, bool]:
    body = mod.SYNC_REPORT_BODY.format(token=token.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")).encode()
    status, payload, _headers = mod.caldav_http("REPORT", href, USER, PASSWORD, body, {"Depth": "0", "Content-Type": "application/xml; charset=utf-8"})
    if status not in (200, 207):
        raise SystemExit(f"not ok - REPORT {status} for {href}")
    return mod.parse_sync_collection(payload, href)


def synthetic_events(calendar_id: str, changed: list) -> list:
    events = []
    for item in changed:
        events.append({
            "id": f"{calendar_id}:{item['uid']}",
            "uid": "",
            "hrefUid": item["uid"],
            "calendarId": calendar_id,
            "title": "ics" if "BEGIN:VEVENT" in (item.get("ics") or "") else "missing",
        })
        uid_line = ""
        for line in (item.get("ics") or "").splitlines():
            if line.startswith("UID:"):
                uid_line = line.split(":", 1)[1].strip()
        events[-1]["uid"] = uid_line or item["uid"]
        events[-1]["id"] = f"{calendar_id}:{events[-1]['uid']}"
    return events


def run() -> int:
    failed = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failed
        if ok:
            print(f"ok - {name}")
        else:
            failed += 1
            extra = f": {detail}" if detail else ""
            print(f"not ok - {name}{extra}")

    cache_dir = tempfile.mkdtemp(prefix="omarchy-caldav-harness-")
    os.environ["OMARCHY_CALENDAR_CACHE"] = cache_dir
    mod = load_helper()
    proc, base = start_server()
    try:
        time.sleep(0.05)
        found = mod.discover_caldav_calendars(base + "/", USER, PASSWORD)
        names = sorted(item["name"] for item in found)
        check("discover finds both calendars", names == ["Personal", "Work"], str(names))
        work = next(item for item in found if item["name"] == "Work")
        personal = next(item for item in found if item["name"] == "Personal")

        token, changed, removed, truncated = report(mod, work["href"])
        check("first fill is not truncated", truncated is False)
        check("first fill lists the seed event", len(changed) == 1 and removed == [], str((changed, removed)))
        check("first fill includes wrapped VEVENT", "BEGIN:VEVENT" in (changed[0].get("ics") or "") and "Seed Alpha" in (changed[0].get("ics") or ""))
        check("href filename is not the iCalendar UID", changed[0]["uid"] == "file-alpha")

        work_events = synthetic_events("work", changed)
        check("seed uid comes from ICS", work_events[0]["uid"] == "uid-alpha@test")

        token2, changed2, removed2, _trunc = report(mod, work["href"], token)
        check("cheap poll is unchanged", changed2 == [] and removed2 == [] and token2 == token)

        control(base, {"op": "put", "calendar": "work", "filename": "file-gamma", "uid": "uid-gamma@test", "summary": "Remote Gamma"})
        token3, changed3, removed3, _trunc = report(mod, work["href"], token)
        check("remote create appears in REPORT", any(item["uid"] == "file-gamma" for item in changed3) and removed3 == [], str(changed3))
        work_events = mod.apply_sync_delta(work_events, removed3, synthetic_events("work", changed3))
        check("remote create merges into cache", any(event["uid"] == "uid-gamma@test" for event in work_events), str(work_events))

        control(base, {"op": "delete", "calendar": "work", "filename": "file-gamma"})
        token4, changed4, removed4, _trunc = report(mod, work["href"], token3)
        check("remote delete is a 404", "file-gamma" in removed4, str(removed4))
        work_events = mod.apply_sync_delta(work_events, removed4, synthetic_events("work", changed4))
        check("remote delete removes by hrefUid", not any(event["uid"] == "uid-gamma@test" for event in work_events), str(work_events))

        pers_token, pers_changed, _rm, _tr = report(mod, personal["href"])
        pers_events = synthetic_events("personal", pers_changed)
        check("personal first fill is isolated", [event["uid"] for event in pers_events] == ["uid-beta@test"])

        control(base, {"op": "put", "calendar": "work", "filename": "file-delta", "uid": "uid-delta@test", "summary": "Keep Me"})
        _tok, delta_changed, _rm, _tr = report(mod, work["href"], token4)
        work_events = mod.apply_sync_delta(work_events, [], synthetic_events("work", delta_changed))
        delta_event = next(event for event in work_events if event["uid"] == "uid-delta@test")
        disk = {
            "events": [event for event in work_events if event["uid"] != "uid-delta@test"],
        }
        mod.note_event_touch(disk, delta_event, "delete", "series")
        held = {"work": {"token": "new"}}
        start = {"work": {"token": "old"}}
        merged = mod.merge_snapshot_with_local(
            work_events,
            disk,
            {"work": "updated"},
            {"work": ["file-delta", "uid-delta@test"]},
            held,
            start,
        )
        check("local delete is not restored by a stale REPORT", not any(event["uid"] == "uid-delta@test" for event in merged), str(merged))
        check("stale REPORT holds the token", held["work"]["token"] == "old")
        pruned = mod.prune_local_touches(disk["localTouches"], {}, None)
        check("delete-touch survives until 404", len(pruned.get("work", {})) == 1)
        pruned = mod.prune_local_touches(disk["localTouches"], {"work": ["file-delta"]}, None)
        check("404 clears all aliases in the delete-touch", not pruned.get("work"))

        control(base, {"op": "truncate", "on": True})
        _tok, _ch, _rm, truncated = report(mod, work["href"], pers_token)
        check("507 is flagged truncated", truncated is True)
        control(base, {"op": "truncate", "on": False})

        control(base, {"op": "stale-404", "filename": "gone-old"})
        _tok, _ch, stale_removed, _tr = report(mod, work["href"], token4)
        check("replayed 404s are parsed", "gone-old" in stale_removed, str(stale_removed))
        leftover = mod.apply_sync_delta(pers_events, stale_removed, [])
        check("unknown 404s do not wipe the other calendar", leftover == pers_events)

        try:
            modules = mod.load_eds_modules()
        except Exception:
            modules = None
        if modules is None:
            print("ok - ics ingest skipped (no GI bindings)")
        else:
            calendar = {"id": "work", "name": "Work", "color": "#000", "provider": "caldav", "host": "127.0.0.1", "source": "test"}
            window_start = datetime.now(UTC) - timedelta(days=400)
            window_end = datetime.now(UTC) + timedelta(days=400)
            parsed, complete = mod.events_from_ics(work_events[0].get("title") and changed[0]["ics"], calendar, None, modules, window_start, window_end)
            check("GI parse of wrapped VEVENT", complete and parsed and parsed[0]["title"] == "Seed Alpha" and parsed[0]["uid"] == "uid-alpha@test", str(parsed[:1]))

        probe_status, probe_body = mod.caldav_propfind(work["href"], USER, PASSWORD)
        supported, probed_token, ctag = mod.parse_sync_probe(probe_body) if probe_status in (200, 207) else (False, "", "")
        check("calendar advertises sync-collection", supported is True and probed_token.startswith("http://example.test/ns/sync/"), str((supported, probed_token, ctag)))

        adaptive_proc, adaptive_base = start_server()
        original_events_from_ics = mod.events_from_ics
        try:
            time.sleep(0.05)
            adaptive_work = next(item for item in mod.discover_caldav_calendars(adaptive_base + "/", USER, PASSWORD) if item["name"] == "Work")
            href = adaptive_work["href"]
            calendar = {"id": "work", "name": "Work", "color": "#000", "provider": "caldav", "host": "127.0.0.1", "source": "test"}
            window_start = datetime.now(UTC) - timedelta(days=400)
            window_end = datetime.now(UTC) + timedelta(days=400)

            def fake_events_from_ics(ics, cal, _client, _modules, _start, _end, event_limit=mod.MAX_EVENTS, deadline=None):
                values = {}
                if deadline is not None and time.monotonic() >= deadline:
                    return [], False
                if "BEGIN:VEVENT" not in str(ics):
                    return [], False
                for line in str(ics).splitlines():
                    key, separator, value = line.partition(":")
                    if separator and key in ("UID", "SUMMARY"):
                        values[key] = value.strip()
                if not values.get("UID"):
                    return [], False
                if values.get("SUMMARY") == "Expand":
                    expanded = [{"id": f"{cal['id']}:{values['UID']}:{index}", "uid": f"{values['UID']}:{index}", "calendarId": cal["id"], "title": "Expand"} for index in range(3)]
                    return (expanded, True) if len(expanded) <= event_limit else ([], False)
                parsed = [{"id": f"{cal['id']}:{values['UID']}", "uid": values["UID"], "calendarId": cal["id"], "title": values.get("SUMMARY", "")}]
                return (parsed, True) if len(parsed) <= event_limit else ([], False)

            mod.events_from_ics = fake_events_from_ics
            cache = {"events": [], "syncState": {}, "_removed": {}}
            state = cache["syncState"]
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "page-a", "uid": "page-a@test"})
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "page-b", "uid": "page-b@test"})
            control(adaptive_base, {"op": "config", "page_size": 1})
            control(adaptive_base, {"op": "reset-stats"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, "", calendar, None, None, object(), window_start, window_end, cache, state, "work", "", [], False, replace=True)
            cache["events"] = synced
            stats = server_state(adaptive_base)["stats"]
            check("paged initial sync commits all pages", mode == "updated" and {event["uid"] for event in synced} == {"uid-alpha@test", "page-a@test", "page-b@test"} and stats["sync"] == 3, str((mode, synced, stats)))
            check("paged initial sync commits terminal token", state["work"]["token"].endswith("/5"), str(state))

            legacy_cache = {
                "events": list(synced),
                "syncState": {"work": dict(state["work"])},
                "localTouches": {"work": {"uid-alpha@test": "delete"}},
            }
            legacy_state = legacy_cache["syncState"]
            mode, migrated, _remote = mod.apply_collection_report(href, USER, PASSWORD, "", calendar, None, None, object(), window_start, window_end, legacy_cache, legacy_state, "work", "", legacy_cache["events"], True, replace=True)
            check("authoritative baseline restores events hidden by legacy touches", mode == "updated" and any(event["uid"] == "uid-alpha@test" for event in migrated), str((mode, migrated)))

            old_token = state["work"]["token"]
            old_events = list(cache["events"])
            expired_state = {"work": dict(state["work"])}
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, old_token, calendar, None, None, object(), window_start, window_end, cache, expired_state, "work", "", old_events, True, budget=[0], deadline=time.monotonic() - 1)
            check("expired transaction preserves cache and token", mode == "unchanged" and synced == [] and expired_state["work"]["token"] == old_token, str((mode, expired_state)))
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "fail-a", "uid": "fail-a@test"})
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "fail-b", "uid": "fail-b@test"})
            control(adaptive_base, {"op": "config", "report_fail_after": 1})
            control(adaptive_base, {"op": "reset-stats"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, old_token, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", old_events, True)
            check("interrupted page sequence preserves cache", mode == "unchanged" and synced == [] and cache["events"] == old_events)
            check("interrupted page sequence preserves token", state["work"]["token"] == old_token, str(state))

            control(adaptive_base, {"op": "config", "report_fail_after": 0})
            control(adaptive_base, {"op": "reset-stats"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, old_token, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", old_events, True)
            cache["events"] = synced
            check("paged retry applies complete transaction", mode == "updated" and {"fail-a@test", "fail-b@test"}.issubset({event["uid"] for event in synced}), str((mode, synced)))

            token_before = state["work"]["token"]
            events_before = list(cache["events"])
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "expand", "uid": "expand@test", "summary": "Expand"})
            old_max_events = mod.MAX_EVENTS
            mod.MAX_EVENTS = len(events_before) + 1
            try:
                mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", events_before, True)
            finally:
                mod.MAX_EVENTS = old_max_events
            check("expanded event limit preserves cache and token", mode == "unchanged" and synced == [] and cache["events"] == events_before and state["work"]["token"] == token_before, str((mode, state)))
            control(adaptive_base, {"op": "delete", "calendar": "work", "filename": "expand"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", events_before, True)
            cache["events"] = synced
            check("sync recovers after expanded event rejection", mode == "updated" and state["work"]["token"] != token_before, str((mode, state)))

            token_before = state["work"]["token"]
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "metadata", "uid": "metadata@test"})
            control(adaptive_base, {"op": "config", "page_size": 0, "omit_inline": True, "multiget_supported": True})
            control(adaptive_base, {"op": "reset-stats"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", cache["events"], True)
            cache["events"] = synced
            stats = server_state(adaptive_base)["stats"]
            check("missing inline data uses multiget", mode == "updated" and any(event["uid"] == "metadata@test" for event in synced) and stats["multiget"] == 1 and stats["get"] == 0, str(stats))

            token_before = state["work"]["token"]
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "get-fallback", "uid": "get-fallback@test"})
            control(adaptive_base, {"op": "config", "multiget_supported": False})
            control(adaptive_base, {"op": "reset-stats"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", cache["events"], True)
            cache["events"] = synced
            stats = server_state(adaptive_base)["stats"]
            check("unsupported multiget falls back to GET", mode == "updated" and any(event["uid"] == "get-fallback@test" for event in synced) and stats["multiget"] == 1 and stats["get"] == 1, str(stats))

            token_before = state["work"]["token"]
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "no-limit", "uid": "no-limit@test"})
            control(adaptive_base, {"op": "config", "omit_inline": False, "multiget_supported": True, "limit_mode": "reject"})
            control(adaptive_base, {"op": "reset-stats"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", cache["events"], True)
            cache["events"] = synced
            stats = server_state(adaptive_base)["stats"]
            check("rejected DAV limit retries without limit", mode == "updated" and any(event["uid"] == "no-limit@test" for event in synced) and stats["sync"] == 2, str(stats))

            token_before = state["work"]["token"]
            for index in range(4):
                control(adaptive_base, {"op": "put", "calendar": "work", "filename": f"large-{index}", "uid": f"large-{index}@test", "summary": "X" * 500})
            control(adaptive_base, {"op": "config", "limit_mode": "honor"})
            control(adaptive_base, {"op": "reset-stats"})
            old_limit = mod.MAX_CALDAV_RESPONSE_BYTES
            mod.MAX_CALDAV_RESPONSE_BYTES = 2600
            try:
                mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", cache["events"], True)
            finally:
                mod.MAX_CALDAV_RESPONSE_BYTES = old_limit
            cache["events"] = synced
            stats = server_state(adaptive_base)["stats"]
            check("oversized inline page uses split multiget", mode == "updated" and all(any(event["uid"] == f"large-{index}@test" for event in synced) for index in range(4)) and stats["sync"] == 2 and stats["multiget"] >= 3, str((mode, stats)))

            token_before = state["work"]["token"]
            events_before = list(cache["events"])
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "too-large", "uid": "too-large@test", "summary": "Y" * 5000})
            control(adaptive_base, {"op": "reset-stats"})
            mod.MAX_CALDAV_RESPONSE_BYTES = 2000
            try:
                mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", events_before, True)
            finally:
                mod.MAX_CALDAV_RESPONSE_BYTES = old_limit
            check("oversized singleton preserves cache and token", mode == "unchanged" and synced == [] and cache["events"] == events_before and state["work"]["token"] == token_before, str((mode, state)))

            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "repeat-a", "uid": "repeat-a@test"})
            control(adaptive_base, {"op": "put", "calendar": "work", "filename": "repeat-b", "uid": "repeat-b@test"})
            control(adaptive_base, {"op": "config", "page_size": 1, "repeat_token": True})
            control(adaptive_base, {"op": "reset-stats"})
            mode, synced, _remote = mod.apply_collection_report(href, USER, PASSWORD, token_before, calendar, None, None, object(), window_start, window_end, cache, state, "work", "", events_before, True)
            check("repeated partial token aborts transaction", mode == "unchanged" and synced == [] and state["work"]["token"] == token_before)
            check("cross-origin event href is rejected", not mod.safe_event_href(href, "https://attacker.invalid/event.ics"))
            check("encoded traversal event hrefs are rejected", all(not mod.safe_event_href(href, value) for value in (href + "%2e%2e/private.ics", href + "%252e%252e/private.ics", href + "safe%2f..%2fprivate.ics", href + "..\\private.ics")))
            check("encoded iCloud ReminderKit href is accepted", mod.safe_event_href(href, href + "x-apple-reminderkit%3A%252FREMCDReminder%252F48EA0210.ics"))
            vtodo = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\nBEGIN:VTODO\r\nUID:task@test\r\nSUMMARY:Literal BEGIN:VEVENT text\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
            ignored, failures = mod.ingest_changed_items([{"uid": "task", "href": href + "task.ics", "ics": vtodo}], calendar, None, object(), window_start, window_end, USER, PASSWORD)
            check("valid non-event calendar data advances sync", ignored == [] and failures == [], str((ignored, failures)))
            malformed_non_events = (
                "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\nEND:VCALENDAR\r\n",
                "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\nBEGIN:VTODO\r\nSUMMARY:Broken\r\nEND:VCALENDAR\r\n",
                "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\nBEGIN:VTODO\r\nSUMMARY:No UID\r\nEND:VTODO\r\nEND:VCALENDAR\r\n",
                "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:task@test\r\nEND:VTODO\r\nEND:VCALENDAR\r\n",
            )
            malformed_failures = []
            for index, malformed in enumerate(malformed_non_events):
                _ignored, item_failures = mod.ingest_changed_items([{"uid": f"bad-{index}", "href": href + f"bad-{index}.ics", "ics": malformed}], calendar, None, object(), window_start, window_end, USER, PASSWORD)
                malformed_failures.extend(item_failures)
            check("malformed non-event calendar data holds token", malformed_failures == ["bad-0", "bad-1", "bad-2", "bad-3"], str(malformed_failures))

            attacker_proc, attacker_base = start_server()
            try:
                time.sleep(0.05)
                control(attacker_base, {"op": "reset-stats"})
                control(adaptive_base, {"op": "config", "discovery_home": attacker_base + "/dav/user/"})
                discovered = mod.discover_caldav_calendars(adaptive_base + "/", USER, PASSWORD)
                attacker_stats = server_state(attacker_base)["stats"]
                check("cross-origin discovery target receives no credentials", bool(discovered) and attacker_stats["propfind"] == 0 and attacker_stats["authorized"] == 0, str(attacker_stats))
            finally:
                attacker_proc.terminate()
                try:
                    attacker_proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    attacker_proc.kill()
        finally:
            mod.events_from_ics = original_events_from_ics
            adaptive_proc.terminate()
            try:
                adaptive_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                adaptive_proc.kill()

        source_webdav_url = mod.source_webdav_url
        lookup_source_credentials = mod.lookup_source_credentials
        caldav_http = mod.caldav_http
        try:
            mod.source_webdav_url = lambda _source, _modules: work["href"]
            mod.lookup_source_credentials = lambda _source, _registry, _modules: (USER, PASSWORD)
            cache = {"events": [], "syncState": {}}
            mode, synced, removed = mod.caldav_sync_calendar(object(), object(), object(), {"id": "work", "host": "caldav.fastmail.com"}, None, cache, datetime.now(UTC), datetime.now(UTC) + timedelta(days=30), True)
            check("failed initial baseline requests EDS without committing a token", mode == "eds" and synced == [] and removed == [] and not cache["syncState"], str((mode, cache)))
            mod.lookup_source_credentials = lambda _source, _registry, _modules: ("", "")
            cache = {"events": [{"uid": "cached", "calendarId": "work"}], "syncState": {"work": {"supported": True, "token": "old", "filled": True}}}
            mode, synced, removed = mod.caldav_sync_calendar(object(), object(), object(), {"id": "work", "host": "caldav.fastmail.com"}, None, cache, datetime.now(UTC), datetime.now(UTC) + timedelta(days=30), True)
            check("missing direct credentials falls back to EDS", mode == "eds" and synced == [] and removed == [], str((mode, cache)))
            mod.lookup_source_credentials = lambda _source, _registry, _modules: (USER, PASSWORD)
            unsupported_probe = b"""<d:multistatus xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:response><d:propstat><d:prop><cs:getctag>same</cs:getctag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"""
            mod.caldav_http = lambda *_args, **_kwargs: (207, unsupported_probe, {})
            cache = {"events": [{"uid": "legacy", "calendarId": "work"}], "syncState": {"work": {"supported": False, "token": "", "ctag": "same", "filled": True}}, "localTouches": {"work": {"legacy": "delete"}}}
            mode, synced, removed = mod.caldav_sync_calendar(object(), object(), object(), {"id": "work", "host": "caldav.fastmail.com"}, None, cache, datetime.now(UTC), datetime.now(UTC) + timedelta(days=30), True)
            check("unsupported legacy touch forces authoritative EDS pull", mode == "eds" and synced == [] and removed == [] and cache.get("_pendingSyncState", {}).get("work", {}).get("ctag") == "same", str((mode, cache)))
        finally:
            mod.source_webdav_url = source_webdav_url
            mod.lookup_source_credentials = lookup_source_credentials
            mod.caldav_http = caldav_http
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
    if failed:
        print(f"not ok - caldav harness ({failed} failed)")
        return 1
    print("ok - caldav harness")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
