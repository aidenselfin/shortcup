#!/usr/bin/env python3
"""Inspect a signed Shortcup Dev.app. Does not launch it."""
import subprocess
import sys
from pathlib import Path


def exe_of(app):
    return Path(app) / "Contents" / "MacOS" / "ShortcupDev"


def running(app):
    exe = str(exe_of(app))
    helper = Path(__file__).resolve().parent / "stop-launched.py"
    result = subprocess.run(
        [sys.executable, str(helper), "find", exe],
        capture_output=True,
        text=True,
        errors="replace",
    )
    return bool(result.stdout.strip())


def inspect(app):
    app = Path(app)
    exe = exe_of(app)
    req = subprocess.run(
        ["/usr/bin/codesign", "-d", "-r-", str(app)],
        capture_output=True,
        text=True,
        errors="replace",
    )
    requirement = (req.stdout or "") + (req.stderr or "")
    print(requirement, end="" if requirement.endswith("\n") else "\n")
    if "certificate leaf" not in requirement:
        print("FAIL: designated requirement has no certificate leaf")
        return 1
    plist = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :LSMinimumSystemVersion", str(app / "Contents" / "Info.plist")],
        capture_output=True,
        text=True,
        errors="replace",
    )
    ui = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :LSUIElement", str(app / "Contents" / "Info.plist")],
        capture_output=True,
        text=True,
        errors="replace",
    )
    vtool = subprocess.run(
        ["/usr/bin/vtool", "-show-build", str(exe)],
        capture_output=True,
        text=True,
        errors="replace",
    )
    bin_min = ""
    for line in vtool.stdout.splitlines():
        if "minos" in line:
            parts = line.split()
            if len(parts) >= 2:
                bin_min = parts[1]
            break
    plist_min = (plist.stdout or "").strip()
    lsui = (ui.stdout or "").strip()
    print("plist_min=" + plist_min)
    print("binary_min=" + bin_min)
    print("LSUIElement=" + lsui)
    if plist_min != bin_min or not bin_min or lsui != "true":
        print("FAIL: dev plist does not match the binary or LSUIElement is not true")
        return 1
    print("inspect=ok")
    return 0


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("--running", "--inspect"):
        print("usage: check-dev-bundle.py --running|--inspect <app>", file=sys.stderr)
        return 2
    app = sys.argv[2]
    if sys.argv[1] == "--running":
        return 0 if running(app) else 1
    return inspect(app)


if __name__ == "__main__":
    sys.exit(main())
