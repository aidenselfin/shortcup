#!/usr/bin/env python3
"""Judge the fixture's own AX dump. The dump has no titles, so this never prints UI text."""
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)

windows = set(data.get("windows") or [])
buttons = data.get("buttons") or []
items = data.get("menuItems") or []
problems = []

if "AXStandardWindow" not in windows:
    problems.append("missing AXStandardWindow")
if "AXSystemFloatingWindow" not in windows:
    problems.append("missing AXSystemFloatingWindow")
if int(data.get("sheetCount") or 0) < 1:
    problems.append("missing AXSheet")

idents = {b.get("identifier") for b in buttons}
if "fixture.tabClose" not in idents:
    problems.append("missing fixture.tabClose")
if "fixture.sheetClose" not in idents:
    problems.append("missing fixture.sheetClose")

def item_char(item):
    return str(item.get("char") or "").casefold()

def items_with(identifier):
    return [item for item in items if item.get("identifier") == identifier]

mini = items_with("performMiniaturize:")
zoom = items_with("performZoom:")
full = items_with("toggleFullScreen:")
close = [item for item in items if item.get("identifier") == "" and item_char(item) == "w" and (int(item.get("modifiers") or 0) & 1)]

if not any(item_char(item) == "m" for item in mini):
    problems.append("performMiniaturize: missing")
if not zoom or zoom[0].get("char") not in ("", None):
    problems.append("performZoom: should have no shortcut character")
if len(full) < 2:
    problems.append("toggleFullScreen: expected two items")
if not close:
    problems.append("identifier-less shift-command W missing")

mods = ",".join(str(item.get("modifiers")) for item in full) if full else "none"
print("windows=" + ",".join(sorted(windows)))
print("sheetCount=" + str(data.get("sheetCount")))
print("hasFullScreenButton=" + str(bool(data.get("hasFullScreenButton"))))
print("toggleFullScreenModifiers=" + mods)
if problems:
    print("structure=fail")
    for problem in problems:
        print(problem)
    raise SystemExit(1)
print("structure=ok")
