#!/usr/bin/env bash
# Builds a throwaway git repo with obvious fakes and checks both detectors.
set -euo pipefail
export LC_ALL=C

root=$(git rev-parse --show-toplevel)
check="$root/scripts/privacy-check.sh"

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

cat "$root/.gitleaks.toml" "$root/scripts/privacy-fixtures/macos-user-path.toml" > "$tmp/gitleaks.toml"

set +e
check_out=$(bash "$check" --repo "$repo" --all 2>"$tmp/check.err")
check_code=$?
gl_out=$(bash "$check" --repo "$repo" --all --gitleaks --config "$tmp/gitleaks.toml" 2>"$tmp/gl.err")
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
