#!/usr/bin/env bash
# Builds throwaway git repos with obviously fake values and checks the built-in
# check, gitleaks, the pre-push hook, and the CI range logic.
# Must run on bash 3.2 and the awk shipped with macOS.
set -euo pipefail
export LC_ALL=C

root=$(git rev-parse --show-toplevel)
check="$root/scripts/privacy-check.sh"
installer="$root/scripts/install-pre-push-hook.sh"
config="$root/.gitleaks.toml"
fixtures="$root/scripts/privacy-fixtures"
marker="fake self-test fixture"

# Keep the user's git config (hooks path, signing, templates) out of the test repos.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GITHUB_STEP_SUMMARY GITHUB_EVENT_NAME RANGE_BEFORE RANGE_AFTER PR_BASE PR_HEAD GITHUB_SHA GITHUB_REF || true

fail() {
  echo "selftest-fail $*" >&2
  exit 1
}

command -v gitleaks > /dev/null 2>&1 || fail gitleaks-not-found

# Every line of a committed fixture that holds a fake value carries the marker.
for name in fake-private-key.txt fake-user-path.txt fake-device-name.txt; do
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == *"$marker"* ]] || fail "unmarked-fixture-line $name"
  done < "$fixtures/$name"
done

# Assembled at runtime so no real-format token is committed.
tok_head="gh"
tok_tail="p_FAKEtokenNOTreal9xK2mQ7vB4nL8pZ3wQ8s"
fake_token="${tok_head}${tok_tail}"
fake_user="someone"
fake_path="/Users/${fake_user}/fake-not-a-real-home"
fake_device="Someone-Fake'""s MacBook"
fake_host="${fake_user}-MacBook-Pro.local"
fake_host_lc=$(printf '%s' "$fake_host" | tr '[:upper:]' '[:lower:]')
pk_begin="BEGIN"
pk_kind="FAKE PRIVATE KEY"

tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

new_repo() {
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email "privacy-selftest@example.invalid"
  git -C "$1" config user.name "privacy-selftest"
  git -C "$1" config commit.gpgsign false
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

out=""
code=0
run() {
  set +e
  out=$(bash "$check" "$@" 2> "$tmp/err")
  code=$?
  set -e
}

no_raw_values() {
  local raw
  for raw in someone 가짜사용자 Someone-Fake 가짜사람 FAKEtoken "PRIVATE KEY" placeholder-not-a-password; do
    if printf '%s\n' "$out" | grep -F -q -- "$raw" || grep -F -q -- "$raw" "$tmp/err"; then
      fail "$1 raw-value-leaked"
    fi
  done
}

# Exit code, redacted stdout, and stderr limited to notes and warning annotations.
expect() {
  local want=$1 label=$2 line
  [[ "$code" -eq "$want" ]] || fail "$label expected=$want got=$code"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[^[:space:]]+:[0-9]+\ [A-Za-z0-9._-]+$ ]] || fail "$label non-redacted-output"
  done <<< "$out"
  while IFS= read -r line; do
    case "$line" in
      "" | "note: "* | "::warning file="*) ;;
      *) fail "$label unexpected-stderr" ;;
    esac
  done < "$tmp/err"
  no_raw_values "$label"
}

expect_error() {
  [[ "$code" -eq 2 ]] || fail "$1 expected=2 got=$code"
  [[ -z "$out" ]] || fail "$1 output-on-error"
  no_raw_values "$1"
}

has() {
  local pat
  pat=$(printf '%s' "$1" | sed 's#[][\.*^$+?(){}|]#\\&#g')
  if [[ -n "${3:-}" ]]; then
    pat="^${pat}:${3} ${2}\$"
  else
    pat="^${pat}:[0-9]+ ${2}\$"
  fi
  if ! printf '%s\n' "$out" | grep -E -q -- "$pat"; then
    printf '%s\n' "$out" >&2
    fail "missing-finding $1 $2 ${3:-}"
  fi
}

lacks() {
  if printf '%s\n' "$out" | grep -F -q -- "$1"; then
    fail "unexpected-finding $1"
  fi
}

# 1. Planted values in a tree: every rule, both detectors, exact fixture paths.
repo="$tmp/planted"
new_repo "$repo"
mkdir -p "$repo/planted/Users/$fake_user" "$repo/clean" "$repo/scripts/privacy-fixtures/nested" \
  "$repo/planted/.config/shortcup" "$repo/planted/App.xcodeproj/xcuserdata" "$repo/build"
