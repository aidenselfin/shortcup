#!/bin/zsh
# Live-only Shortcup steps: launch, clicks, and process stop.
# verify.sh calls this only when --live is passed. Do not run it from SAFE CI.
set -euo pipefail
cd "${0:A:h:h}"

PYTHON=/usr/bin/python3

live=0
launch_method=open
if [[ "${SHORTCUP_LAUNCH:-}" == "direct" ]]; then
  launch_method=direct
fi
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    --direct-launch) launch_method=direct ;;
    *) print -- "unknown argument: $arg"; exit 2 ;;
  esac
done
if [[ "$live" != 1 ]]; then
  print -- "verify-live.sh is live-only. Pass --live from verify.sh."
  exit 2
fi

DEV_APP="$PWD/build/Shortcup Dev.app"
INSTALLED="${HOME}/Applications/Shortcup Dev.app"
CANARY_FILE="${HOME}/.config/shortcup/verify-canary"
OUT="build/verify/selftest.json"
CONTROL="build/verify/control"
STRUCT_OUT="build/verify/fixture-structure.json"
STRUCT_CONTROL="build/verify/fixture-control"
FIXTURE="build/Shortcup Fixture.app"
RECORD="build/verify/launched.jsonl"
ROOT="$PWD"
fail=0
sign_ok="${SHORTCUP_SIGN_OK:-0}"
stop_remaining=0

note() { print -- "$1"; }

record_pid() {
  local pid="$1"
  [[ "$pid" == <-> ]] || return 0
  "$PYTHON" scripts/stop-launched.py record "$RECORD" "$pid" >/dev/null || true
}

stop_launched() {
  stop_remaining=0
  [[ -f "$RECORD" ]] || return 0
  local out
  out="$("$PYTHON" scripts/stop-launched.py stop "$RECORD" 2>&1 || true)"
  print -r -- "$out"
  stop_remaining="$(print -r -- "$out" | /usr/bin/awk -F= '/^remaining=/ { print $2 }')"
  [[ "$stop_remaining" == <-> ]] || stop_remaining=1
  return 0
}

cleanup() {
  [[ -n "${CONTROL:-}" ]] && /bin/mkdir -p "$CONTROL" && : > "$CONTROL/quit"
  [[ -n "${STRUCT_CONTROL:-}" ]] && /bin/mkdir -p "$STRUCT_CONTROL" && : > "$STRUCT_CONTROL/quit"
  stop_launched
  if [[ "$stop_remaining" != 0 ]]; then
    print -- "FAIL: $stop_remaining launched process(es) still running after SIGKILL"
  fi
  return 0
}
trap cleanup EXIT INT TERM

note ""
note "WARNING: --live will start Shortcup Fixture and Shortcup Dev windows on this screen and send synthetic clicks."
note "The fixture is an accessory app. Its windows are small, sit in the bottom-right corner, and cannot become key."
note "Launch method: $launch_method. The development Mac default uses LaunchServices with -g. CI uses --direct-launch or SHORTCUP_LAUNCH=direct."
note ""
note "WARNING: starting Shortcup Fixture and Shortcup Dev now. Windows will appear in the bottom-right corner."
note "LAYER 3 live fixture"
note "Launch method: $launch_method"
if [[ "$sign_ok" != 1 ]]; then
  note "FAIL: signing did not succeed, so the dev app was not launched"
  fail=$((fail + 1))
  exit "$fail"
fi

launch_app="$DEV_APP"
if [[ "$launch_method" == "open" ]]; then
  src="$DEV_APP/Contents/MacOS/ShortcupDev"
  dst="$INSTALLED/Contents/MacOS/ShortcupDev"
  if [[ ! -f "$dst" ]] || ! /usr/bin/cmp -s "$src" "$dst"; then
    already="$("$PYTHON" scripts/stop-launched.py find "$dst" || true)"
    if [[ -n "$already" ]]; then
      note "FAIL: installed Shortcup Dev is running and the binary differs. This script will not quit it."
      fail=$((fail + 1))
      exit "$fail"
    fi
    /bin/mkdir -p "${HOME}/Applications"
    /usr/bin/ditto "$DEV_APP" "$INSTALLED"
  fi
  launch_app="$INSTALLED"
fi

fixture_exe="$ROOT/$FIXTURE/Contents/MacOS/Fixture"
dev_exe="$launch_app/Contents/MacOS/ShortcupDev"
already="$("$PYTHON" scripts/stop-launched.py find "$dev_exe" "$fixture_exe" || true)"
if [[ -n "$already" ]]; then
  note "FAIL: Shortcup Dev or the fixture is already running from the paths this run would launch. Nothing was started."
  fail=$((fail + 1))
  exit "$fail"
fi

/bin/mkdir -p "$CONTROL" "$STRUCT_CONTROL" "${HOME}/.config/shortcup" build/verify
: > "$RECORD"
canary="SCX-$(/usr/bin/openssl rand -hex 4)"
umask 077
print -n -- "$canary" > "$CANARY_FILE"
/bin/chmod 600 "$CANARY_FILE"
/bin/rm -f "$STRUCT_OUT" "$OUT" "$CONTROL/quit" "$STRUCT_CONTROL/quit" "$CONTROL/shortcup.pid" "$CONTROL/fixture.pid" "$STRUCT_CONTROL/fixture.pid"

if [[ "$launch_method" == "direct" ]]; then
  "$PYTHON" scripts/stop-launched.py spawn "$RECORD" -- "$ROOT/$FIXTURE/Contents/MacOS/Fixture" --control "$PWD/$STRUCT_CONTROL" --dump-structure "$PWD/$STRUCT_OUT" &
