#!/usr/bin/env python3

import json
import os
import stat
import tempfile
from importlib.machinery import SourceFileLoader
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
helper = SourceFileLoader("omarchy_calendar_permissions_test", str(ROOT / "helper/omarchy-calendar-helper")).load_module()


def mode(path: Path) -> int:
    return stat.S_IMODE(path.lstat().st_mode)


old_override = os.environ.get("OMARCHY_CALENDAR_CACHE")
old_shell_config = os.environ.get("OMARCHY_SHELL_CONFIG")
old_umask = os.umask(0)
try:
    with tempfile.TemporaryDirectory() as temporary_root:
        root = Path(temporary_root)
        cache = root / "calendar-state"
        cache.mkdir(mode=0o777)
        initial = {
            "cache.json": '{"ok":true,"calendars":[],"events":[]}',
            "cache.lock": "",
            "cache.dirty.json": "{}",
            "reminders.json": "{}",
            "sync.log": "old\n",
        }
        for name, contents in initial.items():
            path = cache / name
            path.write_text(contents, encoding="utf-8")
            path.chmod(0o666)
        os.environ["OMARCHY_CALENDAR_CACHE"] = str(cache)

        assert helper.cache_dir() == cache
        assert mode(cache) == 0o700
        for name in initial:
            assert mode(cache / name) == 0o600, (name, oct(mode(cache / name)))

        observed_temps = []
        original_replace = helper.os.replace

        def observe_replace(source, destination):
            observed_temps.append((Path(source).name, mode(Path(source))))
            return original_replace(source, destination)

        helper.os.replace = observe_replace
        try:
            helper.sync_log("permission-test", calendarId="private-calendar")
            assert helper.write_reminders({"minutes": 5, "fired": ["private-event"]})["ok"] is True
            assert helper.write_cache({"ok": True, "calendars": [], "events": []}) is not None
            helper.write_dirty_touches({"calendar": {"series:event": {"op": "delete", "uid": "event"}}})

            shell = root / "shell.json"
            shell.write_text(json.dumps({"bar": {"centerAnchor": "omarchy.clock", "layout": {"center": [{"id": "sirwizardlizard.calendar"}]}}}), encoding="utf-8")
            shell.chmod(0o640)
            os.environ["OMARCHY_SHELL_CONFIG"] = str(shell)
            assert helper.ensure_center_anchor("sirwizardlizard.calendar")["changed"] is True
            assert mode(shell) == 0o640
        finally:
            helper.os.replace = original_replace

        assert observed_temps
        assert all(item_mode == (0o640 if name.startswith(".shell.json.") else 0o600) for name, item_mode in observed_temps), observed_temps
        for name in initial:
            assert mode(cache / name) == 0o600, (name, oct(mode(cache / name)))
        assert not list(cache.glob(".*.tmp"))

        sentinel = root / "sentinel"
        sentinel.write_text("unchanged", encoding="utf-8")
        unsafe_root = root / "unsafe-root"
        unsafe_root.symlink_to(root, target_is_directory=True)
        os.environ["OMARCHY_CALENDAR_CACHE"] = str(unsafe_root)
        try:
            helper.cache_dir()
        except OSError:
            pass
        else:
            raise AssertionError("symlinked cache root should be rejected")
        assert sentinel.read_text(encoding="utf-8") == "unchanged"

        safe_root = root / "safe-root"
        os.environ["OMARCHY_CALENDAR_CACHE"] = str(safe_root)
        helper.cache_dir()
        (safe_root / "sync.log").symlink_to(sentinel)
        helper.sync_log("must-not-follow")
        assert sentinel.read_text(encoding="utf-8") == "unchanged"
        assert helper.read_cache() is None
        assert helper.write_reminders({"minutes": 10, "fired": []})["ok"] is True
        (safe_root / "sync.log").unlink()
        os.mkfifo(safe_root / "sync.log", mode=0o666)
        helper.sync_log("must-not-open-fifo")
        (safe_root / "sync.log").unlink()
        (safe_root / "cache.lock").symlink_to(sentinel)
        assert helper.read_reminders()["ok"] is True
        try:
            helper.write_cache({"ok": True, "calendars": [], "events": []})
        except OSError:
            pass
        else:
            raise AssertionError("symlinked cache lock should be rejected")
        assert sentinel.read_text(encoding="utf-8") == "unchanged"

finally:
    os.umask(old_umask)
    if old_override is None:
        os.environ.pop("OMARCHY_CALENDAR_CACHE", None)
    else:
        os.environ["OMARCHY_CALENDAR_CACHE"] = old_override
    if old_shell_config is None:
        os.environ.pop("OMARCHY_SHELL_CONFIG", None)
    else:
        os.environ["OMARCHY_SHELL_CONFIG"] = old_shell_config

print("ok - private calendar state permissions")