cp "$fixtures/fake-private-key.txt" "$fixtures/fake-user-path.txt" "$fixtures/fake-device-name.txt" "$repo/planted/"
printf '# %s\n%s %s\n' "$marker" "$fake_token" "$marker" > "$repo/planted/fake-github-token.txt"
printf '%s\n' "placeholder-not-a-password $marker" > "$repo/planted/keychain-password"
cp "$fixtures/clean-users-path.txt" "$repo/clean/"
printf '%s\n' "ok" > "$repo/planted/Users/$fake_user/notes.txt"
printf '%s\n%s\n' "$fake_host" "$fake_host_lc" > "$repo/planted/hostname.txt"
printf '%s\n' "$fake_path/utf16" | iconv -f UTF-8 -t UTF-16 > "$repo/planted/utf16.txt"
printf 'bin\000%s\000\n' "$fake_path/binary" > "$repo/planted/binary.dat"
for name in 가짜인증서.p12 dev.pfx app.mobileprovision dist.provisionprofile Signing.certSigningRequest \
  login.keychain login.keychain-db AuthKey.p8 .env.local; do
  printf '%s\n' "placeholder" > "$repo/planted/$name"
done
printf '%s\n' "{}" > "$repo/planted/.config/shortcup/settings.json"
printf '%s\n' "x" > "$repo/planted/App.xcodeproj/xcuserdata/state.plist"
printf '%s\n' "{}" > "$repo/build/validation-events-old.jsonl"
printf '%s\n' "{}" > "$repo/build/validation-state.json.bak"
# Exact fixture path: marked lines skip only their own rule; an unmarked line is not.
cp "$fixtures/fake-user-path.txt" "$repo/scripts/privacy-fixtures/fake-user-path.txt"
printf '%s\n' "/Users/unmarkeduser/unmarked" >> "$repo/scripts/privacy-fixtures/fake-user-path.txt"
printf '%s %s %s\n' "$fake_token" "$fake_path/combined" "$marker" >> "$repo/scripts/privacy-fixtures/fake-user-path.txt"
cp "$fixtures/fake-user-path.txt" "$repo/scripts/privacy-fixtures/nested/fake-user-path.txt"
commit_all "$repo" "plant fake fixtures"

run --repo "$repo" --all
expect 1 planted-check
has planted/fake-private-key.txt private-key 2
for n in 2 3 4 5 6 8; do
  has planted/fake-user-path.txt users-path "$n"
done
has planted/fake-user-path.txt users-path 9
has planted/fake-user-path.txt users-path 10
has planted/fake-user-path.txt home-path 7
has planted/fake-user-path.txt home-path 11
for n in 2 3 4; do
  has planted/fake-device-name.txt owner-device "$n"
done
for n in 5 6 7 8 9 10 11 12; do
  has planted/fake-device-name.txt host-device "$n"
done
has planted/fake-github-token.txt github-token 2
has planted/keychain-password forbidden-filename
has "planted/Users/<redacted>/notes.txt" users-path-in-name 1
has planted/utf16.txt users-path
has planted/binary.dat users-path
has planted/hostname.txt host-device 1
has planted/hostname.txt host-device 2
for name in 가짜인증서.p12 dev.pfx app.mobileprovision dist.provisionprofile Signing.certSigningRequest \
  login.keychain login.keychain-db AuthKey.p8 .env.local .config/shortcup/settings.json \
  App.xcodeproj/xcuserdata/state.plist; do
  has "planted/$name" forbidden-filename
done
has build/validation-events-old.jsonl runtime-output
has build/validation-state.json.bak runtime-output
has scripts/privacy-fixtures/fake-user-path.txt users-path 12
has scripts/privacy-fixtures/fake-user-path.txt github-token 13
[[ "$(printf '%s\n' "$out" | grep -c '^scripts/privacy-fixtures/fake-user-path.txt:')" -eq 2 ]] ||
  fail exact-fixture-marked-lines-flagged
has scripts/privacy-fixtures/nested/fake-user-path.txt users-path 2
lacks clean/

run --repo "$repo" --all --gitleaks --config "$config"
expect 1 planted-gitleaks
has planted/fake-private-key.txt private-key
for n in 2 3 4 5 6 8; do
  has planted/fake-user-path.txt macos-user-path "$n"
done
has planted/fake-user-path.txt macos-user-path 9
has planted/fake-user-path.txt macos-user-path 10
has planted/fake-user-path.txt home-path 7
has planted/fake-user-path.txt home-path 11
for n in 2 3 4; do
  has planted/fake-device-name.txt owner-device "$n"
