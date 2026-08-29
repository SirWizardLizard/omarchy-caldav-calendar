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
        disk = {
            "events": [event for event in work_events if event["uid"] != "uid-delta@test"],
            "localTouches": {"work": {"uid-delta@test": "delete", "file-delta": "delete"}},
        }
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
        check("delete-touch survives until 404", pruned.get("work", {}).get("uid-delta@test") == "delete")
        pruned = mod.prune_local_touches(disk["localTouches"], {"work": ["file-delta"]}, None)
        check("404 clears the matching delete-touch", "file-delta" not in pruned.get("work", {}) and pruned.get("work", {}).get("uid-delta@test") == "delete")

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

        source_webdav_url = mod.source_webdav_url
        lookup_source_credentials = mod.lookup_source_credentials
        try:
            mod.source_webdav_url = lambda _source, _modules: work["href"]
            mod.lookup_source_credentials = lambda _source, _registry, _modules: (USER, PASSWORD)
            cache = {"events": [], "syncState": {}}
            mode, synced, removed = mod.caldav_sync_calendar(object(), object(), object(), {"id": "work", "host": "caldav.fastmail.com"}, None, cache, datetime.now(UTC), datetime.now(UTC) + timedelta(days=30), True)
            check("initial background poll requests a full EDS fill", mode == "eds" and synced == [] and removed == [] and bool(cache["syncState"]["work"].get("token")), str((mode, cache)))
        finally:
            mod.source_webdav_url = source_webdav_url
            mod.lookup_source_credentials = lookup_source_credentials
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
