#!/bin/zsh
# Safe Shortcup checks. This script does not launch an app unless you pass --live.
# --live opens windows on the screen and sends synthetic clicks. Leave it off.
# Default launch is `open -g` (the development Mac). CI passes --direct-launch
# or SHORTCUP_LAUNCH=direct so bash, not LaunchServices, starts the executable.
set -euo pipefail
cd "${0:A:h}"

live=0
launch_method=open
if [[ "${SHORTCUP_LAUNCH:-open}" == "direct" ]]; then
  launch_method=direct
fi
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    --direct-launch) launch_method=direct ;;
    *) print -- "unknown argument: $arg"; exit 2 ;;
  esac
done

DEV_APP="$PWD/build/Shortcup Dev.app"
INSTALLED="${HOME}/Applications/Shortcup Dev.app"
KEYCHAIN="${HOME}/Library/Keychains/shortcup-dev.keychain-db"
PW_FILE="${HOME}/.config/shortcup/keychain-password"
CANARY_FILE="${HOME}/.config/shortcup/verify-canary"
OUT="build/verify/selftest.json"
CONTROL="build/verify/control"
STRUCT_OUT="build/verify/fixture-structure.json"
STRUCT_CONTROL="build/verify/fixture-control"
FIXTURE="build/Shortcup Fixture.app"
SUMMARY="build/verify/summary.txt"
ROOT="$PWD"
fail=0
known=0
sign_ok=0
lines=()
typeset -a recorded_pids
typeset -A recorded_seen
typeset -a launched_paths
start=$SECONDS
note() { lines+=("$1"); print -- "$1"; }
# Output and logs show ~ and . instead of real absolute paths.
show() {
  local p="$1"
  [[ -n "${TMPDIR:-}" && "$p" == "${TMPDIR%/}"* ]] && p='$TMPDIR'"${p#${TMPDIR%/}}"
  [[ "$p" == "$ROOT"* ]] && p=".${p#$ROOT}"
  [[ "$p" == "$HOME"* ]] && p="~${p#$HOME}"
  print -r -- "$p"
}

record_pid() {
  local pid="$1"
  [[ "$pid" == <-> ]] || return 0
  [[ -n "${recorded_seen[$pid]:-}" ]] && return 0
  recorded_seen[$pid]=1
  recorded_pids+=("$pid")
}