done
for n in 5 6 7 8 9 10 11 12; do
  has planted/fake-device-name.txt host-device "$n"
done
has planted/fake-github-token.txt github-pat
has planted/keychain-password keychain-password-file
has planted/hostname.txt host-device 1
has planted/hostname.txt host-device 2
has "planted/가짜인증서.p12" forbidden-filename
has planted/.env.local forbidden-filename
has scripts/privacy-fixtures/fake-user-path.txt macos-user-path 12
has scripts/privacy-fixtures/fake-user-path.txt github-pat 13
[[ "$(printf '%s\n' "$out" | grep -c '^scripts/privacy-fixtures/fake-user-path.txt:')" -eq 2 ]] ||
  fail exact-fixture-marked-lines-flagged-gitleaks
has scripts/privacy-fixtures/nested/fake-user-path.txt macos-user-path 2
lacks clean/

# 2. Range: added then removed, commit message, rename, non-ASCII name, a content
#    line that looks like a diff header, and media warnings.
repo="$tmp/range"
new_repo "$repo"
printf '%s\n' "ok" > "$repo/ok.txt"
printf '%s\n' "notes" > "$repo/notes.txt"
commit_all "$repo" "base"
base=$(git -C "$repo" rev-parse HEAD)
printf '%s\n' "$fake_path" > "$repo/added-path.txt"
printf '%s\n%s\n' "++ /dev/null" "$fake_path/after-header" > "$repo/m1.txt"
printf '%s\n' "not-a-screenshot" > "$repo/shot.png"
printf '%s\n' "not-a-document" > "$repo/Report.PDF"
printf '%s\n' "placeholder" > "$repo/.env.local"
printf '%s\n' "placeholder" > "$repo/가짜인증서.p12"
git -C "$repo" add -A
git -C "$repo" mv notes.txt dist.mobileprovision
git -C "$repo" commit -q -F - << EOF
add fakes
${fake_path}/in-message
${fake_device}
EOF
add_commit=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" rm -q -- added-path.txt m1.txt shot.png Report.PDF .env.local 가짜인증서.p12 dist.mobileprovision
git -C "$repo" commit -q -m "remove fakes"
head=$(git -C "$repo" rev-parse HEAD)

summary="$tmp/summary"
: > "$summary"
set +e
out=$(GITHUB_STEP_SUMMARY="$summary" bash "$check" --repo "$repo" --range "$base" "$head" 2> "$tmp/err")
code=$?
set -e
expect 1 range-check
has added-path.txt users-path 1
has m1.txt users-path 2
has .env.local forbidden-filename
has dist.mobileprovision forbidden-filename
has 가짜인증서.p12 forbidden-filename
has "$add_commit" users-path 2
has "$add_commit" owner-device 3
has shot.png unreviewed-media
has Report.PDF unreviewed-media
if grep -F -q "someone" "$summary"; then
  fail summary-leaked
fi

run --repo "$repo" --range "$base" "$head" --gitleaks --config "$config"
expect 1 range-gitleaks
has added-path.txt macos-user-path
has m1.txt macos-user-path 2
has dist.mobileprovision forbidden-filename

run --repo "$repo" --all
expect 1 range-head-messages
has "$add_commit" users-path
has "$add_commit" owner-device
lacks added-path.txt
run --repo "$repo" --all --gitleaks --config "$config"
expect 1 range-full-history
has added-path.txt macos-user-path

# 2b. Binary/UTF-16 added then removed must fail the range. A PNG-only commit
# must pass both checks and only warn.
repo="$tmp/binary"
new_repo "$repo"
printf '%s\n' "ok" > "$repo/ok.txt"
commit_all "$repo" "base"
bin_base=$(git -C "$repo" rev-parse HEAD)
printf 'bin\000%s\n' "$fake_path/binary-range" > "$repo/bin.dat"
printf '%s\n' "$fake_path/utf16-range" | iconv -f UTF-8 -t UTF-16 > "$repo/utf16-le.txt"
printf '%s\n\000%s\n%s\n' "-----${pk_begin} ${pk_kind}-----" "FAKE-NOT-A-REAL-PRIVATE-KEY-MATERIAL-FAKE-NOT-A-REAL-PRIVATE-KEY-MATERIAL-" "-----END ${pk_kind}-----" > "$repo/bin-key.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "add binary fakes"
git -C "$repo" rm -q -- bin.dat utf16-le.txt bin-key.txt
git -C "$repo" commit -q -m "remove binary fakes"
bin_head=$(git -C "$repo" rev-parse HEAD)

