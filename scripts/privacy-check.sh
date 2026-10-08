#!/usr/bin/env bash
# Shared privacy check for the workflow and the optional pre-push hook.
# Prints "path:line rule" and nothing from the matched line.
# Exit 0 clean, 1 findings, 2 usage or tool failure.
set -euo pipefail
export LC_ALL=C

usage() {
  echo "usage: privacy-check.sh [--repo DIR] [--gitleaks] [--config FILE] (--all | --range BASE HEAD | --ci)" >&2
  exit 2
}

repo=""
use_gitleaks=0
config=""
mode=""
range_base=""
range_head=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || usage
      repo=$2
      shift 2
      ;;
    --gitleaks)
      use_gitleaks=1
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || usage
      config=$2
      shift 2
      ;;
    --all)
      mode=all
      shift
      ;;
    --range)
      [[ $# -ge 3 ]] || usage
      mode=range
      range_base=$2
      range_head=$3
      shift 3
      ;;
    --ci)
      mode=ci
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$mode" ]]; then
  usage
fi

if [[ -z "$repo" ]]; then
  repo=$(git rev-parse --show-toplevel)
fi
repo=$(cd "$repo" && pwd)
cd "$repo"

if [[ -z "$config" && -f "$repo/.gitleaks.toml" ]]; then
  config="$repo/.gitleaks.toml"
fi

sha_ok() {
  [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

if [[ "$mode" == "ci" ]]; then
  event=${GITHUB_EVENT_NAME-}
  case "$event" in
    workflow_dispatch)
      mode=all
      ;;
    pull_request)
      range_base=${PR_BASE-}
      range_head=${PR_HEAD-}
      mode=range
      ;;
    push)
      before=${RANGE_BEFORE-}
      after=${RANGE_AFTER-}
      if [[ -z "$before" || "$before" =~ ^0+$ ]]; then
        mode=all
      else
        range_base=$before
        range_head=$after
        mode=range
      fi
      ;;
    *)
      echo "unsupported-event" >&2
      exit 2
      ;;
  esac
fi

if [[ "$mode" == "range" ]]; then
  if ! sha_ok "$range_base" || ! sha_ok "$range_head"; then
    echo "bad-revision" >&2
    exit 2
  fi
elif [[ "$mode" != "all" ]]; then
  usage
fi

is_fixture() {
  case "$1" in
    scripts/privacy-fixtures | scripts/privacy-fixtures/*) return 0 ;;
    *) return 1 ;;
  esac
}

run_gitleaks() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "gitleaks-not-found" >&2
    exit 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3-not-found" >&2
    exit 2
  fi
  if [[ -z "$config" || ! -f "$config" ]]; then
    echo "gitleaks-config-missing" >&2
    exit 2
  fi

  local report err code parsed
  report=$(mktemp)
  err=$(mktemp)
  cleanup() {
    rm -f "$report" "$err"
  }
  trap cleanup EXIT

  # Range mode scans every commit in base..head. Full-history mode scans the
  # tree at HEAD only, so a path that was added and later removed is not a hit.
  local -a args=()
  if [[ "$mode" == "range" ]]; then
    args=(
      git
      --no-banner
      --redact
      --no-color
      --exit-code 1
      --report-format json
      --report-path "$report"
      --config "$config"
      --log-opts="${range_base}..${range_head}"
    )
  else
    args=(
      dir
      --no-banner
      --redact
      --no-color
      --exit-code 1
      --report-format json
      --report-path "$report"
      --config "$config"
      "$repo"
    )
  fi

  set +e
  gitleaks "${args[@]}" >/dev/null 2>"$err"
  code=$?
  set -e
  if [[ "$code" -ne 0 && "$code" -ne 1 ]]; then
    echo "gitleaks-failed" >&2
    exit 2
  fi

  set +e
  python3 - "$report" "$repo" << 'PY'
import json
import os
import sys

path, root = sys.argv[1], sys.argv[2]
data = []
if os.path.isfile(path) and os.path.getsize(path) > 0:
    try:
        loaded = json.load(open(path))
    except Exception:
        sys.exit(2)
    if isinstance(loaded, list):
        data = loaded

count = 0
for item in data:
    if not isinstance(item, dict):
        continue
    name = str(item.get("File") or "")
    prefix = root + "/"
    if name.startswith(prefix):
        name = name[len(prefix) :]
    if name.startswith("./"):
        name = name[2:]
    try:
        line = int(item.get("StartLine") or 1)
    except (TypeError, ValueError):
        line = 1
    if line < 1:
        line = 1
    rule = str(item.get("RuleID") or "unknown")
    if not name or any(char in name for char in "\n\r") or any(char in rule for char in "\n\r \t"):
        continue
    sys.stdout.write(f"{name}:{line} {rule}\n")
    count += 1
sys.exit(1 if count else 0)
PY
  parsed=$?
  set -e
  cleanup
  trap - EXIT

  if [[ "$parsed" -eq 2 ]]; then
    echo "gitleaks-report-unreadable" >&2
    exit 2
  fi
  if [[ "$parsed" -eq 1 || "$code" -eq 1 ]]; then
    exit 1
  fi
  if [[ "$parsed" -ne 0 ]]; then
    echo "gitleaks-report-unreadable" >&2
    exit 2
  fi
  exit 0
}

if [[ "$use_gitleaks" -eq 1 ]]; then
  run_gitleaks
fi

scan_rev=HEAD
if [[ "$mode" == "range" ]]; then
  scan_rev=$range_head
fi

summary_started=0
warn_image() {
  local file=$1
  local base ext
  base=${file##*/}
  ext=""
  case "$base" in
    *.*) ext=${base##*.} ;;
    *) return 0 ;;
  esac
  ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    png | jpg | jpeg | gif | heic | tiff | mov | mp4) ;;
    *) return 0 ;;
  esac
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  if [[ "$summary_started" -eq 0 ]]; then
    printf '%s\n' "### Privacy scan warnings" >> "$GITHUB_STEP_SUMMARY"
    summary_started=1
  fi
  printf '%s\n' "- Warning: \`${file}\` was added. Image and video files may contain screen contents. This warning does not fail the check." >> "$GITHUB_STEP_SUMMARY"
}

