#!/usr/bin/env python3

from __future__ import annotations

import email.message
import signal
import sys
import time
import urllib.error
import urllib.request
from importlib.machinery import SourceFileLoader
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "helper" / "omarchy-calendar-helper"
LIMIT = 32


class Headers(email.message.Message):
    def __init__(self, values: dict[str, str] | None = None):
        super().__init__()
        for key, value in (values or {}).items():
            self[key] = value


class FakeBody:
    def __init__(self, data: bytes, chunk_size: int | None = None):
        self.data = data
        self.pos = 0
        self.chunk_size = chunk_size
        self.read_calls = 0
        self.closed = False

    def read(self, size: int = -1) -> bytes:
        self.read_calls += 1
        remaining = self.data[self.pos :]
        if size is None or size < 0:
            chunk = remaining
        else:
            take = size
            if self.chunk_size is not None:
                take = min(take, self.chunk_size)
            chunk = remaining[:take]
        self.pos += len(chunk)
        return chunk

    def close(self) -> None:
        self.closed = True


class FakeResponse:
    def __init__(self, data: bytes, headers: dict[str, str] | None = None, status: int = 207, chunk_size: int | None = None):
        self.body = FakeBody(data, chunk_size)
        self.headers = Headers(headers)
        self.status = status

    def read(self, size: int = -1) -> bytes:
        return self.body.read(size)

    def close(self) -> None:
        self.body.close()

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()
        return False


def load_helper():
    return SourceFileLoader("omarchy_calendar_limit", str(HELPER)).load_module()


def patch_opener(mod, result):
    original = urllib.request.build_opener

    class Opener:
        def open(self, request, timeout=None):
            if isinstance(result, BaseException):
                raise result
            return result

    urllib.request.build_opener = lambda *args, **kwargs: Opener()
    return original


def restore_opener(original) -> None:
    urllib.request.build_opener = original


def expect_too_large(fn) -> None:
    try:
        fn()
    except Exception as error:
        if type(error).__name__ != "CaldavResponseTooLarge":
            raise SystemExit(f"not ok - expected CaldavResponseTooLarge, got {type(error).__name__}: {error}") from error
        if str(error) != "Calendar server response was too large.":
            raise SystemExit(f"not ok - wrong oversized message: {error}")
        return
    raise SystemExit("not ok - expected oversized CalDAV response to fail")


def http_error(body: bytes, code: int = 401) -> urllib.error.HTTPError:
    fp = FakeBody(body)
    return urllib.error.HTTPError("https://caldav.example.com/dav/", code, "Unauthorized", Headers({"Content-Length": str(len(body))}), fp)