run --repo "$repo" --range "$bin_base" "$bin_head"
expect 1 binary-range-check
has bin.dat users-path
has utf16-le.txt users-path
has bin-key.txt private-key
run --repo "$repo" --range "$bin_base" "$bin_head" --gitleaks --config "$config"
expect 1 binary-range-gitleaks
has bin.dat macos-user-path
has utf16-le.txt macos-user-path
has bin-key.txt private-key

repo="$tmp/png"
new_repo "$repo"
printf '%s\n' "ok" > "$repo/ok.txt"
commit_all "$repo" "base"
png_base=$(git -C "$repo" rev-parse HEAD)
printf 'PNG\000not-a-screenshot\n' > "$repo/icon.png"
git -C "$repo" add icon.png
git -C "$repo" commit -q -m "add icon"
png_head=$(git -C "$repo" rev-parse HEAD)
summary="$tmp/png-summary"
: > "$summary"
set +e
out=$(GITHUB_STEP_SUMMARY="$summary" bash "$check" --repo "$repo" --range "$png_base" "$png_head" 2> "$tmp/err")
code=$?
set -e
expect 1 png-only-check
has icon.png unreviewed-media
run --repo "$repo" --range "$png_base" "$png_head" --gitleaks --config "$config"
expect 1 png-only-gitleaks
has icon.png unreviewed-media

mkdir -p "$repo/scripts"
printf '%s\n' "icon.png" > "$repo/scripts/privacy-binary-allowlist.txt"
summary="$tmp/png-allowed-summary"
: > "$summary"
set +e
out=$(GITHUB_STEP_SUMMARY="$summary" bash "$check" --repo "$repo" --range "$png_base" "$png_head" 2> "$tmp/err")
code=$?
set -e
expect 0 png-allowlisted-check
grep -F -q "::warning file=icon.png::" "$tmp/err" || fail missing-allowlisted-warning
grep -F -q "icon.png" "$summary" || fail missing-allowlisted-summary
printf '%s\n' "icon.*" > "$repo/scripts/privacy-binary-allowlist.txt"
run --repo "$repo" --range "$png_base" "$png_head"
expect_error png-wildcard-allowlist

# 3. Content that exists only in a merge commit, removed afterwards.
repo="$tmp/merge"
new_repo "$repo"
printf '%s\n' "base" > "$repo/a.txt"
commit_all "$repo" "base"
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q -b side
printf '%s\n' "side" > "$repo/s.txt"
commit_all "$repo" "side"
git -C "$repo" checkout -q main
printf '%s\n' "main" > "$repo/m.txt"
commit_all "$repo" "main"
git -C "$repo" merge -q --no-commit side > /dev/null 2>&1
printf '%s\n%s\n' "$fake_path/merge" "$fake_token" > "$repo/evil.txt"
printf '%s\n' "placeholder" > "$repo/evil.pfx"
git -C "$repo" add -A
git -C "$repo" commit -q -m "merge side"
git -C "$repo" rm -q -- evil.txt evil.pfx
git -C "$repo" commit -q -m "remove"
head=$(git -C "$repo" rev-parse HEAD)

run --repo "$repo" --range "$base" "$head"
expect 1 merge-check
has evil.txt users-path 1
has evil.txt github-token 2
has evil.pfx forbidden-filename
run --repo "$repo" --range "$base" "$head" --gitleaks --config "$config"
expect 1 merge-gitleaks
has evil.txt macos-user-path
has evil.txt github-pat
run --repo "$repo" --all --gitleaks --config "$config"
expect 1 merge-full-history
has evil.txt macos-user-path

# 4. CI push: new branch, force push, and a base that is not an ancestor all scan
#    from the default branch merge-base, not just the head tree or all history.
repo="$tmp/push"
new_repo "$repo"
printf '%s\n' "$fake_path/old" > "$repo/old.txt"
commit_all "$repo" "old main"
git -C "$repo" rm -q old.txt
printf '%s\n' "ok" > "$repo/ok.txt"
commit_all "$repo" "clean main"
main=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" update-ref refs/remotes/origin/main "$main"
git -C "$repo" checkout -q -b other
printf '%s\n' "other" > "$repo/other.txt"
commit_all "$repo" "other"
other=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q -b feature "$main"
printf '%s\n' "$fake_path/leak" > "$repo/leak.txt"
commit_all "$repo" "leak"
git -C "$repo" rm -q leak.txt
commit_all "$repo" "unleak"
feature=$(git -C "$repo" rev-parse HEAD)
zeros=0000000000000000000000000000000000000000
missing=1234567890abcdef1234567890abcdef12345678

