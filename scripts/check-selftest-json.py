#!/usr/bin/env python3
"""Allow-list the selftest result. Prints result= and exits 0, or exits 1 on a bad shape."""
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
if not isinstance(data, dict):
    raise SystemExit("selftest JSON is not an object")

skipped = data.get("result") == "skipped"
allowed = {"trusted", "result", "cases"} if skipped else {
    "trusted", "result", "cases", "titleFallbackReads", "hangSeconds",
    "menuWalksAfterFirst", "menuWalksAfterSecond", "idleAxReads",
    "canaryLeak", "axAllowListOK", "disallowed",
}
extra = set(data) - allowed
if extra:
    raise SystemExit("extra keys: " + ",".join(sorted(extra)))
cases = data.get("cases", [])
if not isinstance(cases, list):
    raise SystemExit("cases is not a list")
for item in cases:
    if not isinstance(item, dict):
        raise SystemExit("case is not an object")
    if set(item) - {"subrole", "identifier", "shortcut", "result"}:
        raise SystemExit("case has a disallowed key")

print("schema=ok")
print("result=" + str(data.get("result")))
print("trusted=" + str(data.get("trusted")))
if not skipped:
    print("hangSeconds=" + str(data.get("hangSeconds")))
    print("menuWalks=" + str(data.get("menuWalksAfterFirst")) + "->" + str(data.get("menuWalksAfterSecond")))
    print("idleAxReads=" + str(data.get("idleAxReads")))
    print("titleFallbackReads=" + str(data.get("titleFallbackReads")))
    print("canaryLeak=" + str(data.get("canaryLeak")))
    print("axAllowListOK=" + str(data.get("axAllowListOK")))
    print("cases=" + str(len(cases)))
