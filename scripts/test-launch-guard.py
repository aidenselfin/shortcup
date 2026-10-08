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
    ("cmd=open; \"$cmd\"", "variable command"),
    ("osascript -e 'tell application \"Finder\" to activate'", "osascript"),
    ("eval \"$cmd\"", "eval"),
    ("python3 -c 'print(1)'", "python3 -c"),
    ("/usr/bin/python3 -c 'print(1)'", "python3 -c"),
    ("python3 - <<'PY'\nprint(1)\nPY\n", "python3 -"),
    ("python3 - \"$err\" <<'PY'\nprint(1)\nPY\n", "python3 -"),
    ("awk 'BEGIN { system(\"id\") }'", "awk is not allowed"),
    ("git -c alias.x='!id' x", "git -c"),
    ("rg --pre python3 .", "rg --pre"),
    ("rg --pre=python3 .", "rg --pre"),
    ("git '-c' alias.x='!id' x", "git -c"),
    ("git --config alias.x='!id' x", "git -c"),
    ("git -c core.hooksPath=/tmp ls-files", "git -c"),
    ("GIT_CONFIG_COUNT=1 /usr/bin/git ls-files", "GIT_CONFIG_"),
    ("GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=id /usr/bin/git status", "GIT_CONFIG_"),
    ("RIPGREP_CONFIG_PATH=/tmp/rgrc /opt/homebrew/bin/rg .", "RIPGREP_CONFIG_PATH"),
    ("x=\"${(e)foo}\"", "zsh parameter-expansion flags"),
    ("ls *(e:id:)", "glob qualifier (e:"),
    ("ls *(+foo)", "glob qualifier (+"),
    ("/bin/zsh --interactive -f build.sh", "zsh --interactive"),
    ("/bin/zsh --shinstdin -f build.sh", "zsh --shinstdin"),
    ("awk -f /dev/stdin", "awk is not allowed"),
    ("awk 'BEGIN { print | \"id\" }'", "awk is not allowed"),
    ("awk '{ \"id\" | getline }'", "awk is not allowed"),
    ("x=\"${y#$(open -g z)}\"", "open"),
    ("x=$(( $(open -g y) ))", "open"),
    ("x=\"${y#`open -g z`}\"", "open"),
    ("trap 'open -g x' EXIT", "open"),
    ('trap "eval $cmd" INT', "eval"),
    ("/bin/zsh -i -f build.sh", "zsh -i"),
    ("/bin/zsh -ic 'open -g x'", "zsh -c"),
    ("printf '%s\\n' 'BEGIN{system(\"id\")}' | awk", "awk program from stdin"),
    ("\"$app/Contents/MacOS/Fixture\" --x &", "variable command"),
    ("\"$bin/Contents/MacOS/ShortcupDev\" --selftest x &", "variable command"),
    ("source other.sh", "source"),
    (". ./other.sh", " . is not allowed"),
    ("perl -e 'system(\"open\")'", "perl"),
    ("ruby -e 'system(\"open\")'", "ruby"),
    ("exec \"$bin\"", "exec"),
    ("nohup open -g x", "nohup"),
    ("xargs open", "xargs"),
    ("/bin/zsh -c 'open -g x'", "zsh -c"),
    ("python3 <<< 'import os; os.system(\"open x\")'", "here-string"),
    ("python3 <<'PY'\nimport os\nos.system('open x')\nPY\n", "python3"),
    ("cat <<'EOF' | /bin/zsh\nContents/MacOS/ShortcupDev\nEOF\n", "not allow-listed"),
    ("env FOO=1 /usr/bin/open -g x", "env"),
    ("command open -g x", "command"),
    ("launchctl kickstart gui/501/x", "launchctl"),
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
    "trap '/bin/rm -rf \"$work\"' EXIT\n",
    "if [[ \"$live\" == 1 ]]; then\n  /bin/zsh -f \"$ROOT/scripts/verify-live.sh\" \"$@\"\nfi\n",
    "# if [[ \"$live\" == 1 ]]; then\nprint -- ok\n# fi\n",
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

VERIFY_ELSE = """#!/bin/zsh
live=0
if [[ "$live" == 1 ]]; then
  print -- "then branch"
else
  /bin/zsh -f "$ROOT/scripts/verify-live.sh" "$@"
fi
"""

VERIFY_COMMENT_IF = """#!/bin/zsh
live=0
# if this comment contains if [[ "$live" == 1 ]]; then it must not raise depth
if [[ "$live" == 1 ]]; then
  /bin/zsh -f "$ROOT/scripts/verify-live.sh" "$@"
fi
"""


def main():
    failures = []
    for script, expect in BYPASS:
        found = "\n".join(guard.scan_file_text(script))
        if expect not in found:
            failures.append(f"expected {expect!r} for {script!r}, got {found!r}")
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
    else_branch = guard.live_script_only_in_branch(VERIFY_ELSE)
    if "verify.sh names the live script outside the live == 1 branch" not in else_branch:
        failures.append("else-branch live-script was not reported: " + str(else_branch))
    comment_if = guard.live_script_only_in_branch(VERIFY_COMMENT_IF)
    if comment_if:
        failures.append("comment if raised live-branch depth: " + str(comment_if))
    if failures:
        print("\n".join(failures))
        return 1
    print(f"PASS: launch guard cases ({len(BYPASS) + len(ACCEPTED) + 5})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
