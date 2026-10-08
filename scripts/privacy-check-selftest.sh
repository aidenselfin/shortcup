#!/usr/bin/env bash
# Builds a throwaway git repo with obvious fakes and checks both detectors.
set -euo pipefail
export LC_ALL=C

root=$(git rev-parse --show-toplevel)
check="$root/scripts/privacy-check.sh"
marker="fake self-test fixture"
for fixture in \
  scripts/privacy-fixtures/fake-private-key.txt \
  scripts/privacy-fixtures/fake-user-path.txt \
  scripts/privacy-fixtures/fake-github-token.txt \
  scripts/privacy-fixtures/keychain-password \
  scripts/privacy-fixtures/clean-users-path.txt
do
  if ! grep -F -q -- "$marker" "$root/$fixture"; then
    echo "missing-fake-marker" >&2
    exit 1
  fi
done

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks-not-found" >&2
  exit 1
fi

tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

repo="$tmp/repo"
mkdir -p "$repo/planted" "$repo/clean"
cp "$root/scripts/privacy-fixtures/fake-private-key.txt" "$repo/planted/fake-private-key.txt"
cp "$root/scripts/privacy-fixtures/fake-user-path.txt" "$repo/planted/fake-user-path.txt"
cp "$root/scripts/privacy-fixtures/fake-github-token.txt" "$repo/planted/fake-github-token.txt"
cp "$root/scripts/privacy-fixtures/keychain-password" "$repo/planted/keychain-password"
cp "$root/scripts/privacy-fixtures/clean-users-path.txt" "$repo/clean/clean-users-path.txt"

git init -q "$repo"
git -C "$repo" config user.email "privacy-selftest@example.invalid"
git -C "$repo" config user.name "privacy-selftest"
git -C "$repo" config commit.gpgsign false
git -C "$repo" add .
git -C "$repo" commit -q -m "plant fake fixtures"

set +e
check_out=$(bash "$check" --repo "$repo" --all 2>"$tmp/check.err")
check_code=$?
gl_out=$(bash "$check" --repo "$repo" --all --gitleaks --config "$root/.gitleaks.toml" 2>"$tmp/gl.err")
gl_code=$?
set -e

if [[ -s "$tmp/check.err" || -s "$tmp/gl.err" ]]; then
  echo "unexpected-stderr" >&2
  exit 1
fi
if [[ "$check_code" -ne 1 || "$gl_code" -ne 1 ]]; then
  echo "expected-findings check=${check_code} gitleaks=${gl_code}" >&2
  exit 1
fi

assert_redacted() {
  local out="$1"
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^[^[:space:]]+:[0-9]+[[:space:]][A-Za-z0-9._-]+$ ]]; then
      echo "non-redacted-output" >&2
      exit 1
    fi
  done <<< "$out"
}

