#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import UTC, datetime
from importlib.machinery import SourceFileLoader
from pathlib import Path
from threading import Thread
from types import SimpleNamespace
import time


ROOT = Path(__file__).resolve().parent.parent
helper = SourceFileLoader("omarchy_calendar_webcal_test", str(ROOT / "helper/omarchy-calendar-helper")).load_module()
source_webdav_url = helper.source_webdav_url
events_from_ics = helper.events_from_ics


class Handler(BaseHTTPRequestHandler):
    requests = []

    def do_GET(self):
        type(self).requests.append({"path": self.path, "etag": self.headers.get("If-None-Match")})
        if self.path == "/invalid":
            body = b"not a calendar"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/large":
            body = b"x" * 256
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/empty":
            body = b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Omarchy Test//EN\r\nEND:VCALENDAR\r\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/calendar")
            self.send_header("ETag", '"empty"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.headers.get("If-None-Match") == '"v1"':
            self.send_response(304)
            self.end_headers()
            return
        body = b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:event-1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/calendar")
        self.send_header("ETag", '"v1"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()

try:
    base = f"http://127.0.0.1:{server.server_port}"
    modules = SimpleNamespace(ICalGLib=SimpleNamespace(Component=SimpleNamespace(new_from_string=lambda _text: object())))
    helper.source_webdav_url = lambda _source, _modules: base + "/calendar.ics"
    helper.events_from_ics = lambda *_args: ([{"uid": "event-1"}], True)
    cache = {"syncState": {}}
    mode, events, uids = helper.webcal_sync_calendar(None, modules, {"id": "webcal-1"}, None, cache, None, None)
    assert mode == "updated" and len(events) == 1 and uids == ["event-1"]
    assert cache["syncState"]["webcal-1"]["etag"] == '"v1"'
    assert cache["syncState"]["webcal-1"]["filled"] is True

    mode, events, uids = helper.webcal_sync_calendar(None, modules, {"id": "webcal-1"}, None, cache, None, None, True)
    assert mode == "unchanged" and events == [] and uids == []
    assert len(Handler.requests) == 2

    cache["syncState"]["webcal-1"]["filled"] = False
    mode, events, uids = helper.webcal_sync_calendar(None, modules, {"id": "webcal-1"}, None, cache, None, None, True)
    assert mode == "updated" and len(events) == 1 and Handler.requests[-1]["etag"] is None

    helper.source_webdav_url = lambda _source, _modules: base + "/empty"
    mode, events, uids = helper.webcal_sync_calendar(None, modules, {"id": "webcal-empty"}, None, {"syncState": {}}, None, None)
    assert mode == "updated" and events == [] and uids == []

    helper.source_webdav_url = lambda _source, _modules: base + "/invalid"
    try:
        helper.webcal_sync_calendar(None, modules, {"id": "webcal-2"}, None, {}, None, None)
    except ValueError as error:
        assert "did not return an iCalendar feed" in str(error)
    else:
        raise AssertionError("invalid feed should fail")

    helper.source_webdav_url = lambda _source, _modules: base + "/large"
    original_limit = helper.MAX_CALDAV_RESPONSE_BYTES
    helper.MAX_CALDAV_RESPONSE_BYTES = 64
    try:
        try:
            helper.webcal_sync_calendar(None, modules, {"id": "webcal-large"}, None, {}, None, None)
        except helper.CaldavResponseTooLarge:
            pass
        else:
            raise AssertionError("oversized feed should fail")
    finally:
        helper.MAX_CALDAV_RESPONSE_BYTES = original_limit

    before = len(Handler.requests)
    try:
        helper.webcal_sync_calendar(None, modules, {"id": "webcal-expired"}, None, {}, None, None, deadline=time.monotonic() - 1)
    except ValueError:
        pass
    else:
        raise AssertionError("expired feed request should fail")
    assert len(Handler.requests) == before

    assert helper.normalize_webcal_url("EXAMPLE.com/feed.ics?token=a") == "https://EXAMPLE.com/feed.ics?token=a"
    assert helper.normalize_webcal_url("HTTPS://example.com/feed.ics?token=a") == "HTTPS://example.com/feed.ics?token=a"
    assert helper.normalize_webcal_url("webcal://example.com/feed.ics?token=a") == "https://example.com/feed.ics?token=a"
    for invalid in ("https://user:secret@example.com/feed.ics", "https://example.com/feed.ics#fragment", "https://example.com:bad/feed.ics"):
        try:
            helper.normalize_webcal_url(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"unsafe URL should fail: {invalid}")

    class Uri:
        def __init__(self, host, query, port=-1):
            self.host = host
            self.query = query
            self.port = port

        def get_scheme(self): return "https"
        def get_host(self): return self.host
        def get_path(self): return "/feed.ics"
        def get_query(self): return self.query
        def get_port(self): return self.port

    class Source:
        def __init__(self, uri): self.uri = uri
        def has_extension(self, _name): return True
        def get_extension(self, _name): return SimpleNamespace(dup_uri=lambda: self.uri)

    source_modules = SimpleNamespace(EDataServer=SimpleNamespace(SOURCE_EXTENSION_WEBDAV_BACKEND="webdav"))
    first = source_webdav_url(Source(Uri("example.com", "token=a")), source_modules)
    second = source_webdav_url(Source(Uri("example.com", "token=b")), source_modules)
    ipv6 = source_webdav_url(Source(Uri("::1", "token=a", 8443)), source_modules)
    assert first == "https://example.com/feed.ics?token=a" and second != first, (first, second)
    assert ipv6 == "https://[::1]:8443/feed.ics?token=a", ipv6

    try:
        real_modules = helper.load_eds_modules()
    except Exception:
        real_modules = None
    if real_modules is not None:
        escaped_url = "https://example.com/cal%2Ffeed.ics?token=a%26b&sig=x%2By%3D"
        escaped_uri = helper.glib_parse_uri(real_modules, escaped_url)
        escaped = source_webdav_url(Source(escaped_uri), source_modules)
        assert escaped == escaped_url, escaped

        feed = """BEGIN:VCALENDAR\r
VERSION:2.0\r
PRODID:-//Omarchy Test//EN\r
BEGIN:VEVENT\r
UID:series\r
RECURRENCE-ID:20260920T140000Z\r
DTSTART:20260920T160000Z\r
DTEND:20260920T170000Z\r
SUMMARY:Changed\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:series\r
DTSTART:20260919T140000Z\r
DTEND:20260919T150000Z\r
RRULE:FREQ=DAILY;COUNT=2\r
SUMMARY:Original\r
END:VEVENT\r
END:VCALENDAR\r
"""
        calendar = {"id": "webcal-real", "name": "Feed", "color": "#fff", "provider": "webcal", "host": "example.com", "source": "test"}
        start = datetime(2026, 9, 1, tzinfo=UTC)
        end = datetime(2026, 10, 1, tzinfo=UTC)
        parsed, complete = events_from_ics(feed, calendar, None, real_modules, start, end)
        assert complete and len(parsed) == 2
        assert sorted((event["title"], event["start"]) for event in parsed) == [("Changed", "2026-09-20T16:00:00Z"), ("Original", "2026-09-19T14:00:00Z")]
        limited, complete = events_from_ics(feed, calendar, None, real_modules, start, end, 1)
        assert limited == [] and complete is False

        ranged_feed = feed.replace("RECURRENCE-ID:20260920T140000Z", "RECURRENCE-ID;RANGE=THISANDFUTURE:20260920T140000Z").replace("COUNT=2", "COUNT=4")
        parsed, complete = events_from_ics(ranged_feed, calendar, None, real_modules, start, end)
        assert complete and [(event["title"], event["start"]) for event in parsed] == [
            ("Original", "2026-09-19T14:00:00Z"),
            ("Changed", "2026-09-20T16:00:00Z"),
            ("Changed", "2026-09-21T16:00:00Z"),
            ("Changed", "2026-09-22T16:00:00Z"),
        ]

        later_range = """BEGIN:VEVENT\r
UID:series\r
RECURRENCE-ID;RANGE=THISANDFUTURE:20260922T140000Z\r
DTSTART:20260922T180000Z\r
DTEND:20260922T190000Z\r
SUMMARY:Later\r
END:VEVENT\r
"""
        multi_range_feed = ranged_feed.replace("PRODID:-//Omarchy Test//EN\r\n", "PRODID:-//Omarchy Test//EN\r\n" + later_range)
        parsed, complete = events_from_ics(multi_range_feed, calendar, None, real_modules, start, end)
        assert complete and [(event["title"], event["start"]) for event in parsed] == [
            ("Original", "2026-09-19T14:00:00Z"),
            ("Changed", "2026-09-20T16:00:00Z"),
            ("Changed", "2026-09-21T16:00:00Z"),
            ("Later", "2026-09-22T18:00:00Z"),
        ]
finally:
    server.shutdown()
    server.server_close()

print("ok - bounded webcal refresh, baselines, empty feeds, and URL validation")
