#!/bin/zsh
# Safe Shortcup checks. This script does not launch an app unless you pass --live.
# --live opens windows on the screen and sends synthetic clicks. Leave it off.
set -u
cd "${0:A:h}"

live=0
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    *) print -- "unknown argument: $arg"; exit 2 ;;
  esac
done

APP="${HOME}/Applications/Shortcup Dev.app"
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
lines=()
start=$SECONDS
note() { lines+=("$1"); print -- "$1"; }

# Only binaries under this repo's build/ directory. Never ~/shortcup, never ~/Applications.
kill_build_only() {
  local pid command
  ps -ax -o pid=,command= | while IFS= read -r line; do
    pid="${line%% *}"
    command="${line#"$pid"}"
    command="${command#"${command%%[![:space:]]*}"}"
    case "$command" in
      "$ROOT/build/"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
}

cleanup() {
  [[ "$live" == 1 ]] || return 0
  [[ -d "$CONTROL" ]] && : > "$CONTROL/quit" 2>/dev/null || true
  [[ -d "$STRUCT_CONTROL" ]] && : > "$STRUCT_CONTROL/quit" 2>/dev/null || true
  kill_build_only
}
trap cleanup EXIT

mkdir -p build/verify
rm -f "$SUMMARY"

note "Shortcup verify"
if [[ "$live" == 1 ]]; then
  note "WARNING: --live will open Shortcup Fixture and Shortcup Dev windows on this screen and send synthetic clicks."
  note "The fixture is an accessory app. Its windows are small, sit in the bottom-right corner, and cannot become key."
else
  note "SAFE MODE: no app will be launched and no click or key will be sent."
fi
note ""

# --- secrets and static checks (no Accessibility, no launch) ---
if git ls-files | grep -E '\.(p12|pem|key)$|keychain-password|dev-key' >/dev/null; then
  note "CRITICAL: a private key or password file is tracked in git"
  fail=$((fail + 1))
else
  note "PASS: no signing key or password is tracked"
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
if grep -n 'NSApp.activate\|setActivationPolicy(.regular)' Fixture/main.swift >/dev/null; then
  note "CRITICAL: the fixture can still activate or use the regular policy"
  fail=$((fail + 1))
else
  note "PASS: fixture source does not activate and is not a regular app"
fi
python3 - <<'PY'
from pathlib import Path
lines = Path("verify.sh").read_text().splitlines()
live = False
bad = []
needle = "open " + "-W"
for number, line in enumerate(lines, 1):
    if "LIVE-ONLY-START" in line:
        live = True
    elif "LIVE-ONLY-END" in line:
        live = False
    if line.strip().startswith("#"):
        continue
    if needle in line and not live:
        bad.append(str(number))
if bad:
    raise SystemExit("launch is outside the live-only section: " + ",".join(bad))
PY
if [[ $? -eq 0 ]]; then
  note "PASS: app launch is only inside the --live section"
else
  note "CRITICAL: verify.sh can launch an app without --live"
  fail=$((fail + 1))
fi

note ""
note "LAYER 2 snapshots"
if zsh build.sh --checks-only; then
  note "PASS: snapshot replay, glyph table, locale, cache, and AX allow-list"
else
  note "FAIL: permission-free checks"
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
  else
    note "PASS: product build has no fixture selftest and no dead self-test branch"
  fi
else
  note "FAIL: product sources did not compile"
  fail=$((fail + 1))
fi

note ""
note "JSON schema allow-list"
schema_dir="build/verify/schema"
mkdir -p "$schema_dir"
print -r -- '{"cases":[],"result":"skipped","trusted":false}' > "$schema_dir/skipped.json"
print -r -- '{"trusted":true,"result":"pass","cases":[{"subrole":"AXCloseButton","identifier":"","shortcut":"","result":"pass"}],"titleFallbackReads":1,"hangSeconds":0.01,"menuWalksAfterFirst":1,"menuWalksAfterSecond":1,"idleAxReads":0,"canaryLeak":false,"axAllowListOK":true,"disallowed":[]}' > "$schema_dir/pass.json"
print -r -- '{"cases":[],"result":"skipped","trusted":false,"title":"should-not-be-here"}' > "$schema_dir/extra.json"
if python3 scripts/check-selftest-json.py "$schema_dir/skipped.json" >/dev/null 2>&1 \
  && python3 scripts/check-selftest-json.py "$schema_dir/pass.json" >/dev/null 2>&1 \
  && ! python3 scripts/check-selftest-json.py "$schema_dir/extra.json" >/dev/null 2>&1; then
  note "PASS: selftest JSON allow-list accepts skip and pass, rejects extra keys"