# Stops what this --live run started: processes whose executable is exactly one
# of launched_paths, plus recorded pids whose executable is still ours or open.
# SIGTERM, confirm, then SIGKILL. Sets stop_remaining.
stop_remaining=0
stop_launched() {
  stop_remaining=0
  (( ${#launched_paths[@]} )) || return 0
  local -a args
  local pid out
  for pid in "${recorded_pids[@]}"; do args+=(--recorded "$pid"); done
  args+=(--opener /usr/bin/open)
  out="$(python3 scripts/stop-launched.py stop "${args[@]}" "${launched_paths[@]}" 2>&1 || true)"
  stop_remaining="$(print -r -- "$out" | awk -F= '/^remaining=/ { print $2 }')"
  [[ "$stop_remaining" == <-> ]] || stop_remaining=1
  return 0
}

# SAFE mode returns immediately and kills nothing.
cleanup() {
  [[ "${live:-0}" == 1 ]] || return 0
  [[ -n "${CONTROL:-}" ]] && mkdir -p "$CONTROL" && : > "$CONTROL/quit"
  [[ -n "${STRUCT_CONTROL:-}" ]] && mkdir -p "$STRUCT_CONTROL" && : > "$STRUCT_CONTROL/quit"
  stop_launched
  if [[ "$stop_remaining" != 0 ]]; then
    print -- "FAIL: $stop_remaining launched process(es) still running after SIGKILL"
  fi
  return 0
}
trap cleanup EXIT INT TERM

mkdir -p build/verify
rm -f "$SUMMARY"

note "Shortcup verify"
if [[ "$live" == 1 ]]; then
  note "WARNING: --live will open Shortcup Fixture and Shortcup Dev windows on this screen and send synthetic clicks."
  note "The fixture is an accessory app. Its windows are small, sit in the bottom-right corner, and cannot become key."
  note "Launch method: $launch_method. The default is open -g. CI uses --direct-launch or SHORTCUP_LAUNCH=direct."
else
  note "SAFE MODE: no app will be launched and no click or key will be sent."
  if [[ "$launch_method" == "direct" ]]; then
    note "NOTE: direct launch is selected, but without --live nothing is started."
  fi
fi
note ""

# --- secrets and static checks (no Accessibility, no launch) ---
tracked=""
if tracked="$(git ls-files)"; then
  if print -r -- "$tracked" | grep -E '\.(p12|pem|key)$|keychain-password|dev-key' >/dev/null; then
    note "CRITICAL: a private key or password file is tracked in git"
    fail=$((fail + 1))
  else
    note "PASS: no signing key or password is tracked"
  fi
else
  note "CRITICAL: git ls-files failed, so the secret check cannot pass"
  fail=$((fail + 1))
fi

if grep -R -E 'URLSession|import Network|NWConnection|NSURLConnection' Sources Fixture >/dev/null; then
  note "CRITICAL: network API referenced in Sources or Fixture"
  fail=$((fail + 1))
else
  note "PASS: no URLSession or Network framework usage"
fi

if grep -E 'keyDown|keyUp|flagsChanged' Sources/App.swift Sources/Detect.swift Sources/SelfTest.swift >/dev/null; then
  note "CRITICAL: key event monitor found in the listener sources"
  fail=$((fail + 1))
else
  note "PASS: listener sources have no keyDown, keyUp, or flagsChanged"
fi
if grep -n 'tapCreate' -A 2 Sources/App.swift | grep -q 'listenOnly'; then
  note "PASS: event tap is listenOnly for mouse down, up, and drag"
else
  note "CRITICAL: event tap is missing or not listenOnly"
  fail=$((fail + 1))
fi
if grep -n 'AXUIElementSetAttributeValue' Sources/App.swift Sources/Detect.swift Sources/SelfTest.swift Sources/Shortcuts.swift >/dev/null; then
  note "CRITICAL: AXUIElementSetAttributeValue is in the product or selftest path"
  fail=$((fail + 1))
fi
if grep -n 'AXUIElementSetAttributeValue' Sources/Validation.swift >/dev/null; then
  note "KNOWN-FAIL: legacy --validate-once still sets an address-field value. verify.sh does not run it. Expected until a later cleanup."
  known=$((known + 1))
fi
if grep -n 'hint.title' Sources/App.swift >/dev/null; then
  note "KNOWN-FAIL: menu and toolbar validation logs still store command titles (validation-events.jsonl). Expected until the v0.1 fix."
  known=$((known + 1))
fi
if python3 scripts/test-launch-guard.py > build/verify/launch-guard-test.txt 2>&1; then
  note "$(cat build/verify/launch-guard-test.txt)"
else
  note "FAIL: launch guard cases"
  while IFS= read -r line; do note "  $line"; done < build/verify/launch-guard-test.txt
  fail=$((fail + 1))
fi
# Command-line stubs under build/stop-test only. No app is started.
if python3 scripts/test-stop-launched.py > build/verify/stop-test.txt 2>&1; then
  note "$(tail -n 1 build/verify/stop-test.txt)"
else
  note "FAIL: hung-run stop helper"
  tail -n 20 build/verify/stop-test.txt | while IFS= read -r line; do note "  $line"; done
  fail=$((fail + 1))
fi
if python3 scripts/check-launch-guard.py > build/verify/launch-guard.txt 2>&1; then
  note "PASS: app launch is only inside the --live section, and both open -g and a direct executable launch are present there"
else
  note "CRITICAL: verify.sh can launch an app without --live, or a launch method is missing"
  if [[ -s build/verify/launch-guard.txt ]]; then
    while IFS= read -r line; do note "  $line"; done < build/verify/launch-guard.txt
  fi
  fail=$((fail + 1))
fi

note ""
note "LAYER 2 snapshots"
if zsh build.sh --checks-only > build/verify/checks.log 2>&1; then
  note "PASS: snapshot replay, glyph table, locale, cache, and AX allow-list"
else
  note "FAIL: permission-free checks"
  if [[ -s build/verify/checks.log ]]; then
    tail -n 40 build/verify/checks.log | while IFS= read -r line; do note "  $line"; done
  fi
  fail=$((fail + 1))
fi

mkdir -p build/product-link
if swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Sources/Detect.swift Sources/App.swift Sources/Validation.swift \
    -o build/product-link/Shortcup -framework AppKit -framework ApplicationServices -framework Carbon \
    > build/verify/product-link.log 2>&1; then
  if grep -q 'will never be executed' build/verify/product-link.log; then
    note "FAIL: product build still has a dead self-test branch"
    fail=$((fail + 1))
  elif strings -a build/product-link/Shortcup | grep -q 'com.shortcup.fixture'; then
    note "CRITICAL: product binary contains the fixture selftest"
    fail=$((fail + 1))
  elif nm build/product-link/Shortcup | grep -q 'ForTesting'; then
    note "FAIL: product binary exposes a ForTesting hook"
    fail=$((fail + 1))
  else
    note "PASS: product build has no fixture selftest and no dead self-test branch"
  fi
  repo_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist 2>/dev/null || true)"
  bin_min="$(vtool -show-build build/product-link/Shortcup 2>/dev/null | awk '/minos/ { print $2; exit }' || true)"
  if [[ -n "$repo_min" && "$repo_min" == "$bin_min" ]]; then
    note "PASS: repo LSMinimumSystemVersion $repo_min matches the product-link binary"
  else
    note "FAIL: repo LSMinimumSystemVersion plist=$repo_min binary=$bin_min"
    fail=$((fail + 1))
  fi
else
  note "FAIL: product sources did not compile"
  fail=$((fail + 1))
fi

note ""
note "JSON schema allow-list"
schema_dir="build/verify/schema"
mkdir -p "$schema_dir"
print -r -- '{"cases":[],"result":"skipped","trusted":false,"axTrusted":false,"launchMethod":"open"}' > "$schema_dir/skipped.json"
print -r -- '{"cases":[],"result":"skipped","trusted":false,"axTrusted":false,"launchMethod":"direct"}' > "$schema_dir/skipped-direct.json"
print -r -- '{"trusted":true,"axTrusted":true,"launchMethod":"open","result":"pass","cases":[{"subrole":"AXCloseButton","identifier":"","shortcut":"","result":"pass"}],"titleFallbackReads":1,"hangSeconds":0.01,"menuWalksAfterFirst":1,"menuWalksAfterSecond":1,"idleAxReads":0,"canaryLeak":false,"axAllowListOK":true,"disallowed":[]}' > "$schema_dir/pass.json"
print -r -- '{"trusted":true,"axTrusted":true,"launchMethod":"direct","result":"fail","cases":[{"subrole":"AXCloseButton","identifier":"","shortcut":"","result":"skip"}],"titleFallbackReads":1,"hangSeconds":0.01,"menuWalksAfterFirst":1,"menuWalksAfterSecond":1,"idleAxReads":0,"canaryLeak":false,"axAllowListOK":true,"disallowed":[]}' > "$schema_dir/skip-case.json"
print -r -- '{"cases":[],"result":"skipped","trusted":false,"axTrusted":false,"launchMethod":"open","title":"should-not-be-here"}' > "$schema_dir/extra.json"
print -r -- '{"trusted":true,"axTrusted":true,"launchMethod":"open","result":"pass","cases":[{"subrole":"AXCloseButton","identifier":"","shortcut":"","result":"pass"}],"titleFallbackReads":true,"hangSeconds":0.01,"menuWalksAfterFirst":1,"menuWalksAfterSecond":1,"idleAxReads":0,"canaryLeak":false,"axAllowListOK":true,"disallowed":[]}' > "$schema_dir/bool-int.json"
print -r -- '{"trusted":true,"axTrusted":true,"launchMethod":"open","result":"pass","cases":[{"subrole":"AXCloseButton","identifier":"","shortcut":"","result":"pass","extra":"no"}],"titleFallbackReads":1,"hangSeconds":0.01,"menuWalksAfterFirst":1,"menuWalksAfterSecond":1,"idleAxReads":0,"canaryLeak":false,"axAllowListOK":true,"disallowed":[]}' > "$schema_dir/nested.json"
print -r -- '{"cases":[],"result":"skipped","trusted":false,"axTrusted":false,"launchMethod":"fork"}' > "$schema_dir/bad-launch.json"
print -r -- '{"cases":[],"result":"skipped","trusted":false,"axTrusted":true,"launchMethod":"open"}' > "$schema_dir/mismatch.json"
if python3 scripts/check-selftest-json.py "$schema_dir/skipped.json" > build/verify/schema-ok.txt \
  && python3 scripts/check-selftest-json.py "$schema_dir/skipped-direct.json" >> build/verify/schema-ok.txt \
  && python3 scripts/check-selftest-json.py "$schema_dir/pass.json" >> build/verify/schema-ok.txt \
  && python3 scripts/check-selftest-json.py "$schema_dir/skip-case.json" >> build/verify/schema-ok.txt \
  && ! python3 scripts/check-selftest-json.py "$schema_dir/extra.json" >/dev/null 2>&1 \
  && ! python3 scripts/check-selftest-json.py "$schema_dir/bool-int.json" >/dev/null 2>&1 \
  && ! python3 scripts/check-selftest-json.py "$schema_dir/nested.json" >/dev/null 2>&1 \
  && ! python3 scripts/check-selftest-json.py "$schema_dir/bad-launch.json" >/dev/null 2>&1 \
  && ! python3 scripts/check-selftest-json.py "$schema_dir/mismatch.json" >/dev/null 2>&1; then
  note "PASS: selftest JSON allow-list accepts axTrusted and launchMethod, rejects extra keys, bools-as-ints, and nested extras"
else
  note "FAIL: selftest JSON allow-list"
  fail=$((fail + 1))
fi

note ""
note "LAYER 1 signing"
if zsh setup-dev-signing.sh > build/verify/signing-setup.log 2>&1; then
  if zsh build.sh --dev > build/verify/dev-build.log 2>&1; then
    if ps -ax -o command= | grep -F "$DEV_APP/Contents/MacOS/ShortcupDev" | grep -v grep >/dev/null; then
      note "FAIL: Shortcup Dev build is already running. This script will not quit it or sign over it."
      fail=$((fail + 1))
    elif python3 scripts/keychain.py unlock "$KEYCHAIN" "$PW_FILE" \
      && codesign --force --sign "Shortcup Dev" --keychain "$KEYCHAIN" --identifier com.shortcup.dev "$DEV_APP" \
        > build/verify/codesign-sign.log 2>&1; then
      if ! python3 scripts/keychain.py lock "$KEYCHAIN"; then
        note "FAIL: dev keychain did not lock"
        fail=$((fail + 1))
      fi
      requirement="$(codesign -d -r- "$DEV_APP" 2>&1 || true)"
      print -- "$requirement" > build/verify/codesign.txt
      if print -- "$requirement" | grep -q 'certificate leaf'; then
        note "PASS: designated requirement has a certificate leaf (signed in build/, not copied to ~/Applications)"
        note "$(print -r -- "$requirement" | grep '^designated' || true)"
        sign_ok=1
      else
        note "FAIL: designated requirement has no certificate leaf"
        fail=$((fail + 1))
      fi
      dev_plist="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$DEV_APP/Contents/Info.plist" 2>/dev/null || true)"
      dev_bin="$(vtool -show-build "$DEV_APP/Contents/MacOS/ShortcupDev" 2>/dev/null | awk '/minos/ { print $2; exit }' || true)"
      dev_ui="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$DEV_APP/Contents/Info.plist" 2>/dev/null || true)"
      if [[ "$dev_plist" == "$dev_bin" && -n "$dev_bin" && "$dev_ui" == "true" ]]; then
        note "PASS: dev LSMinimumSystemVersion $dev_plist matches the binary and LSUIElement is true"
      else
        note "FAIL: dev plist plist=$dev_plist binary=$dev_bin LSUIElement=$dev_ui"
        fail=$((fail + 1))
      fi
    else
      python3 scripts/keychain.py lock "$KEYCHAIN" || true
      note "FAIL: codesign failed. See build/verify/codesign-sign.log"
      fail=$((fail + 1))
    fi
  else
    note "FAIL: dev build failed"
    fail=$((fail + 1))
  fi