for extra in "" "--gitleaks"; do
  set +e
  out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$zeros" RANGE_AFTER="$feature" \
    bash "$check" --repo "$repo" --ci $extra --config "$config" 2> "$tmp/err")
  code=$?
  set -e
  expect 1 "push-new-branch${extra}"
  has leak.txt "$([[ -z "$extra" ]] && echo users-path || echo macos-user-path)"
  lacks old.txt
  grep -F -q "note: range from default branch merge-base" "$tmp/err" || fail push-new-branch-note
done

for extra in "" "--gitleaks"; do
  set +e
  out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$other" RANGE_AFTER="$feature" \
    bash "$check" --repo "$repo" --ci $extra --config "$config" 2> "$tmp/err")
  code=$?
  set -e
  expect 1 "push-non-ancestor${extra}"
  has leak.txt "$([[ -z "$extra" ]] && echo users-path || echo macos-user-path)"
  lacks old.txt
done

set +e
out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$missing" RANGE_AFTER="$feature" \
  bash "$check" --repo "$repo" --ci 2> "$tmp/err")
code=$?
set -e
expect_error push-missing-before

set +e
out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$zeros" RANGE_AFTER="$main" bash "$check" --repo "$repo" --ci 2> "$tmp/err")
code=$?
set -e
expect 1 push-default-branch-full-history
has old.txt users-path
grep -F -q "note: merge-base equals tip, scanning reachable history" "$tmp/err" || fail push-tip-history-note

set +e
out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$main" RANGE_AFTER="$zeros" bash "$check" --repo "$repo" --ci 2> "$tmp/err")
code=$?
set -e
expect 0 deleted-ref
grep -F -q "note: deleted-ref, nothing to scan" "$tmp/err" || fail deleted-ref-note

# Tag of unique (add-then-remove) history vs origin/main must fail. Tag of main passes.
git -C "$repo" tag v-secret "$feature"
git -C "$repo" tag v-main "$main"
for extra in "" "--gitleaks"; do
  set +e
  out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v-secret RANGE_BEFORE="$zeros" RANGE_AFTER="$feature" \
    bash "$check" --repo "$repo" --ci $extra --config "$config" 2> "$tmp/err")
  code=$?
  set -e
  expect 1 "tag-unique${extra}"
  has leak.txt "$([[ -z "$extra" ]] && echo users-path || echo macos-user-path)"
  lacks old.txt
done
set +e
out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v-main RANGE_BEFORE="$zeros" RANGE_AFTER="$main" \
  bash "$check" --repo "$repo" --ci 2> "$tmp/err")
code=$?
set -e
expect 0 tag-on-main
grep -F -q "note: no unique commits to scan" "$tmp/err" || fail tag-on-main-note

set +e
out=$(GITHUB_EVENT_NAME=workflow_dispatch bash "$check" --repo "$tmp/planted" --ci 2> "$tmp/err")
code=$?
set -e
expect 1 workflow-dispatch-head
has planted/fake-user-path.txt users-path

run --repo "$repo" --range "$missing" "$feature"
expect_error bad-range-base
run --repo "$repo" --range "$feature" "$missing"
expect_error bad-range-head
run --repo "$repo" --range "$feature" "$feature"
expect_error empty-range
run --repo "$repo" --range "$feature" "$feature" --gitleaks --config "$config"
expect_error empty-range-gitleaks

# C1: A adds a fake home path, B removes it, main is force-pushed so origin/main
# already equals the new tip. before is the old main (not an ancestor).
repo="$tmp/force-main"
new_repo "$repo"
printf '%s\n' "ok" > "$repo/ok.txt"
commit_all "$repo" "old main"
old_main=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout --orphan rewritten > /dev/null 2>&1
git -C "$repo" rm -rf --ignore-unmatch . > /dev/null 2>&1 || true
printf '%s\n' "base" > "$repo/ok.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "new root"
printf '%s\n' "$fake_path/force" > "$repo/secret.txt"
commit_all "$repo" "add secret"
git -C "$repo" rm -q secret.txt
commit_all "$repo" "remove secret"
new_main=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" update-ref refs/remotes/origin/main "$new_main"
for extra in "" "--gitleaks"; do
  set +e
  out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$old_main" RANGE_AFTER="$new_main" \
    bash "$check" --repo "$repo" --ci $extra --config "$config" 2> "$tmp/err")
  code=$?
  set -e
  expect 1 "force-push-main${extra}"
  has secret.txt "$([[ -z "$extra" ]] && echo users-path || echo macos-user-path)"
