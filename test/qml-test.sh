#!/bin/bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT/Service.qml" <<'PY'
import re
import sys

source = open(sys.argv[1]).read()
blocks = re.findall(r"\n  Process \{\n(.*?)\n  \}\n", source, re.S)
checked = 0
for block in blocks:
    if "stdinEnabled: true" not in block:
        continue
    ident = re.search(r"id: (\w+)", block)
    name = ident.group(1) if ident else "<anonymous>"
    started = re.search(r"onStarted: \{(.*?)\n    \}", block, re.S)
    if started is None:
        raise SystemExit(f"not ok - {name} enables stdin but has no onStarted handler")
    body = started.group(1)
    if "write(secret" not in body:
        raise SystemExit(f"not ok - {name} enables stdin but does not write the secret")
    if "secret = \"\"" not in body:
        raise SystemExit(f"not ok - {name} does not clear the secret after write")
    if "stdinEnabled = false" not in body:
        raise SystemExit(f"not ok - {name} writes to stdin without closing it")
    checked += 1

if checked == 0:
    raise SystemExit("not ok - found no stdin-enabled Process blocks to check")
print(f"ok - {checked} stdin-enabled processes close stdin and clear secrets")
PY

if ! grep -q "id: setupTimeout" "$ROOT/Service.qml"; then
  echo "not ok - setup timeout is missing"
  exit 1
fi
echo "ok - setup has a timeout"

if ! grep -q 'root.bar.setCenterHoverRevealSuppressed(' "$ROOT/Panel.qml"; then
  echo "not ok - panel must use the bar API setter for centerHoverRevealSuppressed (read-only on Omarchy 4.0.3+)"
  exit 1
fi
echo "ok - panel uses the bar API setter for the center hover reveal flag"

python3 - "$ROOT/Panel.qml" <<'PY'
import re
import sys

source = open(sys.argv[1]).read()
match = re.search(r"Dropdown \{\n\s+id: createCalendarDropdown\n(.*?)\n\s+\}", source, re.S)
if match is None:
    raise SystemExit("not ok - create calendar dropdown is missing")
block = match.group(1)
if "value: root.createCalendarId" not in block:
    raise SystemExit("not ok - create calendar dropdown is not bound to form state")
if "createCalendarDropdown.value = Qt.binding(function() { return root.createCalendarId })" not in block:
    raise SystemExit("not ok - create calendar dropdown does not restore the binding destroyed by shared Dropdown")
print("ok - create calendar dropdown restores its controlled value binding")
PY

if ! grep -q 'payload.events && payload.events.length ? payload.events' "$ROOT/Service.qml"; then
  echo "not ok - recurring create response does not replace optimistic events with expanded occurrences" >&2
  exit 1
fi
echo "ok - recurring creates use expanded helper occurrences"

python3 - "$ROOT/Panel.qml" "$ROOT/Service.qml" <<'PY'
import re
import sys

panel = open(sys.argv[1]).read()
service = open(sys.argv[2]).read()
commit = re.search(r"function commitCreatingEvent\(\) \{(.*?)\n  \}", panel, re.S)
if commit is None:
    raise SystemExit("not ok - create event submit handler is missing")
body = commit.group(1)
closed = body.find("creatingEvent = false")
deferred = body.find("Qt.callLater(function()")
dispatched = body.find("service.createEvent(")
if closed < 0 or deferred < 0 or dispatched < 0 or not closed < deferred < dispatched:
    raise SystemExit("not ok - create dialog must close before deferred event creation")
if "mergeEvents(expanded)" not in service or "mergeEvent(expanded[i])" in service:
    raise SystemExit("not ok - optimistic recurring events must be merged in one batch")
print("ok - create dialog closes before batched optimistic event creation")
PY