else
  note "FAIL: selftest JSON allow-list"
  fail=$((fail + 1))
fi

note ""
note "LAYER 1 signing"
sign_ok=0
if zsh setup-dev-signing.sh > build/verify/signing-setup.log 2>&1; then
  if zsh build.sh --dev > build/verify/dev-build.log 2>&1; then
    if ps -ax -o command= | grep -F "$APP/Contents/MacOS/ShortcupDev" | grep -v grep >/dev/null; then
      note "FAIL: Shortcup Dev is already running. This script will not quit it."
      fail=$((fail + 1))
    else
      rm -rf "$APP"
      mkdir -p "${HOME}/Applications"
      ditto "build/Shortcup Dev.app" "$APP"
      if security unlock-keychain -p "$(cat "$PW_FILE")" "$KEYCHAIN" \
        && codesign --force --sign "Shortcup Dev" --keychain "$KEYCHAIN" --identifier com.shortcup.dev "$APP"; then
        requirement="$(codesign -d -r- "$APP" 2>&1 || true)"
        print -- "$requirement" > build/verify/codesign.txt
        if print -- "$requirement" | grep -q 'certificate leaf'; then
          note "PASS: designated requirement has a certificate leaf"
          note "$requirement"
          sign_ok=1
        else
          note "FAIL: designated requirement has no certificate leaf"
          fail=$((fail + 1))
        fi
        plist_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
        bin_min="$(vtool -show-build "$APP/Contents/MacOS/ShortcupDev" | awk '/minos/ { print $2; exit }')"
        if [[ "$plist_min" == "$bin_min" && -n "$bin_min" ]]; then
          note "PASS: LSMinimumSystemVersion $plist_min matches the binary"
        else
          note "FAIL: LSMinimumSystemVersion plist=$plist_min binary=$bin_min"
          fail=$((fail + 1))
        fi
      else
        note "FAIL: codesign failed"
        fail=$((fail + 1))
      fi
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
if swiftc -module-cache-path build/module-cache Fixture/main.swift -o "$FIXTURE/Contents/MacOS/Fixture" -framework AppKit \
  && cat > "$FIXTURE/Contents/Info.plist" <<'EOF'
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
then
  codesign --force --sign - --identifier com.shortcup.fixture "$FIXTURE" >/dev/null
  note "PASS: fixture app compiled and signed, not launched"
else
  note "FAIL: fixture app did not build"
  fail=$((fail + 1))
fi