else
  note "FAIL: signing identity was not created"
  fail=$((fail + 1))
fi

note ""
note "fixture compile"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE/Contents/MacOS"
if swiftc -module-cache-path build/module-cache Fixture/main.swift -o "$FIXTURE/Contents/MacOS/Fixture" -framework AppKit; then
  cat > "$FIXTURE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleIdentifier</key><string>com.shortcup.fixture</string>
<key>CFBundleName</key><string>Shortcup Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
  if codesign --force --sign - --identifier com.shortcup.fixture "$FIXTURE" > build/verify/fixture-codesign.log 2>&1; then
    note "PASS: fixture app compiled and signed, not launched"
  else
    note "FAIL: fixture codesign failed"
    fail=$((fail + 1))
  fi
else
  note "FAIL: fixture app did not build"
  fail=$((fail + 1))
fi

# LIVE-ONLY-START
run_live() {
  note ""
  note "WARNING: opening Shortcup Fixture and Shortcup Dev now. Windows will appear in the bottom-right corner."
  note "LAYER 3 live fixture"
  note "Launch method: $launch_method"
  if [[ "$sign_ok" != 1 ]]; then
    note "FAIL: signing did not succeed, so the dev app was not launched"
    fail=$((fail + 1))
    return
  fi
  local launch_app="$DEV_APP"
  if [[ "$launch_method" == "open" ]]; then
    local src="$DEV_APP/Contents/MacOS/ShortcupDev"
    local dst="$INSTALLED/Contents/MacOS/ShortcupDev"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      if ps -ax -o command= | grep -F "$dst" | grep -v grep >/dev/null; then
        note "FAIL: installed Shortcup Dev is running and the binary differs. This script will not quit it."
        fail=$((fail + 1))
        return
      fi
      mkdir -p "${HOME}/Applications"
      ditto "$DEV_APP" "$INSTALLED"
    fi
    launch_app="$INSTALLED"
  fi
  local fixture_exe="$ROOT/$FIXTURE/Contents/MacOS/Fixture"
  local dev_exe="$launch_app/Contents/MacOS/ShortcupDev"
  local already
  already="$(python3 scripts/stop-launched.py find "$dev_exe" "$fixture_exe" || true)"
  if [[ -n "$already" ]]; then
    note "FAIL: Shortcup Dev or the fixture is already running from the paths this run would launch. Nothing was started."
    fail=$((fail + 1))
    return
  fi
  launched_paths=("$dev_exe" "$fixture_exe")
  mkdir -p "$CONTROL" "$STRUCT_CONTROL" "${HOME}/.config/shortcup"
  local canary="SCX-$(openssl rand -hex 4)"
  umask 077
  print -n -- "$canary" > "$CANARY_FILE"
  chmod 600 "$CANARY_FILE"
  rm -f "$STRUCT_OUT" "$OUT" "$CONTROL/quit" "$STRUCT_CONTROL/quit" "$CONTROL/shortcup.pid" "$CONTROL/fixture.pid" "$STRUCT_CONTROL/fixture.pid"
  # Both commands exist. launch_method picks one. open always includes -g.
  if [[ "$launch_method" == "direct" ]]; then
    "$ROOT/$FIXTURE/Contents/MacOS/Fixture" --control "$PWD/$STRUCT_CONTROL" --dump-structure "$PWD/$STRUCT_OUT" &
    record_pid "$!"
  else
    open -g -n -W "$FIXTURE" --args --control "$PWD/$STRUCT_CONTROL" --dump-structure "$PWD/$STRUCT_OUT" &
    record_pid "$!"
  fi
  local struct_opener="$!"
  local _
  for _ in {1..75}; do
    [[ -f "$STRUCT_CONTROL/fixture.pid" ]] && record_pid "$(tr -dc '0-9' < "$STRUCT_CONTROL/fixture.pid" || true)"
    [[ -f "$STRUCT_OUT" ]] && break
    kill -0 "$struct_opener" 2>/dev/null || break
    sleep 0.2
  done
  : > "$STRUCT_CONTROL/quit"
  local _wait
  for _wait in {1..10}; do
    kill -0 "$struct_opener" 2>/dev/null || break
    sleep 0.2
  done
  stop_launched
  wait "$struct_opener" 2>/dev/null || true
  if [[ "$stop_remaining" != 0 ]]; then
    note "FAIL: $stop_remaining fixture process(es) survived SIGKILL after the structure dump"
    fail=$((fail + 1))
    return
  fi
  if [[ -f "$STRUCT_OUT" ]] && python3 scripts/check-fixture-structure.py "$STRUCT_OUT" > build/verify/fixture-structure.txt 2>&1; then
    note "PASS: fixture own-tree has the standard window, panel, and menu identifiers"
    while IFS= read -r line; do note "  $line"; done < build/verify/fixture-structure.txt
  else
    note "FAIL: fixture own-tree did not match the expected window and menu structure"
    fail=$((fail + 1))
  fi
  if [[ "$launch_method" == "direct" ]]; then
    "$launch_app/Contents/MacOS/ShortcupDev" --selftest "$PWD/$OUT" --fixture "$PWD/$FIXTURE" --control "$PWD/$CONTROL" --canary-file "$CANARY_FILE" --launch-method direct &
    record_pid "$!"
  else
    open -g -n -W "$launch_app" --args --selftest "$PWD/$OUT" --fixture "$PWD/$FIXTURE" --control "$PWD/$CONTROL" --canary-file "$CANARY_FILE" --launch-method open &
    record_pid "$!"
  fi
  local opener="$!"
  local lsof_samples=0
  local lsof_connections=0
  local pid=""
  for _ in {1..375}; do
    if [[ -f "$CONTROL/shortcup.pid" ]]; then
      pid="$(tr -dc '0-9' < "$CONTROL/shortcup.pid" || true)"
      record_pid "$pid"
    fi
    if [[ -f "$CONTROL/fixture.pid" ]]; then
      record_pid "$(tr -dc '0-9' < "$CONTROL/fixture.pid" || true)"
    fi
    if [[ "$lsof_samples" -lt 2 && -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      if lsof -nP -a -i -p "$pid" > "build/verify/lsof-$((lsof_samples + 1)).txt" 2>/dev/null; then
        lsof_connections=$((lsof_connections + 1))
      fi
      lsof_samples=$((lsof_samples + 1))
      if [[ "$lsof_samples" -lt 2 ]]; then
        sleep 0.4
        if kill -0 "$pid" 2>/dev/null; then
          if lsof -nP -a -i -p "$pid" > "build/verify/lsof-$((lsof_samples + 1)).txt" 2>/dev/null; then
            lsof_connections=$((lsof_connections + 1))
          fi
          lsof_samples=$((lsof_samples + 1))
        fi
      fi
    fi
    kill -0 "$opener" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$opener" 2>/dev/null; then
    note "FAIL: selftest did not finish within 75s"
    fail=$((fail + 1))
    : > "$CONTROL/quit"
    : > "$STRUCT_CONTROL/quit"
    for _wait in {1..10}; do
      kill -0 "$opener" 2>/dev/null || break
      sleep 0.2
    done
  fi
  # Runs on a hang and on a normal finish. Before the pid files exist, the
  # exact executable paths still find the dev app and the fixture.
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
    local schema_status=0
    if python3 scripts/check-selftest-json.py "$OUT" > build/verify/selftest-schema.txt 2>&1; then
      schema_status=0
    else
      schema_status=$?
    fi
    while IFS= read -r line; do note "  $line"; done < build/verify/selftest-schema.txt
    if [[ "$schema_status" != 0 ]]; then
      note "CRITICAL: selftest JSON failed the allow-list schema"
      fail=$((fail + 1))
    else
      local result
      result="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"])' "$OUT")"
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
}
# LIVE-ONLY-END

