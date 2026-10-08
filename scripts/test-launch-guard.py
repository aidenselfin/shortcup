#!/usr/bin/env python3
"""Cases for check-launch-guard.py. Nothing is executed."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("guard", Path(__file__).with_name("check-launch-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

LIVE_OK = '# LIVE-ONLY-START\nopen -g -n -W y &\n"$app/Contents/MacOS/Fixture" --x &\n# LIVE-ONLY-END\n'

# Each line must be rejected outside the live section.
REJECTED = [
    'open -g -n "$APP"',
    '/usr/bin/open -g x',
    'cmp -s a b && open x',
    'env FOO=1 open -g x',
    'command open -g x',
    'x="$(open -g y)"',
    'x=`open -g y`',
    'if open -g a; then :; fi',
    '"$FIXTURE/Contents/MacOS/Fixture" --maps --dump-awk &',
    '"build/Shortcup Fixture.app/Contents/MacOS/Fixture" --cmp',
    '"$bin" --selftest out &',
    '$runner --x',
    '"$launch_app/Contents/MacOS/ShortcupDev" --selftest x &',
    'eval "$cmd"',
    'osascript -e "tell application \\"Finder\\" to activate"',
    'source other.sh',
    '. ./other.sh',
    'zsh other.sh',
    'bash -c "open -g x"',
    'python3 scripts/unknown.py',
    'python3 scripts/stop-launched.py spawn rec -- open -g x',
    'xargs open < list',
    'diff <(open -g x) y',
    'launchctl kickstart gui/501/x',
    'cat > x <<\'PY\'\nimport subprocess\nsubprocess.run(["open", "x"])\nPY',
]

# Each script must pass without problems.
ACCEPTED = [
    'codesign -d -r- "$APP/Contents/MacOS/ShortcupDev"',
    'vtool -show-build "$DEV_APP/Contents/MacOS/ShortcupDev" | awk \'/minos/ { print $2 }\'',
    'nm build/product-link/Shortcup | grep -q ForTesting',
    'ps -ax -o command= | grep -F "$DEV_APP/Contents/MacOS/ShortcupDev"',
    'note() { print -r -- "$1"; }\nnote "WARNING: opening Shortcup Fixture now"',
    'print -- "open the app later"',
    'local opener="$!"',
    'pid="$(tr -dc 0-9 < "$CONTROL/shortcup.pid")"',
    '# open -g "$APP" in a comment',
    'mkdir -p "$CONTROL"  # then open -g "$APP"',
    'fail=$((fail + 1))',
    'if (( count > 1 )); then :; fi',
    'while (( i < 3 )); do (( i++ )); done',
    'roots=("$build" "$tmp")\nroots+=(\n  "$a"\n  "$b"\n)',
    'local -a found=("${(@f)$(grep -l x y)}")',
    'case "$1" in\n  --live) LIVE=1 ;;\n  open|*) print "$1" ;;\nesac',
    '[[ -f "$x" && ( -n "$y" || -z "$z" ) ]] && print ok',
    'for d in ~/Library/Logs/Shortcup*(N); do print -r -- "$d"; done',
    'while read -r line; do print -r -- "$line"; done < <(grep -v x y 2>&1)',
    'cat > x <<\'EOF\'\nopen -g inside heredoc\neval nope\nEOF\nprint done',
    'print -r -- "$x" >&2 2>/dev/null',
    'python3 - "$out" <<\'PY\'\nimport json\nPY',
    'python3 -c \'import json,sys; print(json.load(open(sys.argv[1]))["result"])\' "$OUT"',
    'zsh build.sh --checks-only',
    '{ print a; print b; } > out',
    '(cd build && ditto a b)',
    LIVE_OK,
    '# LIVE-ONLY-START\npython3 scripts/stop-launched.py spawn rec -- open -g -n -W y &\n'
    'python3 scripts/stop-launched.py spawn rec -- "$app/Contents/MacOS/ShortcupDev" --x &\n# LIVE-ONLY-END\n',
]


def main():
    failures = []
    for script in REJECTED:
        problems, _, _, _ = guard.check_text(script)
        if not problems:
            failures.append(f"expected a problem for {script!r}")
    for script in ACCEPTED:
        problems, _, _, _ = guard.check_text(script)
        if problems:
            failures.append(f"expected no problem for {script!r}, got {problems}")
    outside = 'open -g x\n' + LIVE_OK
    problems = guard.check_verify(outside)
    if problems != ["verify.sh:1 open launch outside --live"]:
        failures.append(f"live section handling: {problems}")
    missing_g = '# LIVE-ONLY-START\nopen -n y\n"$exe/Contents/MacOS/Fixture"\n# LIVE-ONLY-END\n'
    if "verify.sh:2 open is missing -g" not in guard.check_verify(missing_g):
        failures.append("open without -g inside live was not reported")
    live_variable = '# LIVE-ONLY-START\n"$exe" --a\n# LIVE-ONLY-END\n'
    if not guard.check_text(live_variable)[0]:
        failures.append("bare variable command inside live was not reported")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"PASS: launch guard cases ({len(REJECTED) + len(ACCEPTED) + 3})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