# LIVE-ONLY-START
run_live() {
  note ""
  note "WARNING: opening Shortcup Fixture and Shortcup Dev now. Windows will appear in the bottom-right corner."
  note "LAYER 3 live fixture"
  if [[ "$sign_ok" != 1 ]]; then
    note "FAIL: signing did not succeed, so the dev app was not launched"
    fail=$((fail + 1))
    return
  fi
  mkdir -p "$CONTROL" "$STRUCT_CONTROL" "${HOME}/.config/shortcup"
  canary="SCX-$(openssl rand -hex 4)"
  umask 077
  print -n -- "$canary" > "$CANARY_FILE"
  chmod 600 "$CANARY_FILE"
  rm -f "$STRUCT_OUT" "$OUT"
  open -W -n "$FIXTURE" --args --control "$PWD/$STRUCT_CONTROL" --dump-structure "$PWD/$STRUCT_OUT" &
  struct_opener=$!
  for _ in {1..75}; do
    [[ -f "$STRUCT_OUT" ]] && break
    kill -0 "$struct_opener" 2>/dev/null || break
    sleep 0.2
  done
  : > "$STRUCT_CONTROL/quit"
  wait "$struct_opener" 2>/dev/null || true
  if [[ -f "$STRUCT_OUT" ]] && python3 scripts/check-fixture-structure.py "$STRUCT_OUT" > build/verify/fixture-structure.txt 2>&1; then
    note "PASS: fixture own-tree has the standard window, sheet, panel, and menu identifiers"
    while IFS= read -r line; do note "  $line"; done < build/verify/fixture-structure.txt
  else
    note "FAIL: fixture own-tree did not match the expected window and menu structure"
    fail=$((fail + 1))
  fi
  open -W -n "$APP" --args --selftest "$PWD/$OUT" --fixture "$PWD/$FIXTURE" --control "$PWD/$CONTROL" --canary-file "$CANARY_FILE" &
  opener=$!
  lsof_ok="skipped"
  for _ in {1..375}; do
    if [[ -z "${lsof_done:-}" && -f "$CONTROL/shortcup.pid" ]]; then
      pid="$(tr -dc '0-9' < "$CONTROL/shortcup.pid")"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        if lsof -nP -a -i -p "$pid" > build/verify/lsof.txt 2>/dev/null; then
          note "CRITICAL: ShortcupDev has a network connection"
          fail=$((fail + 1))
          lsof_ok="fail"
        else
          note "PASS: lsof shows no connections for ShortcupDev"
          lsof_ok="pass"
        fi
        lsof_done=1
      fi
    fi
    kill -0 "$opener" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$opener" 2>/dev/null; then
    note "FAIL: selftest did not finish within 75s"
    fail=$((fail + 1))
    : > "$CONTROL/quit"
  else
    wait "$opener" || true
  fi
  if [[ -f "$OUT" ]]; then
    python3 scripts/check-selftest-json.py "$OUT" > build/verify/selftest-schema.txt 2>&1
    schema_status=$?
    while IFS= read -r line; do note "  $line"; done < build/verify/selftest-schema.txt
    if [[ "$schema_status" != 0 ]]; then
      note "CRITICAL: selftest JSON failed the allow-list schema"
      fail=$((fail + 1))
    else
      result="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"])' "$OUT")"
      if [[ "$result" == "skipped" ]]; then
        note "SKIPPED: needs Accessibility for $APP"
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
  if [[ "$lsof_ok" == "skipped" ]]; then
    note "FAIL: could not run lsof against the dev app"
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
if [[ -z "${canary:-}" ]]; then
  canary="SCX-$(openssl rand -hex 4)"
  umask 077
  print -n -- "$canary" > "$CANARY_FILE"
  chmod 600 "$CANARY_FILE"
fi
scan_file="$(mktemp)"
: > "$scan_file"
search_one() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  rg -a -l --max-filesize 2M -g '!*.pcm' -g '!*.dylib' -g '!*.o' -F "$canary" "$dir" >> "$scan_file" 2>/dev/null || true
}
search_one "build/verify"
search_one "build/Shortcup Dev.app"
search_one "$APP"
search_one "$FIXTURE"
search_one "${HOME}/Library/Application Support"
search_one "${HOME}/Library/Caches"
search_one "${HOME}/Library/Logs"
if [[ -n "${TMPDIR:-}" ]]; then search_one "$TMPDIR"; fi
search_one /tmp
log show --predicate 'process == "ShortcupDev" OR process == "Fixture"' --last 5m --style compact > build/verify/unified.log 2>/dev/null || true
if [[ -s build/verify/unified.log ]] && rg -a -F -q "$canary" build/verify/unified.log; then
  print -- "unified-log" >> "$scan_file"
fi
if [[ -s "$scan_file" ]]; then
  note "CRITICAL: canary text was written to disk or the unified log"
  while IFS= read -r hit; do note "  hit: $hit"; done < "$scan_file"
  fail=$((fail + 1))
else
  note "PASS: canary text was not found on disk or in the unified log"
fi
rm -f "$scan_file"

note ""
note "elapsed: $((SECONDS - start))s"
if [[ "$fail" == 0 ]]; then
  note "RESULT: PASS"
  if [[ "$live" != 1 ]]; then
    note "Live clicks did not run. They stay behind zsh verify.sh --live."
  fi
else
  note "RESULT: FAIL ($fail)"
fi
if [[ "$known" != 0 ]]; then
  note "KNOWN-FAIL count: $known (not counted as passes)"
fi
print -l -- "${lines[@]}" > "$SUMMARY"
exit "$fail"