def main() -> None:
    mod = load_helper()
    if mod.MAX_CALDAV_RESPONSE_BYTES != 32 * 1024 * 1024:
        raise SystemExit("not ok - CalDAV response ceiling should be 32 MiB")
    print("ok - helper caldav 32 MiB ceiling")
    if mod.MAX_CALDAV_TRANSACTION_BYTES != 64 * 1024 * 1024:
        raise SystemExit("not ok - CalDAV transaction ceiling should be 64 MiB")
    print("ok - helper caldav 64 MiB transaction ceiling")
    if mod.CALDAV_SYNC_PAGE_SIZE * mod.MAX_CALDAV_SYNC_PAGES < mod.MAX_EVENTS:
        raise SystemExit("not ok - paging ceiling should cover the event resource ceiling")
    print("ok - helper caldav paging ceiling")
    pages = (mod.MAX_EVENTS + mod.CALDAV_SYNC_PAGE_SIZE - 1) // mod.CALDAV_SYNC_PAGE_SIZE
    if mod.MAX_CALDAV_REQUESTS < mod.MAX_EVENTS + 2 * pages:
        raise SystemExit("not ok - request budget should cover REPORT, multiget, and GET fallback")
    print("ok - helper caldav request ceiling")

    original_http = mod.caldav_http
    original_transaction_limit = mod.MAX_CALDAV_TRANSACTION_BYTES
    mod.MAX_CALDAV_TRANSACTION_BYTES = LIMIT
    responses = [b"a" * LIMIT, b"b"]
    mod.caldav_http = lambda *_args, **_kwargs: (207, responses.pop(0), {})
    transaction_budget = [0]
    try:
        status, payload, _headers = mod.budgeted_caldav_http(transaction_budget, time.monotonic() + 1, "REPORT", "https://caldav.example.com/dav/", "user", "pass")
        if status != 207 or len(payload) != LIMIT or transaction_budget != [1, LIMIT]:
            raise SystemExit("not ok - exact-size CalDAV transaction should be accepted")
        try:
            mod.budgeted_caldav_http(transaction_budget, time.monotonic() + 1, "REPORT", "https://caldav.example.com/dav/", "user", "pass")
        except mod.CaldavTransactionTooLarge:
            pass
        else:
            raise SystemExit("not ok - oversized CalDAV transaction should fail")
    finally:
        mod.caldav_http = original_http
        mod.MAX_CALDAV_TRANSACTION_BYTES = original_transaction_limit
    print("ok - helper caldav transaction byte budget")

    mod.MAX_CALDAV_RESPONSE_BYTES = LIMIT
    exact = b"a" * LIMIT
    over = b"b" * (LIMIT + 1)

    body = mod.read_limited_http_body(FakeResponse(exact), LIMIT)
    if body != exact:
        raise SystemExit("not ok - exact-size body should be accepted")
    print("ok - helper caldav exact-size body")

    streamed = FakeResponse(exact, chunk_size=10)
    if mod.read_limited_http_body(streamed, LIMIT) != exact or streamed.body.read_calls < 3:
        raise SystemExit("not ok - partial chunks at the limit should be accepted")
    print("ok - helper caldav streamed exact-size body")

    expect_too_large(lambda: mod.read_limited_http_body(FakeResponse(over, {"Content-Length": str(LIMIT + 1)}), LIMIT))
    declared = FakeResponse(over, {"Content-Length": str(LIMIT + 1)})
    expect_too_large(lambda: mod.read_limited_http_body(declared, LIMIT))
    if declared.body.read_calls != 0:
        raise SystemExit("not ok - oversized Content-Length should not be read")
    print("ok - helper caldav oversized Content-Length")

    expect_too_large(lambda: mod.read_limited_http_body(FakeResponse(over, chunk_size=7), LIMIT))
    print("ok - helper caldav streamed oversized body")

    invalid = FakeResponse(exact, {"Content-Length": "nope"})
    if mod.read_limited_http_body(invalid, LIMIT) != exact:
        raise SystemExit("not ok - invalid Content-Length should fall back to a capped stream")
    print("ok - helper caldav invalid Content-Length")

    empty = FakeResponse(b"", {"Content-Length": "0"})
    if mod.read_limited_http_body(empty, LIMIT) != b"":
        raise SystemExit("not ok - empty CalDAV body should be accepted")
    print("ok - helper caldav empty body")

    expired = FakeResponse(exact)
    try:
        mod.read_limited_http_body(expired, LIMIT, deadline=time.monotonic() - 1)
    except TimeoutError:
        pass
    else:
        raise SystemExit("not ok - expired body-read deadline should fail")
    if expired.body.read_calls != 0:
        raise SystemExit("not ok - expired body-read deadline should not read")
    print("ok - helper caldav body-read deadline")

    class DripResponse(FakeResponse):
        def read1(self, size: int = -1) -> bytes:
            clock[0] += 0.6
            return self.read(1 if size < 0 else min(size, 1))

    clock = [0.0]
    original_monotonic = mod.time.monotonic
    mod.time.monotonic = lambda: clock[0]
    drip = DripResponse(b"abcd")
    try:
        mod.read_limited_http_body(drip, LIMIT, deadline=1.0)
    except TimeoutError:
        pass
    else:
        raise SystemExit("not ok - slow body stream should exceed its total deadline")
    finally:
        mod.time.monotonic = original_monotonic
    if drip.body.read_calls != 2:
        raise SystemExit(f"not ok - deadline should be checked after each receive ({drip.body.read_calls})")
    print("ok - helper caldav slow-stream deadline")

    started = time.monotonic()
    try:
        with mod.enforce_http_deadline(0.02):
            time.sleep(0.2)
    except TimeoutError:
        pass
    else:
        raise SystemExit("not ok - process-level HTTP deadline should interrupt blocking work")
    if time.monotonic() - started >= 0.15:
        raise SystemExit("not ok - process-level HTTP deadline fired too late")
    print("ok - helper caldav hard deadline")

    if hasattr(signal, "setitimer"):
        signal.setitimer(signal.ITIMER_REAL, 10)
        try:
            try:
                with mod.enforce_http_deadline(1):
                    pass
            except TimeoutError:
                pass
            else:
                raise SystemExit("not ok - nested process deadline should be rejected")
            remaining, _interval = signal.getitimer(signal.ITIMER_REAL)
            if remaining <= 0:
                raise SystemExit("not ok - existing process deadline should be preserved")
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
        print("ok - helper caldav nested deadline preservation")

    handler = mod.CaldavRedirectHandler(lambda _source, target: target.startswith("https://caldav.example.com/dav/"))
    report_request = urllib.request.Request("https://caldav.example.com/dav/cal", data=b"<xml/>", headers={"Content-Type": "application/xml"}, method="REPORT")
    redirected = handler.redirect_request(report_request, None, 307, "Temporary Redirect", Headers(), "https://caldav.example.com/dav/cal/")
    if redirected.get_method() != "REPORT" or redirected.data != b"<xml/>":
        raise SystemExit("not ok - allowed REPORT redirect should preserve method and body")
    propfind_request = urllib.request.Request("https://caldav.example.com/dav", data=b"<propfind/>", method="PROPFIND")
    redirected = handler.redirect_request(propfind_request, None, 301, "Moved", Headers(), "/dav/")
    if redirected.get_method() != "PROPFIND" or redirected.data != b"<propfind/>":
        raise SystemExit("not ok - allowed PROPFIND redirect should preserve method and body")
    try:
        handler.redirect_request(report_request, None, 307, "Temporary Redirect", Headers(), "https://attacker.invalid/dav/")
    except mod.CaldavUnsafeRedirect:
        pass
    else:
        raise SystemExit("not ok - cross-origin redirect should be rejected")
    class PasswordManager:
        def __init__(self):
            self.targets = []

        def add_password(self, _realm, target, _username, _password):
            self.targets.append(target)

    password_manager = PasswordManager()
    auth_handler = mod.CaldavRedirectHandler(lambda _source, target: target.startswith("https://caldav.example.com/dav/"), password_manager, "user", "pass")
    auth_handler.redirect_request(report_request, None, 307, "Temporary Redirect", Headers(), "https://caldav.example.com/dav/sibling/")
    if password_manager.targets != ["https://caldav.example.com/dav/sibling/"]:
        raise SystemExit("not ok - approved redirect should register scoped credentials")
    print("ok - helper caldav redirect policy")

    class SlowEmptyClient:
        def get_object_list_as_comps_sync(self, _query, _cancel):
            clock[0] = 2.0
            return True, []

    clock = [0.0]
    original_monotonic = mod.time.monotonic
    original_query = mod.eds_range_query
    mod.time.monotonic = lambda: clock[0]
    mod.eds_range_query = lambda _start, _end: "query"
    try:
        complete = mod.eds_pull_calendar_events(SlowEmptyClient(), {}, None, None, object(), [], deadline=1.0)
    finally:
        mod.time.monotonic = original_monotonic
        mod.eds_range_query = original_query
    if complete:
        raise SystemExit("not ok - EDS pull should fail when its blocking call exceeds the deadline")
    print("ok - helper EDS pull deadline")

    original = patch_opener(mod, FakeResponse(exact, {"Content-Length": str(LIMIT)}))
    try:
        status, payload = mod.caldav_propfind("https://caldav.example.com/dav/", "user", "pass")
    finally:
        restore_opener(original)
    if status != 207 or payload != exact:
        raise SystemExit("not ok - caldav_propfind should return a capped success body")
    print("ok - helper caldav_propfind exact-size body")

    original = patch_opener(mod, FakeResponse(over, {"Content-Length": str(LIMIT + 1)}))
    try:
        expect_too_large(lambda: mod.caldav_propfind("https://caldav.example.com/dav/", "user", "pass"))
    finally:
        restore_opener(original)
    print("ok - helper caldav_propfind oversized Content-Length")

    original = patch_opener(mod, FakeResponse(over, chunk_size=5))
    try:
        expect_too_large(lambda: mod.caldav_propfind("https://caldav.example.com/dav/", "user", "pass"))
    finally:
        restore_opener(original)
    print("ok - helper caldav_propfind streamed oversized body")

    err = http_error(over)
    original = patch_opener(mod, err)
    try:
        status, payload = mod.caldav_propfind("https://caldav.example.com/dav/", "user", "pass")
    finally:
        restore_opener(original)
    if status != 401 or payload != b"":
        raise SystemExit(f"not ok - caldav_propfind HTTP error should not return a body ({status!r}, {payload!r})")
    if err.fp.read_calls != 0:
        raise SystemExit("not ok - caldav_propfind should not read HTTP error bodies")
    print("ok - helper caldav_propfind unread HTTP error body")

    original = patch_opener(mod, FakeResponse(exact, {"Content-Length": str(LIMIT)}, status=207))
    try:
        status, payload, headers = mod.caldav_http("REPORT", "https://caldav.example.com/dav/", "user", "pass", b"<xml/>", {})
    finally:
        restore_opener(original)
    if status != 207 or payload != exact or headers.get("Content-Length") != str(LIMIT):
        raise SystemExit("not ok - caldav_http should return a capped success body")
    print("ok - helper caldav_http exact-size body")

    original = patch_opener(mod, FakeResponse(over, {"Content-Length": str(LIMIT + 1)}))
    try:
        status, payload, headers = mod.caldav_http("REPORT", "https://caldav.example.com/dav/", "user", "pass")
    finally:
        restore_opener(original)
    if status != 0 or payload != b"" or headers is not None:
        raise SystemExit("not ok - caldav_http oversized response should fall back without a body")
    print("ok - helper caldav_http oversized Content-Length")

    original = patch_opener(mod, FakeResponse(over, chunk_size=9))
    try:
        status, payload, headers = mod.caldav_http("GET", "https://caldav.example.com/event.ics", "user", "pass")
    finally:
        restore_opener(original)
    if status != 0 or payload != b"" or headers is not None:
        raise SystemExit("not ok - caldav_http streamed oversized body should fall back")
    print("ok - helper caldav_http streamed oversized body")

    err = http_error(over, 403)
    original = patch_opener(mod, err)
    try:
        status, payload, headers = mod.caldav_http("PROPFIND", "https://caldav.example.com/dav/", "user", "pass")
    finally:
        restore_opener(original)
    if status != 403 or payload != b"":
        raise SystemExit("not ok - caldav_http HTTP error should not return a body")
    if err.fp.read_calls != 0:
        raise SystemExit("not ok - caldav_http should not read HTTP error bodies")
    print("ok - helper caldav_http unread HTTP error body")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        print(f"not ok - helper caldav response limit: {error}", file=sys.stderr)
        raise
