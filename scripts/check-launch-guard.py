#!/usr/bin/env python3
"""Fail if verify.sh can launch an app outside the live-only section.

Inside that section both launch methods must exist: open -g, and a direct
Contents/MacOS executable. Only one of them runs. --direct-launch selects it.
"""
import re
import sys
from pathlib import Path

OPEN = re.compile(r"(?:^|[;&|`])\s*open(?:\s|$)")
DIRECT = re.compile(r"Contents/MacOS/(?:Shortcup|ShortcupDev|Fixture)\b")
SAFE_TOOLS = ("codesign", "vtool", "grep", "strings", "cmp", "ditto", "ps", "PlistBuddy", "awk", "swiftc")


def command_open(line):
    stripped = line.strip()
    if stripped.startswith("#"):
        return False
    if OPEN.search(line):
        return True
    return bool(re.match(r"open(?:\s|$)", stripped))


def direct_launch(line):
    if not DIRECT.search(line):
        return False
    return not any(tool in line for tool in SAFE_TOOLS)


def main():
    text = Path("verify.sh").read_text()
    live = False
    problems = []
    saw_live_open = False
    saw_live_direct = False
    live_lines = []
    for number, line in enumerate(text.splitlines(), 1):
        if "LIVE-ONLY-START" in line:
            live = True
            continue
        if "LIVE-ONLY-END" in line:
            live = False
            continue
        if live:
            live_lines.append(line)
        if line.strip().startswith("#"):
            continue
        if command_open(line) or direct_launch(line):
            if not live:
                problems.append(f"verify.sh:{number} launches outside --live")
            elif command_open(line):
                saw_live_open = True
                if "-g" not in line:
                    problems.append(f"verify.sh:{number} open is missing -g")
            if live and direct_launch(line):
                saw_live_direct = True
    if not saw_live_open:
        problems.append("live section has no open -g command")
    if not saw_live_direct:
        problems.append("live section has no direct executable launch")
    live_text = "\n".join(live_lines)
    if "--launch-method open" not in live_text or "--launch-method direct" not in live_text:
        problems.append("live section does not pass --launch-method open and direct")
    if "--direct-launch" not in text or "SHORTCUP_LAUNCH" not in text:
        problems.append("verify.sh has no --direct-launch or SHORTCUP_LAUNCH switch")
    if "LSUIElement" not in text:
        problems.append("fixture plist in verify.sh is missing LSUIElement")
    if "LSUIElement" not in Path("build.sh").read_text():
        problems.append("dev bundle plist is missing LSUIElement")

    selftest = Path("Sources/SelfTest.swift").read_text()
    if "AXUIElementPerformAction" in selftest or "AXPress" in selftest:
        problems.append("SelfTest uses AXPress")
    if "Contents/MacOS/Fixture" not in selftest:
        problems.append("SelfTest has no direct Fixture launch")
    if '"-g"' not in selftest:
        problems.append("SelfTest open is missing -g")
    if "--launch-method" not in selftest or "launchMethod" not in selftest:
        problems.append("SelfTest does not record the launch method")
    if "axTrusted" not in selftest or "AXIsProcessTrusted()" not in selftest:
        problems.append("SelfTest does not record AXIsProcessTrusted()")
    if "NSApp.activate" in selftest or "setActivationPolicy(.regular)" in selftest:
        problems.append("SelfTest can still activate")

    app = Path("Sources/App.swift").read_text()
    if "NSApp.activate" in app:
        problems.append("dev app calls NSApp.activate")
    if "override var canBecomeKey: Bool { false }" not in app:
        problems.append("dev panel can still become key")

    fixture = Path("Fixture/main.swift").read_text()
    if "beginSheet" in fixture:
        problems.append("fixture still presents a modal sheet")
    if "NSTextField(string:" in fixture:
        problems.append("fixture still has an editable text field")
    if "NSApp.activate" in fixture or "setActivationPolicy(.regular)" in fixture:
        problems.append("fixture can still activate")
    if "override var canBecomeKey: Bool { false }" not in fixture:
        problems.append("fixture window can still become key")

    if problems:
        print("\n".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