assert_no_raw_fixture() {
  local out="$1"
  local file line
  for file in "$root/scripts/privacy-fixtures"/*; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == *"/Users/"* || "$line" == *"PRIVATE KEY"* || "$line" == ghp_* || "$line" == *placeholder-not-a-password* ]]; then
        if printf '%s\n' "$out" | grep -F -q -- "$line"; then
          echo "raw-fixture-leaked" >&2
          exit 1
        fi
      fi
    done < "$file"
  done
}

require_finding() {
  local out="$1"
  local file="$2"
  local rule="$3"
  local escaped=${file//./\\.}
  if ! printf '%s\n' "$out" | grep -E -q "^${escaped}:[0-9]+ ${rule}$"; then
    echo "missing-finding ${file} ${rule}" >&2
    exit 1
  fi
}

assert_redacted "$check_out"
assert_redacted "$gl_out"
assert_no_raw_fixture "$check_out"
assert_no_raw_fixture "$gl_out"

require_finding "$check_out" "planted/fake-private-key.txt" "private-key"
require_finding "$check_out" "planted/fake-user-path.txt" "users-path"
require_finding "$check_out" "planted/fake-github-token.txt" "github-token"
require_finding "$check_out" "planted/keychain-password" "forbidden-filename"

require_finding "$gl_out" "planted/fake-private-key.txt" "private-key"
require_finding "$gl_out" "planted/fake-user-path.txt" "macos-user-path"
require_finding "$gl_out" "planted/fake-github-token.txt" "github-pat"
require_finding "$gl_out" "planted/keychain-password" "keychain-password-file"

if printf '%s\n' "$check_out" "$gl_out" | grep -F -q "clean/clean-users-path.txt"; then
  echo "clean-file-flagged" >&2
  exit 1
fi

# A home path added in one commit and removed in a later commit must still fail
# a range scan. The tree at HEAD is clean, so a head-only scan must pass.
range_repo="$tmp/range"
mkdir -p "$range_repo"
git init -q "$range_repo"
git -C "$range_repo" config user.email "privacy-selftest@example.invalid"
git -C "$range_repo" config user.name "privacy-selftest"
git -C "$range_repo" config commit.gpgsign false
printf '%s\n' "ok" > "$range_repo/ok.txt"
printf '%s\n' "notes" > "$range_repo/notes.txt"
git -C "$range_repo" add ok.txt notes.txt
git -C "$range_repo" commit -q -m "base"
range_base=$(git -C "$range_repo" rev-parse HEAD)
mkdir -p "$range_repo/scripts/privacy-fixtures/nested"
cp "$root/scripts/privacy-fixtures/fake-user-path.txt" "$range_repo/added-path.txt"
cp "$root/scripts/privacy-fixtures/fake-user-path.txt" "$range_repo/scripts/privacy-fixtures/fake-user-path.txt"
cp "$root/scripts/privacy-fixtures/fake-user-path.txt" "$range_repo/scripts/privacy-fixtures/nested/extra.txt"
printf '%s\n' "not-a-screenshot" > "$range_repo/shot.png"
printf '%s\n' "placeholder" > "$range_repo/.env.local"
git -C "$range_repo" add added-path.txt shot.png .env.local scripts
git -C "$range_repo" mv notes.txt .env
path_line=$(grep -F '/Users/' "$root/scripts/privacy-fixtures/fake-user-path.txt" | head -n 1)
git -C "$range_repo" commit -q -F - <<EOF
add fakes
${path_line}
EOF
add_commit=$(git -C "$range_repo" rev-parse HEAD)
git -C "$range_repo" rm -q -- added-path.txt shot.png .env.local .env scripts/privacy-fixtures/fake-user-path.txt scripts/privacy-fixtures/nested/extra.txt
git -C "$range_repo" commit -q -m "remove fakes"
range_head=$(git -C "$range_repo" rev-parse HEAD)
summary="$tmp/summary"

set +e
range_out=$(GITHUB_STEP_SUMMARY="$summary" bash "$check" --repo "$range_repo" --range "$range_base" "$range_head" 2>"$tmp/range.err")
range_code=$?
range_gl=$(bash "$check" --repo "$range_repo" --range "$range_base" "$range_head" --gitleaks --config "$root/.gitleaks.toml" 2>"$tmp/range-gl.err")
range_gl_code=$?
range_all=$(bash "$check" --repo "$range_repo" --all 2>"$tmp/range-all.err")
range_all_code=$?
range_all_gl=$(bash "$check" --repo "$range_repo" --all --gitleaks --config "$root/.gitleaks.toml" 2>"$tmp/range-all-gl.err")
range_all_gl_code=$?
set -e

if [[ -s "$tmp/range-gl.err" || -s "$tmp/range-all.err" || -s "$tmp/range-all-gl.err" ]]; then
  echo "range-stderr" >&2
  exit 1
fi
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if [[ ! "$line" =~ ^::warning\ file=.+:: ]]; then
    echo "range-stderr" >&2
    exit 1
  fi
done < "$tmp/range.err"
if ! grep -F -q "file=shot.png" "$tmp/range.err"; then
  echo "missing-warning-annotation" >&2
  exit 1
fi
if [[ "$range_code" -ne 1 || "$range_gl_code" -ne 1 ]]; then
  echo "range-should-fail check=${range_code} gitleaks=${range_gl_code}" >&2
  exit 1
fi
if [[ "$range_all_code" -ne 0 || "$range_all_gl_code" -ne 0 || -n "$range_all" || -n "$range_all_gl" ]]; then
  echo "head-scan-should-pass" >&2
  exit 1
fi
assert_redacted "$range_out"
assert_redacted "$range_gl"
assert_no_raw_fixture "$range_out"
assert_no_raw_fixture "$range_gl"
require_finding "$range_out" "added-path.txt" "users-path"
require_finding "$range_out" ".env.local" "forbidden-filename"
require_finding "$range_out" ".env" "forbidden-filename"
require_finding "$range_out" "scripts/privacy-fixtures/nested/extra.txt" "users-path"
require_finding "$range_out" "$add_commit" "users-path"
require_finding "$range_gl" "added-path.txt" "macos-user-path"
require_finding "$range_gl" "scripts/privacy-fixtures/nested/extra.txt" "macos-user-path"
if printf '%s\n' "$range_out" "$range_gl" | grep -F -q "scripts/privacy-fixtures/fake-user-path.txt"; then
  echo "exact-fixture-was-scanned" >&2
  exit 1
fi
if [[ ! -f "$summary" ]] || ! grep -F -q "shot.png" "$summary" || ! grep -F -q "Warning:" "$summary"; then
  echo "missing-image-warning" >&2
  exit 1
fi
if grep -F -q "/Users/" "$summary"; then
  echo "summary-leaked-path" >&2
  exit 1
fi

# The branch itself must stay clean under the production config.
set +e
real_check=$(bash "$check" --repo "$root" --all 2>"$tmp/real-check.err")
real_check_code=$?
real_gl=$(bash "$check" --repo "$root" --all --gitleaks 2>"$tmp/real-gl.err")
real_gl_code=$?
set -e
if [[ -s "$tmp/real-check.err" || -s "$tmp/real-gl.err" ]]; then
  echo "real-repo-stderr" >&2
  exit 1
fi
if [[ "$real_check_code" -ne 0 || "$real_gl_code" -ne 0 || -n "$real_check" || -n "$real_gl" ]]; then
  printf '%s\n' "$real_check" "$real_gl" >&2
  echo "real-repo-flagged" >&2
  exit 1
fi

echo "privacy-selftest-ok"
