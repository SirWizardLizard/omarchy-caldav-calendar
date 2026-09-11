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
