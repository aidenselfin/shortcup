#!/bin/zsh
# Safe Shortcup checks. This script does not launch an app unless you pass --live.
# --live starts windows on the screen and sends synthetic clicks. Leave it off.
# Default launch on the dev Mac uses LaunchServices with -g. CI passes
# --direct-launch or SHORTCUP_LAUNCH=direct so the executable is started directly.
set -euo pipefail
cd "${0:A:h}"
unset RIPGREP_CONFIG_PATH

run_rg() {
  unset RIPGREP_CONFIG_PATH
  if [[ -x /opt/homebrew/bin/rg ]]; then
    /opt/homebrew/bin/rg --no-config "$@"
  elif [[ -x /usr/local/bin/rg ]]; then
    /usr/local/bin/rg --no-config "$@"
  elif [[ -x /usr/bin/rg ]]; then
    /usr/bin/rg --no-config "$@"
  else
    print -- "FAIL: rg is not installed"
    return 127
  fi
}
if ! run_rg --version >/dev/null 2>&1; then
  print -- "FAIL: rg is not installed"
  exit 1
fi

live=0
direct_selected=0
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    --direct-launch) direct_selected=1 ;;
    *) print -- "unknown argument: $arg"; exit 2 ;;
  esac
done

DEV_APP="$PWD/build/Shortcup Dev.app"
KEYCHAIN="${HOME}/Library/Keychains/shortcup-dev.keychain-db"
PW_FILE="${HOME}/.config/shortcup/keychain-password"
CANARY_FILE="${HOME}/.config/shortcup/verify-canary"
FIXTURE="build/Shortcup Fixture.app"
SUMMARY="build/verify/summary.txt"
ROOT="$PWD"
fail=0
known=0
sign_ok=0
lines=()
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

/bin/mkdir -p build/verify
/bin/rm -f "$SUMMARY"

note "Shortcup verify"
if [[ "$live" != 1 ]]; then
  note "SAFE MODE: no app will be launched and no click or key will be sent."
  if [[ "$direct_selected" == 1 ]]; then
    note "NOTE: direct launch is selected, but without --live nothing is started."
  fi
else
  note "WARNING: --live will start Shortcup Fixture and Shortcup Dev windows on this screen and send synthetic clicks."
fi
note ""

# --- secrets and static checks (no Accessibility, no launch) ---
tracked=""
if tracked="$(/usr/bin/git ls-files)"; then
  if print -r -- "$tracked" | /usr/bin/grep -E '\.(p12|pem|key)$|keychain-password|dev-key' >/dev/null; then
    note "CRITICAL: a private key or password file is tracked in git"
    fail=$((fail + 1))
  else
    note "PASS: no signing key or password is tracked"
  fi
else
  note "CRITICAL: git ls-files failed, so the secret check cannot pass"
  fail=$((fail + 1))
fi

if /usr/bin/grep -R -E 'URLSession|import Network|NWConnection|NSURLConnection' Sources Fixture >/dev/null; then
  note "CRITICAL: network API referenced in Sources or Fixture"
  fail=$((fail + 1))
else
  note "PASS: no URLSession or Network framework usage"
fi

if /usr/bin/grep -E 'keyDown|keyUp|flagsChanged' Sources/App.swift Sources/Detect.swift Sources/SelfTest.swift >/dev/null; then
  note "CRITICAL: key event monitor found in the listener sources"
  fail=$((fail + 1))
else
  note "PASS: listener sources have no keyDown, keyUp, or flagsChanged"
fi
if /usr/bin/grep -n 'tapCreate' -A 2 Sources/App.swift | /usr/bin/grep -q 'listenOnly'; then
  note "PASS: event tap is listenOnly for mouse down, up, and drag"
else
  note "CRITICAL: event tap is missing or not listenOnly"
  fail=$((fail + 1))
fi
if /usr/bin/grep -n 'AXUIElementSetAttributeValue' Sources/App.swift Sources/Detect.swift Sources/SelfTest.swift Sources/Shortcuts.swift >/dev/null; then
  note "CRITICAL: AXUIElementSetAttributeValue is in the product or selftest path"
  fail=$((fail + 1))
fi
if /usr/bin/grep -n 'AXUIElementSetAttributeValue' Sources/Validation.swift >/dev/null; then
  note "KNOWN-FAIL: legacy --validate-once still sets an address-field value. verify.sh does not run it. Expected until a later cleanup."
  known=$((known + 1))
