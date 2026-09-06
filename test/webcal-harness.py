#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.machinery import SourceFileLoader
from pathlib import Path
from threading import Thread


ROOT = Path(__file__).resolve().parent.parent
helper = SourceFileLoader("omarchy_calendar_webcal_test", str(ROOT / "helper/omarchy-calendar-helper")).load_module()


class Handler(BaseHTTPRequestHandler):
    requests = 0

    def do_GET(self):
        type(self).requests += 1
        if self.path == "/invalid":
            body = b"not a calendar"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
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
    helper.source_webdav_url = lambda _source, _modules: base + "/calendar.ics"
    helper.events_from_ics = lambda *_args: ([{"uid": "event-1"}], True)
    cache = {"syncState": {}}
    mode, events, uids = helper.webcal_sync_calendar(None, None, {"id": "webcal-1"}, None, cache, None, None)
    assert mode == "updated" and len(events) == 1 and uids == ["event-1"]
    assert cache["syncState"]["webcal-1"]["etag"] == '"v1"'

    mode, events, uids = helper.webcal_sync_calendar(None, None, {"id": "webcal-1"}, None, cache, None, None, True)
    assert mode == "unchanged" and events == [] and uids == []
    assert Handler.requests == 2

    helper.source_webdav_url = lambda _source, _modules: base + "/invalid"
    try:
        helper.webcal_sync_calendar(None, None, {"id": "webcal-2"}, None, {}, None, None)
    except ValueError as error:
        assert "did not return an iCalendar feed" in str(error)
    else:
        raise AssertionError("invalid feed should fail")
finally:
    server.shutdown()
    server.server_close()

print("ok - webcal refresh and conditional request")