else
  "$PYTHON" scripts/stop-launched.py spawn "$RECORD" -- /usr/bin/open -g -n -W "$FIXTURE" --args --control "$PWD/$STRUCT_CONTROL" --dump-structure "$PWD/$STRUCT_OUT" &
fi
struct_opener="$!"
for _ in {1..75}; do
  [[ -f "$STRUCT_CONTROL/fixture.pid" ]] && record_pid "$(tr -dc '0-9' < "$STRUCT_CONTROL/fixture.pid" || true)"
  [[ -f "$STRUCT_OUT" ]] && break
  kill -0 "$struct_opener" 2>/dev/null || break
  /bin/sleep 0.2
done
: > "$STRUCT_CONTROL/quit"
for _wait in {1..10}; do
  kill -0 "$struct_opener" 2>/dev/null || break
  /bin/sleep 0.2
done
stop_launched
wait "$struct_opener" 2>/dev/null || true
if [[ "$stop_remaining" != 0 ]]; then
  note "FAIL: $stop_remaining fixture process(es) survived SIGKILL after the structure dump"
  fail=$((fail + 1))
  exit "$fail"
fi
if [[ -f "$STRUCT_OUT" ]] && "$PYTHON" scripts/check-fixture-structure.py "$STRUCT_OUT" > build/verify/fixture-structure.txt 2>&1; then
  note "PASS: fixture own-tree has the standard window, panel, and menu identifiers"
  while IFS= read -r line; do note "  $line"; done < build/verify/fixture-structure.txt
else
  note "FAIL: fixture own-tree did not match the expected window and menu structure"
  fail=$((fail + 1))
fi

if [[ "$launch_method" == "direct" ]]; then
  "$PYTHON" scripts/stop-launched.py spawn "$RECORD" -- "$launch_app/Contents/MacOS/ShortcupDev" --selftest "$PWD/$OUT" --fixture "$PWD/$FIXTURE" --control "$PWD/$CONTROL" --canary-file "$CANARY_FILE" --launch-method direct &
else
  "$PYTHON" scripts/stop-launched.py spawn "$RECORD" -- /usr/bin/open -g -n -W "$launch_app" --args --selftest "$PWD/$OUT" --fixture "$PWD/$FIXTURE" --control "$PWD/$CONTROL" --canary-file "$CANARY_FILE" --launch-method open &
fi
opener="$!"
lsof_samples=0
lsof_connections=0
pid=""
for _ in {1..375}; do
  if [[ -f "$CONTROL/shortcup.pid" ]]; then
    pid="$(tr -dc '0-9' < "$CONTROL/shortcup.pid" || true)"
    record_pid "$pid"
  fi
  if [[ -f "$CONTROL/fixture.pid" ]]; then
    record_pid "$(tr -dc '0-9' < "$CONTROL/fixture.pid" || true)"
  fi
  if [[ "$lsof_samples" -lt 2 && -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    if /usr/sbin/lsof -nP -a -i -p "$pid" > "build/verify/lsof-$((lsof_samples + 1)).txt" 2>/dev/null; then
      lsof_connections=$((lsof_connections + 1))
    fi
    lsof_samples=$((lsof_samples + 1))
    if [[ "$lsof_samples" -lt 2 ]]; then
      /bin/sleep 0.4
      if kill -0 "$pid" 2>/dev/null; then
        if /usr/sbin/lsof -nP -a -i -p "$pid" > "build/verify/lsof-$((lsof_samples + 1)).txt" 2>/dev/null; then
          lsof_connections=$((lsof_connections + 1))
        fi
        lsof_samples=$((lsof_samples + 1))
      fi
    fi
  fi
  kill -0 "$opener" 2>/dev/null || break
  /bin/sleep 0.2
done
if kill -0 "$opener" 2>/dev/null; then
  note "FAIL: selftest did not finish within 75s"
  fail=$((fail + 1))
  : > "$CONTROL/quit"
  : > "$STRUCT_CONTROL/quit"
  for _wait in {1..10}; do
    kill -0 "$opener" 2>/dev/null || break
    /bin/sleep 0.2
  done
fi
stop_launched
wait "$opener" 2>/dev/null || true
if [[ "$stop_remaining" != 0 ]]; then
  note "FAIL: $stop_remaining launched process(es) survived SIGKILL"
  fail=$((fail + 1))
else
  note "PASS: no launched dev app or fixture process remains"
fi
if [[ "$lsof_connections" -gt 0 ]]; then
  note "CRITICAL: ShortcupDev has a network connection"
  fail=$((fail + 1))
elif [[ "$lsof_samples" -ge 2 ]]; then
  note "PASS: lsof shows no connections for ShortcupDev across $lsof_samples samples"
else
  note "FAIL: could not sample lsof twice against the dev app"
  fail=$((fail + 1))
fi
if [[ -f "$OUT" ]]; then
  schema_status=0
  if "$PYTHON" scripts/check-selftest-json.py "$OUT" > build/verify/selftest-schema.txt 2>&1; then
    schema_status=0
  else
    schema_status=$?
  fi
  while IFS= read -r line; do note "  $line"; done < build/verify/selftest-schema.txt
  if [[ "$schema_status" != 0 ]]; then
    note "CRITICAL: selftest JSON failed the allow-list schema"
    fail=$((fail + 1))
  else
    result="$(/usr/bin/awk -F= '/^result=/ { print $2; exit }' build/verify/selftest-schema.txt)"
    if [[ "$result" == "skipped" ]]; then
      note "SKIPPED: needs Accessibility for the dev app. axTrusted is in the result JSON."
    elif [[ "$result" == "pass" ]]; then
      note "PASS: fixture clicks matched the expected hints"
    else
      note "FAIL: fixture selftest reported fail"
      fail=$((fail + 1))
    fi
  fi
else
  note "FAIL: selftest wrote no result file"
  fail=$((fail + 1))
fi

exit "$fail"