note ""
if [[ "$live" == 1 ]]; then
  run_live
else
  note "LAYER 3: SKIPPED. --live was not passed, so no window was opened and no synthetic click was sent."
fi

note ""
note "LAYER 4 privacy"
mkdir -p "${HOME}/.config/shortcup"
if [[ ! -f "$CANARY_FILE" ]]; then
  umask 077
  print -n -- "SCX-$(openssl rand -hex 4)" > "$CANARY_FILE"
  chmod 600 "$CANARY_FILE"
fi
canary_mode="$(stat -f '%Lp' "$CANARY_FILE")"
if [[ "$canary_mode" != "600" ]]; then
  note "CRITICAL: canary file mode is $canary_mode, expected 600"
  fail=$((fail + 1))
fi
pw_mode="$(stat -f '%Lp' "$PW_FILE" 2>/dev/null || true)"
if [[ "$pw_mode" != "600" ]]; then
  note "CRITICAL: keychain password file mode is ${pw_mode:-missing}, expected 600"
  fail=$((fail + 1))
fi
scan_file="$(mktemp)"
: > "$scan_file"
scan_failed=0
scan_blocked=0
# Only paths Shortcup itself can write. Other apps' containers, preferences,
# caches, and logs are never read: macOS can show an "access data from other
# apps" prompt for the terminal, and those files are not ours.
SHORTCUP_IDS=(com.shortcup.dev com.shortcup.fixture)
user_cache_dir="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
user_cache_dir="${user_cache_dir%/}"
allowed_scan_path() {
  local p="$1" id
  case "$p" in
    build|build/*|"$ROOT/build"|"$ROOT/build/"*) return 0 ;;
    "$INSTALLED"|"$INSTALLED/"*) return 0 ;;
  esac
  for id in "${SHORTCUP_IDS[@]}"; do
    case "$p" in
      "$HOME/Library/Containers/$id"|"$HOME/Library/Containers/$id/"*) return 0 ;;
      "$HOME/Library/Preferences/$id.plist") return 0 ;;
      "$HOME/Library/Caches/$id"|"$HOME/Library/Caches/$id/"*) return 0 ;;
      "$HOME/Library/Saved Application State/$id.savedState"|"$HOME/Library/Saved Application State/$id.savedState/"*) return 0 ;;
    esac
    if [[ -n "$user_cache_dir" ]]; then
      case "$p" in "$user_cache_dir/$id"|"$user_cache_dir/$id/"*) return 0 ;; esac
    fi
  done
  local base="${p:t:l}"
  if [[ "$base" == *shortcup* || "$base" == *fixture* ]]; then
    [[ -n "${TMPDIR:-}" && "${p:h}" == "${TMPDIR%/}" ]] && return 0
    [[ "${p:h}" == /tmp || "${p:h}" == /private/tmp ]] && return 0
  fi
  return 1
}
typeset -a scan_roots
for id in "${SHORTCUP_IDS[@]}"; do
  scan_roots+=(
    "$HOME/Library/Containers/$id"
    "$HOME/Library/Preferences/$id.plist"
    "$HOME/Library/Caches/$id"
    "$HOME/Library/Saved Application State/$id.savedState"
  )
  [[ -n "$user_cache_dir" ]] && scan_roots+=("$user_cache_dir/$id")
done
add_named_temp_roots() {
  setopt local_options extended_glob
  if [[ -n "${TMPDIR:-}" ]]; then
    scan_roots+=("${TMPDIR%/}"/(#i)*(shortcup|fixture)*(N))
  fi
  scan_roots+=(/tmp/(#i)*(shortcup|fixture)*(N))
}
add_named_temp_roots
# needle is an rg -f pattern file so the random canary is never placed on argv.
# A literal needle is only used for the replay string, which already lives in source.
scan_tree() {
  local dir="$1" pattern_file="${2:-}" literal="${3:-}" out err rg_status
  if ! allowed_scan_path "$dir"; then
    note "FAIL: refused to scan a path outside Shortcup's own data: $(show "$dir")"
    scan_failed=1
    return 0
  fi
  [[ -e "$dir" ]] || return 0
  scanned_count=$((scanned_count + 1))
  scanned_list+=("$(show "$dir")")
  out="$(mktemp)"
  err="$(mktemp)"
  rg_status=0
  if [[ -n "$pattern_file" ]]; then
    rg -a -l --max-filesize 2M -g '!*.pcm' -g '!*.dylib' -g '!*.o' -F -f "$pattern_file" "$dir" >"$out" 2>"$err" || rg_status=$?
  else
    rg -a -l --max-filesize 2M -g '!*.pcm' -g '!*.dylib' -g '!*.o' -F "$literal" "$dir" >"$out" 2>"$err" || rg_status=$?
  fi
  if [[ -s "$out" || "$rg_status" == 0 ]]; then
    cat "$out" >> "$scan_file"
  elif [[ "$rg_status" == 1 ]]; then
    :
  elif [[ "$rg_status" == 2 && ! -s "$out" ]] && python3 - "$err" <<'PY'
import sys
allowed = ("Operation not permitted", "Permission denied", "Interrupted system call")
lines = [line for line in open(sys.argv[1], errors="replace") if line.strip()]
sys.exit(0 if lines and all(any(piece in line for piece in allowed) for line in lines) else 1)
PY
  then
    note "canary scan: unreadable or interrupted paths under $(show "$dir"). Readable files had no match. Those paths are not a pass."
    scan_blocked=1
  else
    note "FAIL: canary scan error under $(show "$dir") (rg status $rg_status)"
    scan_failed=1
  fi
  rm -f "$out" "$err"
}
scanned_count=0
typeset -a scanned_list
# Random canary. The file itself lives in ~/.config and is not scanned.
scan_tree "build" "$CANARY_FILE"
scan_tree "$INSTALLED" "$CANARY_FILE"
for root in "${scan_roots[@]}"; do
  scan_tree "$root" "$CANARY_FILE"
done
# Self-check of the guard: another app's data must be refused.
if allowed_scan_path "$HOME/Library/Containers" || allowed_scan_path "$HOME/Library/Preferences" \
  || allowed_scan_path "$HOME/Library/Caches/com.example.other" || allowed_scan_path "${TMPDIR:-/tmp}"; then
  note "FAIL: canary scan allow-list accepts another app's data"
  scan_failed=1
fi
# Stable replay canary. Source and build/checks contain the literal, so they are not scanned.
scan_tree "build/verify" "" "SCX-replay-canary"
scan_tree "build/Shortcup Dev.app" "" "SCX-replay-canary"
scan_tree "build/product-link" "" "SCX-replay-canary"
scan_tree "$FIXTURE" "" "SCX-replay-canary"
log show --predicate 'process == "ShortcupDev" OR process == "Fixture"' --last 5m --style compact > build/verify/unified.log 2>/dev/null || true
if [[ -s build/verify/unified.log ]]; then
  log_status=0
  rg -a -F -q -f "$CANARY_FILE" build/verify/unified.log || log_status=$?
  if [[ "$log_status" == 0 ]]; then
    print -- "unified-log" >> "$scan_file"
  elif [[ "$log_status" != 1 ]]; then
    note "FAIL: unified log scan error"
    scan_failed=1
  fi
fi
note "canary scan read $scanned_count Shortcup-owned paths:"
for root in "${scanned_list[@]}"; do note "  $root"; done
if [[ -s "$scan_file" ]]; then
  note "CRITICAL: canary text was written to disk or the unified log"
  while IFS= read -r hit; do note "  hit: $(show "$hit")"; done < "$scan_file"
  fail=$((fail + 1))
elif [[ "$scan_failed" != 0 ]]; then
  note "FAIL: canary scan did not finish cleanly"
  fail=$((fail + 1))
elif [[ "$scan_blocked" != 0 ]]; then
  note "PASS: no canary in readable files. Some paths could not be read and were not treated as clean."
else
  note "PASS: canary text was not found in Shortcup's own files or in the unified log"
fi
rm -f "$scan_file"

note ""
note "elapsed: $((SECONDS - start))s"
if [[ "$fail" == 0 ]]; then
  note "RESULT: PASS"
  if [[ "$live" != 1 ]]; then
    note "Live clicks did not run. They stay behind zsh verify.sh --live. CI adds --direct-launch."
  fi
else
  note "RESULT: FAIL ($fail)"
fi
if [[ "$known" != 0 ]]; then
  note "KNOWN-FAIL count: $known (not counted as passes)"
fi
print -l -- "${lines[@]}" > "$SUMMARY"
exit "$fail"
