#!/usr/bin/env python3
"""Allow-list the selftest result. Nested values are checked. Exits 0 or 1."""
import json
import sys

CASE_KEYS = ("subrole", "identifier", "shortcut", "result")
CASE_RESULTS = {"pass", "fail", "skip"}
LAUNCH_METHODS = {"open", "direct"}
PASS_KEYS = (
    "trusted", "axTrusted", "launchMethod", "result", "cases", "titleFallbackReads", "hangSeconds",
    "menuWalksAfterFirst", "menuWalksAfterSecond", "idleAxReads",
    "canaryLeak", "axAllowListOK", "disallowed",
)
SKIP_KEYS = ("trusted", "axTrusted", "launchMethod", "result", "cases")


def is_bool(value):
    return isinstance(value, bool)


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_string(value):
    return isinstance(value, str)


def reject(message):
    raise SystemExit(message)


def check_case(item):
    if not isinstance(item, dict):
        reject("case is not an object")
    if set(item) != set(CASE_KEYS):
        reject("case keys must be subrole, identifier, shortcut, result")
    for key in CASE_KEYS:
        if not is_string(item[key]):
            reject("case " + key + " must be a string")
    if item["result"] not in CASE_RESULTS:
        reject("case result must be pass, fail, or skip")


def check(data):
    if not isinstance(data, dict):
        reject("selftest JSON is not an object")
    result = data.get("result")
    if result == "skipped":
        if set(data) != set(SKIP_KEYS):
            reject("skipped result has unexpected keys")
        if not is_bool(data["trusted"]) or data["trusted"] is not False:
            reject("skipped trusted must be false")
        if not is_bool(data["axTrusted"]) or data["axTrusted"] is not False:
            reject("skipped axTrusted must be false")
        if data["axTrusted"] != data["trusted"]:
            reject("axTrusted must match trusted")
        if data["launchMethod"] not in LAUNCH_METHODS:
            reject("launchMethod must be open or direct")
        if not isinstance(data["cases"], list):
            reject("cases is not a list")
        for item in data["cases"]:
            check_case(item)
        return
    if set(data) != set(PASS_KEYS):
        missing = [key for key in PASS_KEYS if key not in data]
        extra = sorted(set(data) - set(PASS_KEYS))
        reject("result keys mismatch missing=" + ",".join(missing) + " extra=" + ",".join(extra))
    if not is_bool(data["trusted"]):
        reject("trusted must be a boolean")
    if not is_bool(data["axTrusted"]) or data["axTrusted"] != data["trusted"]:
        reject("axTrusted must be a boolean and match trusted")
    if data.get("launchMethod") not in LAUNCH_METHODS:
        reject("launchMethod must be open or direct")
    if result not in {"pass", "fail"}:
        reject("result must be pass, fail, or skipped")
    if not isinstance(data["cases"], list):
        reject("cases is not a list")
    for item in data["cases"]:
        check_case(item)
    for key in ("titleFallbackReads", "menuWalksAfterFirst", "menuWalksAfterSecond", "idleAxReads"):
        if not is_int(data[key]):
            reject(key + " must be an integer")
    if not is_number(data["hangSeconds"]):
        reject("hangSeconds must be a number")
    if not is_bool(data["canaryLeak"]) or not is_bool(data["axAllowListOK"]):
        reject("canaryLeak and axAllowListOK must be booleans")
    if not isinstance(data["disallowed"], list) or not all(is_string(item) for item in data["disallowed"]):
        reject("disallowed must be a list of strings")


path = sys.argv[1]
with open(path) as handle:
    parsed = json.load(handle)
check(parsed)
skipped = parsed.get("result") == "skipped"
print("schema=ok")
print("result=" + str(parsed.get("result")))
print("trusted=" + str(parsed.get("trusted")))
print("axTrusted=" + str(parsed.get("axTrusted")))
print("launchMethod=" + str(parsed.get("launchMethod")))
if not skipped:
    print("hangSeconds=" + str(parsed.get("hangSeconds")))
    print("menuWalks=" + str(parsed.get("menuWalksAfterFirst")) + "->" + str(parsed.get("menuWalksAfterSecond")))
    print("idleAxReads=" + str(parsed.get("idleAxReads")))
    print("titleFallbackReads=" + str(parsed.get("titleFallbackReads")))
    print("canaryLeak=" + str(parsed.get("canaryLeak")))
    print("axAllowListOK=" + str(parsed.get("axAllowListOK")))
    print("cases=" + str(len(parsed.get("cases", []))))
