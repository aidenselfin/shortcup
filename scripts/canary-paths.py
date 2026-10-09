#!/usr/bin/env python3
"""Shortcup-owned canary scan roots. Other apps' data is never listed.

Prints one path per line. --allowed PATH exits 0 when PATH is inside that set.
"""
import os
import sys
from pathlib import Path

IDS = ("com.shortcup.dev", "com.shortcup.app")
SHORTCUP_FOLDERS = ("Shortcup Dev", "Shortcup")
SKIP_CONFIG = {"verify-canary", "keychain-password"}
VALIDATION_FILES = ("validation-events.jsonl", "validation-state.json")


def home():
    return Path.home()


def _norm(path):
    path = Path(path).expanduser()
    try:
        return path.resolve() if path.exists() else Path(os.path.normpath(str(path)))
    except OSError:
        return Path(os.path.normpath(str(path)))


def _under(path, root):
    path_n = _norm(path)
    root_n = _norm(root)
    if path_n == root_n:
        return True
    return str(path_n).startswith(str(root_n) + os.sep)


def scan_roots():
    base = home()
    roots = []
    for ident in IDS:
        roots.append(base / "Library" / "Application Support" / ident)
        roots.append(base / "Library" / "Logs" / ident)
    support = base / "Library" / "Application Support"
    logs = base / "Library" / "Logs"
    if support.is_dir():
        roots.extend(sorted(support / name for name in SHORTCUP_FOLDERS if (support / name).exists()))
    if logs.is_dir():
        roots.extend(sorted(logs / name for name in SHORTCUP_FOLDERS if (logs / name).exists()))
    config = base / ".config" / "shortcup"
    if config.is_dir():
        for item in sorted(config.iterdir()):
            if item.name not in SKIP_CONFIG:
                roots.append(item)
    apps = base / "Applications"
    for name in VALIDATION_FILES:
        roots.append(apps / name)
    return roots


def is_allowed(path):
    path = Path(path).expanduser()
    base = home()
    for folder in ("Application Support", "Logs"):
        parent = base / "Library" / folder
        for ident in IDS:
            if _under(path, parent / ident):
                return True
        try:
            relative = _norm(path).relative_to(_norm(parent))
        except ValueError:
            relative = None
        if relative is not None and relative.parts and relative.parts[0] in SHORTCUP_FOLDERS:
            return True
    config = base / ".config" / "shortcup"
    try:
        relative = _norm(path).relative_to(_norm(config))
    except ValueError:
        relative = None
    if relative is not None and relative.parts and relative.parts[0] not in SKIP_CONFIG:
        return True
    apps = base / "Applications"
    for name in VALIDATION_FILES:
        if _norm(path) == _norm(apps / name):
            return True
    return False


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--allowed":
        return 0 if is_allowed(sys.argv[2]) else 1
    if len(sys.argv) != 1:
        print("usage: canary-paths.py | canary-paths.py --allowed PATH", file=sys.stderr)
        return 2
    for root in scan_roots():
        print(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