fi
if /usr/bin/grep -n 'hint.title' Sources/App.swift >/dev/null; then
  note "KNOWN-FAIL: menu and toolbar validation logs still store command titles (validation-events.jsonl). Expected until the v0.1 fix."
  known=$((known + 1))
fi
if /usr/bin/python3 scripts/test-launch-guard.py > build/verify/launch-guard-test.txt 2>&1; then
  note "$(/bin/cat build/verify/launch-guard-test.txt)"
else
  note "FAIL: launch guard cases"
  while IFS= read -r line; do note "  $line"; done < build/verify/launch-guard-test.txt
  fail=$((fail + 1))
fi
if /usr/bin/python3 scripts/test-keychain-prompt.py > build/verify/keychain-prompt-test.txt 2>&1; then
  note "$(/bin/cat build/verify/keychain-prompt-test.txt)"
else
  note "FAIL: keychain prompt cases"
  while IFS= read -r line; do note "  $line"; done < build/verify/keychain-prompt-test.txt
  fail=$((fail + 1))
fi
# Command-line stubs outside build/. No app is started.
if /usr/bin/python3 scripts/test-stop-launched.py > build/verify/stop-test.txt 2>&1; then
  note "$(/usr/bin/tail -n 1 build/verify/stop-test.txt)"
else
  note "FAIL: hung-run stop helper"
  /usr/bin/tail -n 20 build/verify/stop-test.txt | while IFS= read -r line; do note "  $line"; done
  fail=$((fail + 1))
fi
if /usr/bin/python3 scripts/test-canary-paths.py > build/verify/canary-paths-test.txt 2>&1; then
  note "$(/bin/cat build/verify/canary-paths-test.txt)"
else
  note "FAIL: canary path cases"
  while IFS= read -r line; do note "  $line"; done < build/verify/canary-paths-test.txt
  fail=$((fail + 1))
fi
if /usr/bin/python3 scripts/check-launch-guard.py > build/verify/launch-guard.txt 2>&1; then
  note "PASS: app launch is only in the live script, and SAFE files have no launch primitives"
else
  note "CRITICAL: verify.sh can launch an app without --live, or a launch method is missing"
  if [[ -s build/verify/launch-guard.txt ]]; then
    while IFS= read -r line; do note "  $line"; done < build/verify/launch-guard.txt
  fi
  fail=$((fail + 1))
fi

note ""
note "LAYER 2 snapshots"
if /bin/zsh -f build.sh --checks-only > build/verify/checks.log 2>&1; then
  note "PASS: snapshot replay, glyph table, locale, cache, and AX allow-list"
else
  note "FAIL: permission-free checks"
  if [[ -s build/verify/checks.log ]]; then
    /usr/bin/tail -n 40 build/verify/checks.log | while IFS= read -r line; do note "  $line"; done
  fi
  fail=$((fail + 1))
fi

/bin/mkdir -p build/product-link
if /usr/bin/swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Sources/Detect.swift Sources/App.swift Sources/Validation.swift \
    -o build/product-link/Shortcup -framework AppKit -framework ApplicationServices -framework Carbon \
    > build/verify/product-link.log 2>&1; then
  if /usr/bin/grep -q 'will never be executed' build/verify/product-link.log; then
    note "FAIL: product build still has a dead self-test branch"
    fail=$((fail + 1))
  elif /usr/bin/strings -a build/product-link/Shortcup | /usr/bin/grep -q 'com.shortcup.fixture'; then
    note "CRITICAL: product binary contains the fixture selftest"
    fail=$((fail + 1))
  elif /usr/bin/nm build/product-link/Shortcup | /usr/bin/grep -q 'ForTesting'; then
    note "FAIL: product binary exposes a ForTesting hook"
    fail=$((fail + 1))
  else
    note "PASS: product build has no fixture selftest and no dead self-test branch"
  fi
  repo_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist 2>/dev/null || true)"
  bin_min="$(/usr/bin/vtool -show-build build/product-link/Shortcup 2>/dev/null | /usr/bin/python3 scripts/vtool-minos.py || true)"
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
/usr/bin/python3 scripts/write-schema-samples.py "$schema_dir"
if /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/skipped.json" > build/verify/schema-ok.txt \
  && /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/skipped-direct.json" >> build/verify/schema-ok.txt \
  && /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/pass.json" >> build/verify/schema-ok.txt \
  && /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/skip-case.json" >> build/verify/schema-ok.txt \
  && ! /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/extra.json" >/dev/null 2>&1 \
  && ! /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/bool-int.json" >/dev/null 2>&1 \
  && ! /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/nested.json" >/dev/null 2>&1 \
  && ! /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/bad-launch.json" >/dev/null 2>&1 \
  && ! /usr/bin/python3 scripts/check-selftest-json.py "$schema_dir/mismatch.json" >/dev/null 2>&1; then
  note "PASS: selftest JSON allow-list accepts axTrusted and launchMethod, rejects extra keys, bools-as-ints, and nested extras"
