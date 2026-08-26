#!/bin/bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Helper operations that read a JSON payload from stdin block until EOF. Every
# Process that enables stdin must therefore close it after writing, or the
# helper hangs forever and the UI sticks on its progress message.
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
    if "stdinEnabled = false" not in started.group(1):
        raise SystemExit(f"not ok - {name} writes to stdin without closing it (helper would hang)")
    checked += 1

if checked == 0:
    raise SystemExit("not ok - found no stdin-enabled Process blocks to check")
print(f"ok - {checked} stdin-enabled processes close stdin")
PY

if ! grep -q "id: setupWatchdog" "$ROOT/Service.qml"; then
  echo "not ok - setup watchdog is missing"
  exit 1
fi
echo "ok - setup has a watchdog"
