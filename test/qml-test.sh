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

python3 - "$ROOT/Panel.qml" <<'PY'
from collections import Counter
import re
import sys

source = open(sys.argv[1]).read()
section = re.search(r'text: "Repeat"(.*?)text: "Meeting"', source, re.S)
if section is None:
    raise SystemExit("not ok - recurrence controls are missing")
controls = section.group(1)
bound = Counter(re.findall(r'value: (?:String\()?root\.createRecurrence\.(\w+)', controls))
bound.pop("until", None)  # The recurrence end date uses DatePicker, not Dropdown.
restored = Counter(re.findall(r'restoreRecurrenceDropdownBinding\(\w+, "(\w+)"\)', controls))
dropdowns = re.findall(r'id: recurrence\w+Dropdown', controls)
if not bound or bound != restored or len(dropdowns) != sum(bound.values()):
    raise SystemExit(f"not ok - recurrence dropdown bindings are not restored: bound={bound}, restored={restored}")
helper = re.search(r'function restoreRecurrenceDropdownBinding\(dropdown, field\) \{(.*?)\n  \}', source, re.S)
if helper is None or "dropdown.value = Qt.binding(function()" not in helper.group(1):
    raise SystemExit("not ok - recurrence dropdown binding helper is missing")
print(f"ok - {sum(bound.values())} recurrence dropdowns restore their controlled bindings")
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

python3 - "$ROOT/Panel.qml" "$ROOT/Service.qml" <<'PY'
import re
import sys

panel = open(sys.argv[1]).read()
service = open(sys.argv[2]).read()
default_writable = re.search(r"function defaultWritableCalendarId\(\) \{(.*?)\n  \}", service, re.S)
if default_writable is None or 'return ""' not in default_writable.group(1):
    raise SystemExit("not ok - read-only calendars can be selected as writable fallbacks")
for function in ("createEvent", "updateEvent", "deleteEvent"):
    body = re.search(rf"function {function}\([^)]*\) \{{(.*?)\n  \}}", service, re.S)
    if body is None or "rejectReadonlyMutation()" not in body.group(1):
        raise SystemExit(f"not ok - {function} does not reject read-only calendars")
if "function eventIsReadonly(event)" not in panel or "root.eventIsRecurring(event) || root.eventIsReadonly(event)" not in panel:
    raise SystemExit("not ok - read-only events still open the editor directly")
if panel.count("visible: !root.eventIsReadonly(root.contextEvent)") < 2:
    raise SystemExit("not ok - read-only event edit/remove actions are still visible")
print("ok - read-only subscriptions expose no calendar mutations")
PY