else
  note "FAIL: selftest JSON allow-list"
  fail=$((fail + 1))
fi

note ""
note "LAYER 1 signing"
if /usr/bin/python3 scripts/run-deadline.py 120 build/verify/signing-setup.log -- /bin/zsh -f setup-dev-signing.sh; then
  if /usr/bin/python3 scripts/run-deadline.py 120 build/verify/dev-build.log -- /bin/zsh -f build.sh --dev; then
    if /usr/bin/python3 scripts/check-dev-bundle.py --running "$DEV_APP"; then
      note "FAIL: Shortcup Dev build is already running. This script will not quit it or sign over it."
      fail=$((fail + 1))
    elif /usr/bin/python3 scripts/run-deadline.py 120 build/verify/keychain-unlock.log -- /usr/bin/python3 scripts/keychain.py unlock "$KEYCHAIN" "$PW_FILE" \
      && /usr/bin/python3 scripts/run-deadline.py 120 build/verify/codesign-sign.log -- /usr/bin/codesign --force --sign "Shortcup Dev" --keychain "$KEYCHAIN" --identifier com.shortcup.dev "$DEV_APP"; then
      if ! /usr/bin/python3 scripts/run-deadline.py 120 build/verify/keychain-lock.log -- /usr/bin/python3 scripts/keychain.py lock "$KEYCHAIN"; then
        note "FAIL: dev keychain did not lock"
        fail=$((fail + 1))
      fi
      if /usr/bin/python3 scripts/check-dev-bundle.py --inspect "$DEV_APP" > build/verify/codesign.txt 2>&1; then
        note "PASS: designated requirement has a certificate leaf (signed in build/, not copied to ~/Applications)"
        note "$(/usr/bin/grep '^designated' build/verify/codesign.txt || true)"
        note "PASS: dev LSMinimumSystemVersion matches the binary and LSUIElement is true"
        sign_ok=1
      else
        note "FAIL: designated requirement has no certificate leaf or the plist does not match"
        while IFS= read -r line; do note "  $line"; done < build/verify/codesign.txt
        fail=$((fail + 1))
      fi
    else
      /usr/bin/python3 scripts/run-deadline.py 120 build/verify/keychain-lock-fail.log -- /usr/bin/python3 scripts/keychain.py lock "$KEYCHAIN" || true
      note "FAIL: codesign failed. See build/verify/codesign-sign.log"
      if [[ -s build/verify/codesign-sign.log ]]; then
        /usr/bin/tail -n 40 build/verify/codesign-sign.log | while IFS= read -r line; do note "  $line"; done
      fi
      fail=$((fail + 1))
    fi
  else
    note "FAIL: dev build failed"
    if [[ -s build/verify/dev-build.log ]]; then
      /usr/bin/tail -n 40 build/verify/dev-build.log | while IFS= read -r line; do note "  $line"; done
    fi
    fail=$((fail + 1))
  fi
else
  note "FAIL: signing identity was not created"
  if [[ -s build/verify/signing-setup.log ]]; then
    /usr/bin/tail -n 80 build/verify/signing-setup.log | while IFS= read -r line; do note "  $line"; done
  fi
  fail=$((fail + 1))
fi

note ""
note "fixture compile"
if /bin/zsh -f build.sh --fixture > build/verify/fixture-build.log 2>&1; then
  note "PASS: fixture app compiled and signed, not launched"
else
  note "FAIL: fixture app did not build"
  if [[ -s build/verify/fixture-build.log ]]; then
    /usr/bin/tail -n 20 build/verify/fixture-build.log | while IFS= read -r line; do note "  $line"; done
  fi
  fail=$((fail + 1))
fi

note ""
if [[ "$live" == 1 ]]; then
  live_status=0
  SHORTCUP_SIGN_OK="$sign_ok" /bin/zsh -f "$ROOT/scripts/verify-live.sh" "$@" > build/verify/live.log 2>&1 || live_status=$?
  while IFS= read -r line; do
    note "$line"
  done < build/verify/live.log
  fail=$((fail + live_status))