done
set +e
out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$zeros" RANGE_AFTER="$new_main" \
  bash "$check" --repo "$repo" --ci 2> "$tmp/err")
code=$?
set -e
expect 1 force-push-main-zero-before
has secret.txt users-path

# Missing before-commit is fetched from origin when the object is still reachable.
bare="$tmp/force-bare.git"
git init -q --bare "$bare"
git -C "$bare" symbolic-ref HEAD refs/heads/main
git -C "$bare" config uploadpack.allowReachableSHA1InWant true
fetch_src="$tmp/force-fetch-src"
new_repo "$fetch_src"
printf '%s\n' "ok" > "$fetch_src/ok.txt"
commit_all "$fetch_src" "old main"
fetch_old=$(git -C "$fetch_src" rev-parse HEAD)
git -C "$fetch_src" remote add origin "$bare"
git -C "$fetch_src" push -q origin HEAD:refs/heads/main
git -C "$fetch_src" update-ref refs/keep/old "$fetch_old"
git -C "$fetch_src" push -q origin refs/keep/old:refs/keep/old
git -C "$fetch_src" checkout --orphan rewritten > /dev/null 2>&1
git -C "$fetch_src" rm -rf --ignore-unmatch . > /dev/null 2>&1 || true
printf '%s\n' "base" > "$fetch_src/ok.txt"
git -C "$fetch_src" add -A
git -C "$fetch_src" commit -q -m "new root"
printf '%s\n' "$fake_path/fetched" > "$fetch_src/secret.txt"
commit_all "$fetch_src" "add secret"
git -C "$fetch_src" rm -q secret.txt
commit_all "$fetch_src" "remove secret"
fetch_new=$(git -C "$fetch_src" rev-parse HEAD)
git -C "$fetch_src" push -q -f origin HEAD:refs/heads/main
ci_clone="$tmp/force-ci"
git clone -q --no-local "$bare" "$ci_clone"
git -C "$ci_clone" config user.email "privacy-selftest@example.invalid"
git -C "$ci_clone" config user.name "privacy-selftest"
if git -C "$ci_clone" cat-file -e "${fetch_old}^{commit}" 2> /dev/null; then
  fail fetch-setup-old-already-present
fi
set +e
out=$(GITHUB_EVENT_NAME=push RANGE_BEFORE="$fetch_old" RANGE_AFTER="$fetch_new" \
  bash "$check" --repo "$ci_clone" --ci --config "$config" 2> "$tmp/err")
code=$?
set -e
expect 1 force-push-fetch-before
has secret.txt users-path
grep -F -q "note: fetching push before-commit" "$tmp/err" || fail fetch-before-note

# 5. Pull request: contents come from the merge result and the file list from
#    base...head, so a line already removed on the base branch is not reported.
repo="$tmp/pr"
new_repo "$repo"
printf '%s\n' "$fake_path/old" "two" "three" "four" "five" > "$repo/readme.txt"
commit_all "$repo" "start"
git -C "$repo" checkout -q -b pr
printf '%s\n' "$fake_path/old" "two" "three" "four" "five changed" > "$repo/readme.txt"
commit_all "$repo" "pr edit"
pr_head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main
printf '%s\n' "two" "three" "four" "five" > "$repo/readme.txt"
commit_all "$repo" "remove old line"
pr_base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q --detach "$pr_base"
git -C "$repo" merge -q --no-ff -m "merge pr" "$pr_head" > /dev/null
pr_merge=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main

for extra in "" "--gitleaks"; do
  set +e
  out=$(GITHUB_EVENT_NAME=pull_request PR_BASE="$pr_base" PR_HEAD="$pr_head" GITHUB_SHA="$pr_merge" \
    bash "$check" --repo "$repo" --ci $extra --config "$config" 2> "$tmp/err")
  code=$?
  set -e
  expect 0 "pr-merge-result${extra}"
done
run --repo "$repo" --range "$pr_base" "$pr_head"
expect 1 pr-head-would-flag
has readme.txt users-path 1
set +e
out=$(GITHUB_EVENT_NAME=pull_request PR_BASE="$pr_base" PR_HEAD="$pr_head" GITHUB_SHA="$missing" \
  bash "$check" --repo "$repo" --ci 2> "$tmp/err")
code=$?
set -e
expect_error pr-missing-merge

