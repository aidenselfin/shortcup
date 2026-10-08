#!/usr/bin/env python3
"""Canary roots must stay on Shortcup paths. Nothing is executed."""
import sys
from pathlib import Path

import importlib.util

spec = importlib.util.spec_from_file_location("canary", Path(__file__).with_name("canary-paths.py"))
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)

HOME = Path.home()


def main():
    failures = []
    allowed = [
        HOME / "Library" / "Application Support" / "com.shortcup.dev",
        HOME / "Library" / "Application Support" / "com.shortcup.app" / "state.plist",
        HOME / "Library" / "Logs" / "com.shortcup.dev" / "app.log",
        HOME / "Library" / "Logs" / "Shortcup Dev",
        HOME / "Applications" / "validation-events.jsonl",
        HOME / "Applications" / "validation-state.json",
        HOME / ".config" / "shortcup" / "dev-identity-version",
    ]
    refused = [
        HOME / "Library" / "Containers",
        HOME / "Library" / "Containers" / "com.shortcup.dev",
        HOME / "Library" / "Preferences",
        HOME / "Library" / "Preferences" / "com.shortcup.dev.plist",
        HOME / "Library" / "Caches" / "com.shortcup.dev",
        HOME / "Library" / "Caches" / "com.example.other",
        HOME / "Library" / "Saved Application State" / "com.shortcup.dev.savedState",
        HOME / "Library" / "Application Support" / "com.example.other",
        HOME / "Library" / "Application Support" / "ShortcupExtra",
        HOME / "Library" / "Logs" / "com.example.other",
        HOME / "Library" / "Logs" / "ShortcupExtra",
        HOME / ".config" / "shortcup" / "verify-canary",
        HOME / ".config" / "shortcup" / "keychain-password",
        Path("/tmp"),
        HOME / "Applications" / "Other.app" / "Contents" / "Info.plist",
    ]
    for path in allowed:
        if not canary.is_allowed(path):
            failures.append("should allow " + str(path).replace(str(HOME), "~"))
    for path in refused:
        if canary.is_allowed(path):
            failures.append("should refuse " + str(path).replace(str(HOME), "~"))
    names = {p.name for p in canary.scan_roots() if p.parent == HOME / ".config" / "shortcup"}
    if "verify-canary" in names or "keychain-password" in names:
        failures.append("config scan includes the canary or password file")
    if failures:
        print("\n".join(failures))
        return 1
    print("PASS: canary scan roots stay on Shortcup paths")
    return 0


if __name__ == "__main__":
    sys.exit(main())
