#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote


def wrap_ics(uid: str, summary: str, start: str, end: str) -> str:
    return (
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//omarchy-test//caldav//EN\r\n"
        "BEGIN:VTIMEZONE\r\nTZID:UTC\r\nBEGIN:STANDARD\r\n"
        "DTSTART:19700101T000000\r\nTZOFFSETFROM:+0000\r\nTZOFFSETTO:+0000\r\n"
        "END:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\n"
        f"UID:{uid}\r\nSUMMARY:{summary}\r\nDTSTART:{start}\r\nDTEND:{end}\r\n"
        "DTSTAMP:20260824T000000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )


class Store:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.token = 1
        self.stale_404s: list[str] = []
        self.truncate = False
        self.calendars = {
            "work": {"name": "Work", "events": {}},
            "personal": {"name": "Personal", "events": {}},
        }
        self.put_event("work", "file-alpha", "uid-alpha@test", "Seed Alpha", "20260825T180000Z", "20260825T181500Z")
        self.put_event("personal", "file-beta", "uid-beta@test", "Seed Beta", "20260826T180000Z", "20260826T181500Z")

    def bump(self) -> int:
        self.token += 1
        return self.token

    def token_href(self) -> str:
        return f"http://example.test/ns/sync/{self.token}"

    def put_event(self, calendar: str, filename: str, uid: str, summary: str, start: str, end: str) -> None:
        cal = self.calendars[calendar]
        cal["events"][filename] = {
            "uid": uid,
            "summary": summary,
            "ics": wrap_ics(uid, summary, start, end),
            "deleted": False,
            "changed": self.token,
        }
        self.bump()
        cal["events"][filename]["changed"] = self.token

    def delete_event(self, calendar: str, filename: str) -> bool:
        cal = self.calendars.get(calendar) or {}
        event = (cal.get("events") or {}).get(filename)
        if not event or event["deleted"]:
            return False
        event["deleted"] = True
        self.bump()
        event["changed"] = self.token
        return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args) -> None:
        return

    def _store(self) -> Store:
        return self.server.store

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization") or ""
        if not header.startswith("Basic "):
            return False
        try:
            raw = base64.b64decode(header.split(" ", 1)[1]).decode("utf-8")
        except Exception:
            return False
        user, _, password = raw.partition(":")
        return user == self.server.username and password == self.server.password

    def _send(self, status: int, body: bytes, content_type: str = "application/xml; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _need_auth(self) -> bool:
        if self._authorized():
            return False
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="caldav"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return True

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/_control/state":
            with self._store().lock:
                body = json.dumps({"token": self._store().token, "calendars": self._store().calendars}, default=str).encode()
            self._send(200, body, "application/json")
            return
        if self._need_auth():
            return
        match = re.fullmatch(r"/dav/user/([^/]+)/([^/]+)\.ics", parsed.path)
        if not match:
            self._send(404, b"")
            return
        calendar, filename = unquote(match.group(1)), unquote(match.group(2))
        with self._store().lock:
            event = ((self._store().calendars.get(calendar) or {}).get("events") or {}).get(filename)
            if not event or event["deleted"]:
                self._send(404, b"")
                return
            body = event["ics"].encode("utf-8")
        self._send(200, body, "text/calendar; charset=utf-8")

    def do_PUT(self) -> None:
        if self._need_auth():
            return
        match = re.fullmatch(r"/dav/user/([^/]+)/([^/]+)\.ics", urlparse(self.path).path)
        if not match:
            self._send(404, b"")
            return
        calendar, filename = unquote(match.group(1)), unquote(match.group(2))
        raw = self._read_body().decode("utf-8", "replace")
        uid_match = re.search(r"^UID:(.+)$", raw, re.M)
        sum_match = re.search(r"^SUMMARY:(.+)$", raw, re.M)
        start_match = re.search(r"^DTSTART.*:(\d{8}T\d{6}Z)$", raw, re.M)
        end_match = re.search(r"^DTEND.*:(\d{8}T\d{6}Z)$", raw, re.M)
        uid = (uid_match.group(1).strip() if uid_match else f"{filename}@test")
        summary = (sum_match.group(1).strip() if sum_match else filename)
        start = start_match.group(1) if start_match else "20260825T180000Z"
        end = end_match.group(1) if end_match else "20260825T181500Z"
        with self._store().lock:
            if calendar not in self._store().calendars:
                self._send(404, b"")
                return
            self._store().put_event(calendar, filename, uid, summary, start, end)
        self._send(201, b"")

    def do_DELETE(self) -> None:
        if self._need_auth():
            return
        match = re.fullmatch(r"/dav/user/([^/]+)/([^/]+)\.ics", urlparse(self.path).path)
        if not match:
            self._send(404, b"")
            return
        calendar, filename = unquote(match.group(1)), unquote(match.group(2))
        with self._store().lock:
            ok = self._store().delete_event(calendar, filename)
        self._send(204 if ok else 404, b"")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/_control/mutate":
            self._send(404, b"")
            return
        payload = json.loads(self._read_body().decode("utf-8") or "{}")
        op = str(payload.get("op") or "")
        with self._store().lock:
            store = self._store()
            if op == "put":
                store.put_event(
                    str(payload["calendar"]),
                    str(payload["filename"]),
                    str(payload.get("uid") or payload["filename"] + "@test"),
                    str(payload.get("summary") or "Remote"),
                    str(payload.get("start") or "20260827T180000Z"),
                    str(payload.get("end") or "20260827T181500Z"),
                )
            elif op == "delete":
                store.delete_event(str(payload["calendar"]), str(payload["filename"]))
            elif op == "stale-404":
                store.stale_404s.append(str(payload.get("filename") or "gone-old"))
                store.bump()
            elif op == "truncate":
                store.truncate = bool(payload.get("on", True))
            else:
                self._send(400, b"")
                return
        self._send(200, b'{"ok":true}', "application/json")

    def do_PROPFIND(self) -> None:
        if self._need_auth():
            return
        path = urlparse(self.path).path.rstrip("/") or "/"
        store = self._store()
        with store.lock:
            token = store.token_href()
            if path in ("/", "/dav", "/dav/user"):
                if path == "/":
                    body = f"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <c:calendar-home-set><d:href>/dav/user/</d:href></c:calendar-home-set>
        <d:current-user-principal><d:href>/dav/user/</d:href></d:current-user-principal>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>""".encode()
                else:
                    rows = []
                    for slug, calendar in store.calendars.items():
                        rows.append(
                            f"""  <d:response>
    <d:href>/dav/user/{slug}/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>{calendar["name"]}</d:displayname>
        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
        <d:sync-token>{token}</d:sync-token>
        <d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>
        <cs:getctag>{store.token}</cs:getctag>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>"""
                        )
                    body = f"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">
{"".join(rows)}
</d:multistatus>""".encode()
            else:
                match = re.fullmatch(r"/dav/user/([^/]+)", path)
                if not match or match.group(1) not in store.calendars:
                    self._send(404, b"")
                    return
                slug = match.group(1)
                calendar = store.calendars[slug]
                body = f"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">
  <d:response>
    <d:href>/dav/user/{slug}/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>{calendar["name"]}</d:displayname>
        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
        <d:sync-token>{token}</d:sync-token>
        <d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>
        <cs:getctag>{store.token}</cs:getctag>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>""".encode()
        self._send(207, body)

    def do_REPORT(self) -> None:
        if self._need_auth():
            return
        parsed = urlparse(self.path)
        match = re.fullmatch(r"/dav/user/([^/]+)/?", parsed.path)
        if not match:
            self._send(404, b"")
            return
        slug = unquote(match.group(1))
        raw = self._read_body().decode("utf-8", "replace")
        token_match = re.search(r"<d:sync-token>([^<]*)</d:sync-token>", raw)
        client_token = (token_match.group(1) if token_match else "").strip()
        client_n = 0
        if client_token:
            num = re.search(r"/(\d+)$", client_token)
            client_n = int(num.group(1)) if num else 0
        store = self._store()
        with store.lock:
            calendar = store.calendars.get(slug)
            if calendar is None:
                self._send(404, b"")
                return
            if store.truncate:
                body = f"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/user/{slug}/partial.ics</d:href>
    <d:status>HTTP/1.1 507 Insufficient Storage</d:status>
  </d:response>
  <d:sync-token>{store.token_href()}</d:sync-token>
</d:multistatus>""".encode()
                self._send(207, body)
                return
            rows = []
            for filename, event in calendar["events"].items():
                if event["changed"] <= client_n and client_n > 0:
                    continue
                href = f"/dav/user/{slug}/{filename}.ics"
                if event["deleted"]:
                    rows.append(
                        f"  <d:response><d:href>{href}</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
                    )
                    continue
                ics = event["ics"].replace("&", "&amp;").replace("<", "&lt;")
                rows.append(
                    f"""  <d:response>
    <d:href>{href}</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"{event["changed"]}"</d:getetag>
        <c:calendar-data>{ics}</c:calendar-data>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>"""
                )
            for name in store.stale_404s:
                rows.append(
                    f"  <d:response><d:href>/dav/user/{slug}/{name}.ics</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
                )
            body = f"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
{"".join(rows)}
  <d:sync-token>{store.token_href()}</d:sync-token>
</d:multistatus>""".encode()
        self._send(207, body)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--user", default="tester")
    parser.add_argument("--password", default="secret")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.store = Store()
    server.username = args.user
    server.password = args.password
    print(server.server_address[1], flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