# 6. The base branch scanner still catches a PR that disables its own copy.
repo="$tmp/base-scanner"
new_repo "$repo"
mkdir -p "$repo/scripts"
cp "$check" "$repo/scripts/privacy-check.sh"
cp "$config" "$repo/.gitleaks.toml"
commit_all "$repo" "scanner"
b_base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q -b pr
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/scripts/privacy-check.sh"
printf '%s\n' "$fake_path/pr" > "$repo/leak.txt"
commit_all "$repo" "disable check"
b_head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q --detach "$b_base"
git -C "$repo" merge -q --no-ff -m "merge pr" "$b_head" > /dev/null
b_merge=$(git -C "$repo" rev-parse HEAD)

set +e
GITHUB_EVENT_NAME=pull_request PR_BASE="$b_base" PR_HEAD="$b_head" GITHUB_SHA="$b_merge" \
  bash "$repo/scripts/privacy-check.sh" --repo "$repo" --ci > /dev/null 2>&1
pr_copy=$?
set -e
[[ "$pr_copy" -eq 0 ]] || fail base-scanner-setup
base_dir="$tmp/base-scanner-copy"
mkdir -p "$base_dir"
git -C "$repo" archive "$b_base" scripts/privacy-check.sh .gitleaks.toml | tar -x -C "$base_dir"
for extra in "" "--gitleaks"; do
  set +e
  out=$(GITHUB_EVENT_NAME=pull_request PR_BASE="$b_base" PR_HEAD="$b_head" GITHUB_SHA="$b_merge" \
    bash "$base_dir/scripts/privacy-check.sh" --repo "$repo" --config "$base_dir/.gitleaks.toml" --ci $extra 2> "$tmp/err")
  code=$?
  set -e
  expect 1 "base-scanner${extra}"
  has leak.txt "$([[ -z "$extra" ]] && echo users-path || echo macos-user-path)"
done

# 7. gitleaks problems are errors, never a pass.
repo="$tmp/merge"
printf '%s\n' "not [[[ toml" > "$tmp/bad.toml"
run --repo "$repo" --all --gitleaks --config "$tmp/bad.toml"
expect_error gitleaks-bad-config

fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
write_fake_gitleaks() {
  cat > "$fake_bin/gitleaks" << EOF
#!/usr/bin/env bash
report=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == --report-path ]]; then report=\$2; fi
  shift
done
[[ -n "\$report" ]] && printf '%s\n' '[]' > "\$report"
printf '%s\n' "$1" >&2
exit $2
EOF
  chmod +x "$fake_bin/gitleaks"
}
write_fake_gitleaks "1:00PM INF 3 commits scanned." 1
PATH="$fake_bin:$PATH" run --repo "$repo" --range "$base" "$head" --gitleaks --config "$config"
expect_error gitleaks-exit-1
write_fake_gitleaks "1:00PM ERR failed to read something" 0
PATH="$fake_bin:$PATH" run --repo "$repo" --range "$base" "$head" --gitleaks --config "$config"
expect_error gitleaks-err-line
write_fake_gitleaks "1:00PM INF 0 commits scanned." 0
PATH="$fake_bin:$PATH" run --repo "$repo" --range "$base" "$head" --gitleaks --config "$config"
expect_error gitleaks-zero-commits
write_fake_gitleaks "1:00PM INF no leaks found" 77
PATH="$fake_bin:$PATH" run --repo "$repo" --range "$base" "$head" --gitleaks --config "$config"
expect_error gitleaks-report-mismatch

# 8. pre-push hook: installer rules, then pushes from a clean checkout of a repo
#    that has no scripts/ directory.
remote="$tmp/remote.git"
git init -q --bare "$remote"
repo="$tmp/hook"
new_repo "$repo"
printf '%s\n' "ok" > "$repo/ok.txt"
commit_all "$repo" "start"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q origin main

hooks="$repo/.git/hooks"
mkdir -p "$hooks"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$hooks/pre-push"
set +e
(cd "$repo" && bash "$installer") > /dev/null 2> "$tmp/err"
code=$?
set -e
[[ "$code" -ne 0 ]] || fail installer-overwrote-hook
grep -F -q -- "--force" "$tmp/err" || fail installer-no-force-hint
grep -F -q "shortcup privacy" "$hooks/pre-push" && fail installer-overwrote-hook
(cd "$repo" && bash "$installer" --force) > /dev/null
grep -F -q "shortcup privacy" "$hooks/pre-push" || fail installer-force
[[ -f "$hooks/shortcup-privacy-check.sh" && -f "$hooks/shortcup-gitleaks.toml" ]] || fail installer-copy