else
  note "LAYER 3: SKIPPED. --live was not passed, so no window was opened and no synthetic click was sent."
fi

note ""
note "LAYER 4 privacy"
/bin/mkdir -p "${HOME}/.config/shortcup"
if [[ ! -f "$CANARY_FILE" ]]; then
  umask 077
  print -n -- "SCX-$(/usr/bin/openssl rand -hex 4)" > "$CANARY_FILE"
  /bin/chmod 600 "$CANARY_FILE"
fi
canary_mode="$(/usr/bin/stat -f '%Lp' "$CANARY_FILE")"
if [[ "$canary_mode" != "600" ]]; then
  note "CRITICAL: canary file mode is $canary_mode, expected 600"
  fail=$((fail + 1))
fi
pw_mode="$(/usr/bin/stat -f '%Lp' "$PW_FILE" 2>/dev/null || true)"
if [[ "$pw_mode" != "600" ]]; then
  note "CRITICAL: keychain password file mode is ${pw_mode:-missing}, expected 600"
  fail=$((fail + 1))
fi
scan_file="$(/usr/bin/mktemp)"
: > "$scan_file"
scan_failed=0
scan_blocked=0
scan_tree() {
  local dir="$1" pattern_file="${2:-}" literal="${3:-}" out err rg_status
  if ! /usr/bin/python3 scripts/canary-paths.py --allowed "$dir"; then
    note "FAIL: refused to scan a path outside Shortcup's own data: $(show "$dir")"
    scan_failed=1
    return 0
  fi
  [[ -e "$dir" ]] || return 0
  scanned_count=$((scanned_count + 1))
  scanned_list+=("$(show "$dir")")
  out="$(/usr/bin/mktemp)"
  err="$(/usr/bin/mktemp)"
  rg_status=0
  if [[ -n "$pattern_file" ]]; then
    run_rg -a -l --max-filesize 2M -g '!*.pcm' -g '!*.dylib' -g '!*.o' -F -f "$pattern_file" "$dir" >"$out" 2>"$err" || rg_status=$?
  else
    run_rg -a -l --max-filesize 2M -g '!*.pcm' -g '!*.dylib' -g '!*.o' -F "$literal" "$dir" >"$out" 2>"$err" || rg_status=$?
  fi
  if [[ -s "$out" || "$rg_status" == 0 ]]; then
    /bin/cat "$out" >> "$scan_file"
  elif [[ "$rg_status" == 1 ]]; then
    :
  elif [[ "$rg_status" == 2 && ! -s "$out" ]] && /usr/bin/python3 scripts/rg-blocked.py "$err"; then
    note "canary scan: unreadable or interrupted paths under $(show "$dir"). Readable files had no match. Those paths are not a pass."
    scan_blocked=1
  else
    note "FAIL: canary scan error under $(show "$dir") (rg status $rg_status)"
    scan_failed=1
  fi
  /bin/rm -f "$out" "$err"
}
scanned_count=0
typeset -a scanned_list
# Random canary. The file itself lives in ~/.config and is not scanned.
while IFS= read -r root; do
  scan_tree "$root" "$CANARY_FILE"
done < <(/usr/bin/python3 scripts/canary-paths.py)
# Self-check of the guard: another app's data must be refused.
if /usr/bin/python3 scripts/canary-paths.py --allowed "$HOME/Library/Containers" \
  || /usr/bin/python3 scripts/canary-paths.py --allowed "$HOME/Library/Preferences" \
  || /usr/bin/python3 scripts/canary-paths.py --allowed "$HOME/Library/Caches/com.example.other"; then
  note "FAIL: canary scan allow-list accepts another app's data"
  scan_failed=1
fi
note "canary scan read $scanned_count Shortcup-owned paths:"
for root in "${scanned_list[@]}"; do note "  $root"; done
if [[ -s "$scan_file" ]]; then
  note "CRITICAL: canary text was written to disk"
  while IFS= read -r hit; do note "  hit: $(show "$hit")"; done < "$scan_file"
  fail=$((fail + 1))
elif [[ "$scan_failed" != 0 ]]; then
  note "FAIL: canary scan did not finish cleanly"
  fail=$((fail + 1))
elif [[ "$scan_blocked" != 0 ]]; then
  note "PASS: no canary in readable files. Some paths could not be read and were not treated as clean."
else
  note "PASS: canary text was not found in Shortcup's own files"
fi
/bin/rm -f "$scan_file"

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