classify_name() {
  local base=$1
  local lower
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.p12 | *.pem | *.key | *.cer | *.p8 | *.pfx | *.mobileprovision | *.provisionprofile | *.keychain-db | keychain-password | .env | .env.*)
      printf '%s\n' "forbidden-filename"
      ;;
    validation-events.jsonl | validation-state.json | validation-results.json)
      printf '%s\n' "runtime-output"
      ;;
  esac
}

list_tmp=$(mktemp)
cleanup_list() {
  rm -f "$list_tmp"
}
trap cleanup_list EXIT
if [[ "$mode" == "all" ]]; then
  git ls-files -z > "$list_tmp"
else
  git diff --name-only --diff-filter=d -z "$range_base" "$range_head" > "$list_tmp"
fi

found=0
while IFS= read -r -d '' file; do
  if is_fixture "$file"; then
    continue
  fi

  rule=$(classify_name "${file##*/}")
  if [[ -n "$rule" ]]; then
    printf '%s\n' "${file}:1 ${rule}"
    found=1
  fi

  if ! git cat-file -e "${scan_rev}:${file}" 2>/dev/null; then
    continue
  fi
  # A NUL delimiter means the blob is binary. Do not pass a NUL pattern to grep;
  # grep treats it as an empty pattern and would skip every text file.
  if git show "${scan_rev}:${file}" | { IFS= read -r -d '' _; }; then
    continue
  fi

  hits=$(
    git show "${scan_rev}:${file}" | awk -v file="$file" '
      {
        rest = $0
        bad = 0
        while (match(rest, /\/Users\/[A-Za-z0-9._-]+/)) {
          name = substr(rest, RSTART + 7, RLENGTH - 7)
          if (name != "runner" && name != "Shared") {
            bad = 1
          }
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (bad) {
          print file ":" FNR " users-path"
        }
        if ($0 ~ /BEGIN [A-Z ]*PRIVATE KEY/) {
          print file ":" FNR " private-key"
        }
        if ($0 ~ /ghp_[A-Za-z0-9]{36}/) {
          print file ":" FNR " github-token"
        }
      }
    '
  )
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    found=1
  fi
done < "$list_tmp"

# Range mode also reads every commit patch. A path added and later removed is
# still a finding. Only added lines count, so deleting one is not a finding.
if [[ "$mode" == "range" ]]; then
  diff_hits=$(
    git log --reverse -m -U0 --no-color --format= "${range_base}..${range_head}" | awk '
      function bad_home(text,    rest, name) {
        rest = text
        while (match(rest, /\/Users\/[A-Za-z0-9._-]+/)) {
          name = substr(rest, RSTART + 7, RLENGTH - 7)
          if (name != "runner" && name != "Shared") {
            return 1
          }
          rest = substr(rest, RSTART + RLENGTH)
        }
        return 0
      }
      function fixture(path) {
        return path == "scripts/privacy-fixtures" || index(path, "scripts/privacy-fixtures/") == 1
      }
      /^diff --git / {
        file = ""
        newline = 0
        next
      }
      /^\+\+\+ / {
        file = substr($0, 5)
        sub(/^b\//, "", file)
        if (file == "/dev/null") {
          file = ""
        }
        next
      }
      /^@@ / {
        if (match($0, /\+[0-9]+/)) {
          newline = substr($0, RSTART + 1, RLENGTH - 1) + 0
        }
        next
      }
      /^\+/ {
        if (file != "" && !fixture(file) && newline > 0 && bad_home(substr($0, 2))) {
          print file ":" newline " users-path"
        }
        if (newline > 0) {
          newline++
        }
        next
      }
    '
  )
  if [[ -n "$diff_hits" ]]; then
    printf '%s\n' "$diff_hits"
    found=1
  fi

  added_tmp=$(mktemp)
  git log --reverse --diff-filter=A --name-only --pretty=format: "${range_base}..${range_head}" > "$added_tmp"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if is_fixture "$file"; then
      continue
    fi
    rule=$(classify_name "${file##*/}")
    if [[ -n "$rule" ]]; then
      printf '%s\n' "${file}:1 ${rule}"
      found=1
    fi
    warn_image "$file"
  done < "$added_tmp"
  rm -f "$added_tmp"
fi

cleanup_list
trap - EXIT
exit "$found"