git -C "$repo" worktree add -q -b wt "$tmp/hook-worktree" > /dev/null 2>&1
rm -f "$hooks/shortcup-privacy-check.sh"
(cd "$tmp/hook-worktree" && bash "$installer" --force) > /dev/null
[[ -f "$hooks/shortcup-privacy-check.sh" ]] || fail installer-worktree-common-dir
git -C "$repo" config core.hooksPath .githooks
(cd "$repo" && bash "$installer" --force) > /dev/null 2> "$tmp/err"
grep -F -q "core.hooksPath" "$tmp/err" || fail installer-hookspath-warning
git -C "$repo" config --unset core.hooksPath

push() {
  set +e
  out=$(cd "$repo" && git push "$@" 2>&1)
  code=$?
  set -e
  : > "$tmp/err"
  no_raw_values "push $*"
}

git -C "$repo" checkout -q -b leak
printf '%s\n%s\n' "$fake_path/hook" "$fake_token" > "$repo/leak.txt"
printf '%s\n' "placeholder" > "$repo/dev.pfx"
commit_all "$repo" "leak"
git -C "$repo" rm -q -- leak.txt dev.pfx
commit_all "$repo" "unleak"
git -C "$repo" checkout -q main
push origin leak
[[ "$code" -ne 0 ]] || fail hook-new-branch-passed
if git --git-dir="$remote" rev-parse -q --verify refs/heads/leak > /dev/null; then
  fail hook-new-branch-reached-remote
fi

git -C "$repo" checkout -q -b clean main
printf '%s\n' "fine" > "$repo/fine.txt"
commit_all "$repo" "fine"
git -C "$repo" checkout -q main
push origin clean
[[ "$code" -eq 0 ]] || fail hook-clean-new-branch-refused
clean_remote=$(git --git-dir="$remote" rev-parse refs/heads/clean)

git -C "$repo" checkout -q clean
printf '%s\n' "$fake_path/update" > "$repo/update.txt"
commit_all "$repo" "update leak"
git -C "$repo" rm -q update.txt
commit_all "$repo" "update unleak"
git -C "$repo" checkout -q main
push origin clean
[[ "$code" -ne 0 ]] || fail hook-existing-branch-passed
[[ "$(git --git-dir="$remote" rev-parse refs/heads/clean)" == "$clean_remote" ]] || fail hook-existing-branch-reached-remote
git -C "$repo" branch -q -f clean "$clean_remote"

git -C "$repo" branch -q same main
push origin same
[[ "$code" -eq 0 ]] || fail hook-no-new-commits-refused

# Without gitleaks the hook refuses unless skipping is explicit.
no_gl_path=""
old_ifs=$IFS
IFS=:
for dir in $PATH; do
  [[ -x "$dir/gitleaks" ]] && continue
  no_gl_path="${no_gl_path:+$no_gl_path:}$dir"
done
IFS=$old_ifs
if ! PATH="$no_gl_path" command -v gitleaks > /dev/null 2>&1 &&
  PATH="$no_gl_path" command -v git > /dev/null 2>&1; then
  git -C "$repo" branch -q nogl main
  set +e
  (cd "$repo" && PATH="$no_gl_path" git push -q origin nogl) > /dev/null 2>&1
  code=$?
  set -e
  [[ "$code" -ne 0 ]] || fail hook-missing-gitleaks-passed
  set +e
  (cd "$repo" && PATH="$no_gl_path" SHORTCUP_PRIVACY_SKIP_GITLEAKS=1 git push -q origin nogl) > /dev/null 2> "$tmp/err"
  code=$?
  set -e
  [[ "$code" -eq 0 ]] || fail hook-skip-gitleaks-refused
  grep -F -q "SHORTCUP_PRIVACY_SKIP_GITLEAKS" "$tmp/err" || fail hook-skip-gitleaks-no-warning
else
  echo "note: could not hide gitleaks from PATH; skipped the missing-gitleaks hook case" >&2
fi

# 9. This repository stays clean under the production config.
out=""
set +e
out=$(bash "$check" --repo "$root" --all 2> "$tmp/err")
code=$?
set -e
[[ ! -s "$tmp/err" ]] || fail real-repo-stderr
[[ "$code" -eq 0 && -z "$out" ]] || {
  printf '%s\n' "$out" >&2
  fail real-repo-flagged
}
set +e
out=$(bash "$check" --repo "$root" --all --gitleaks 2> "$tmp/err")
code=$?
set -e
[[ ! -s "$tmp/err" ]] || fail real-repo-gitleaks-stderr
[[ "$code" -eq 0 && -z "$out" ]] || {
  printf '%s\n' "$out" >&2
  fail real-repo-gitleaks-flagged
}

echo "privacy-selftest-ok"
