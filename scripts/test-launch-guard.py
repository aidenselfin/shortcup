#!/usr/bin/env python3
"""Cases for check-launch-guard.py. Nothing is executed."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("guard", Path(__file__).with_name("check-launch-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

# Each snippet is a SAFE-path bypass and must be reported.
BYPASS = [
    ("open -g -n \"$APP\"", "open"),
    ("/usr/bin/open -g x", "open"),
    ("x=\"$(open -g y)\"", "open"),
    ("x=`open -g y`", "open"),
    ("cmd=\"${open}\"", "open"),
    ("n=$((open))", "open"),
    ("osascript -e 'tell application \"Finder\" to activate'", "osascript"),
    ("eval \"$cmd\"", "eval"),
    ("python3 -c 'print(1)'", "python3 -c"),
    ("/usr/bin/python3 -c 'print(1)'", "python3 -c"),
    ("python3 - <<'PY'\nprint(1)\nPY\n", "python3 -"),
    ("python3 - \"$err\" <<'PY'\nprint(1)\nPY\n", "python3 -"),
    ("awk 'BEGIN { system(\"id\") }'", "awk system("),
    ("git -c alias.x='!id' x", "git -c alias"),
    ("rg --pre python3 .", "rg --pre"),
    ("\"$app/Contents/MacOS/Fixture\" --x &", "app-binary path"),
    ("\"$bin/Contents/MacOS/ShortcupDev\" --selftest x &", "app-binary path"),
    ("~/Applications/Shortcup Dev.app", "app-binary path"),
    ("# LIVE-ONLY-START\nopen -g x\n# LIVE-ONLY-END\n", "open"),
    ("# LIVE-ONLY-START\neval \"$cmd\"\n# LIVE-ONLY-END\n", "eval"),
]

# Documentation heredoc bodies must not fail the scan.
ACCEPTED = [
    "codesign -d -r- \"$APP\"",
    "note() { print -r -- \"$1\"; }\nnote \"WARNING: starting the fixture later\"\n",
    "print -- \"the default uses LaunchServices with -g\"\n",
    "fail=$((fail + 1))\n",
    "if (( count > 1 )); then :; fi\n",
    "cat > x <<'EOF'\nopen -g inside heredoc\neval nope\nosascript\npython3 -c\npython3 -\nContents/MacOS/Fixture\nEOF\nprint done\n",
    "cat > \"$FIXTURE/Contents/Info.plist\" <<'EOF'\n<key>LSUIElement</key><true/>\nEOF\n",
    "/usr/bin/python3 scripts/check-launch-guard.py\n",
    "/bin/zsh -f build.sh --checks-only\n",
    "if [[ \"$live\" == 1 ]]; then\n  /bin/zsh -f \"$ROOT/scripts/verify-live.sh\" \"$@\"\nfi\n",
]

VERIFY_OK = """#!/bin/zsh
live=0
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    --direct-launch) ;;
    *) print -- "unknown argument: $arg"; exit 2 ;;
  esac
done
/usr/bin/python3 scripts/check-launch-guard.py
if [[ "$live" == 1 ]]; then
  /bin/zsh -f "$ROOT/scripts/verify-live.sh" "$@"
fi
"""

VERIFY_OUTSIDE = """#!/bin/zsh
live=0
/bin/zsh -f scripts/verify-live.sh
if [[ "$live" == 1 ]]; then
  /bin/zsh -f "$ROOT/scripts/verify-live.sh" "$@"
fi
"""

VERIFY_MISSING = """#!/bin/zsh
live=0
if [[ "$live" == 1 ]]; then
  print -- "no live script"
fi
"""


def main():
    failures = []
    for script, expect in BYPASS:
        found = guard.scan_file_text(script)
        if expect not in found:
            failures.append(f"expected {expect!r} for {script!r}, got {found}")
    for script in ACCEPTED:
        found = guard.scan_file_text(script)
        if found:
            failures.append(f"expected no problem for {script!r}, got {found}")
    if guard.live_script_only_in_branch(VERIFY_OK):
        failures.append("ok live branch was rejected: " + str(guard.live_script_only_in_branch(VERIFY_OK)))
    outside = guard.live_script_only_in_branch(VERIFY_OUTSIDE)
    if "verify.sh names the live script outside the live == 1 branch" not in outside:
        failures.append("outside live-script reference was not reported: " + str(outside))
    missing = guard.live_script_only_in_branch(VERIFY_MISSING)
    if "live == 1 branch does not run scripts/verify-live.sh" not in missing:
        failures.append("missing live-script call was not reported: " + str(missing))
    if failures:
        print("\n".join(failures))
        return 1
    print(f"PASS: launch guard cases ({len(BYPASS) + len(ACCEPTED) + 3})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
