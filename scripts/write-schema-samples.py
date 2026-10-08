#!/usr/bin/env python3
"""Write selftest JSON samples used by the SAFE schema allow-list."""
import json
import sys
from pathlib import Path

CASE = {"subrole": "AXCloseButton", "identifier": "", "shortcut": "", "result": "pass"}
SKIP_CASE = dict(CASE, result="skip")
PASS_EXTRA = {
    "trusted": True,
    "axTrusted": True,
    "launchMethod": "open",
    "result": "pass",
    "cases": [CASE],
    "titleFallbackReads": 1,
    "hangSeconds": 0.01,
    "menuWalksAfterFirst": 1,
    "menuWalksAfterSecond": 1,
    "idleAxReads": 0,
    "canaryLeak": False,
    "axAllowListOK": True,
    "disallowed": [],
}


def write(path, data):
    Path(path).write_text(json.dumps(data, separators=(",", ":")) + "\n")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: write-schema-samples.py DIR")
    dest = Path(sys.argv[1])
    dest.mkdir(parents=True, exist_ok=True)
    write(dest / "skipped.json", {"cases": [], "result": "skipped", "trusted": False, "axTrusted": False, "launchMethod": "open"})
    write(dest / "skipped-direct.json", {"cases": [], "result": "skipped", "trusted": False, "axTrusted": False, "launchMethod": "direct"})
    write(dest / "pass.json", PASS_EXTRA)
    write(dest / "skip-case.json", dict(PASS_EXTRA, launchMethod="direct", result="fail", cases=[SKIP_CASE]))
    write(dest / "extra.json", {"cases": [], "result": "skipped", "trusted": False, "axTrusted": False, "launchMethod": "open", "title": "should-not-be-here"})
    bad_bool = dict(PASS_EXTRA, titleFallbackReads=True)
    write(dest / "bool-int.json", bad_bool)
    nested = dict(PASS_EXTRA, cases=[dict(CASE, extra="no")])
    write(dest / "nested.json", nested)
    write(dest / "bad-launch.json", {"cases": [], "result": "skipped", "trusted": False, "axTrusted": False, "launchMethod": "fork"})
    write(dest / "mismatch.json", {"cases": [], "result": "skipped", "trusted": False, "axTrusted": True, "launchMethod": "open"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
