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

# These exact paths are the self-test fixtures. A same-named file in any other
# directory is still scanned. Skipping also requires the fake marker in the blob.
fixture_marker="fake self-test fixture"

exact_fixture_path() {
  case "$1" in
    scripts/privacy-fixtures/fake-private-key.txt | \
      scripts/privacy-fixtures/fake-user-path.txt | \
      scripts/privacy-fixtures/fake-github-token.txt | \
      scripts/privacy-fixtures/keychain-password | \
      scripts/privacy-fixtures/clean-users-path.txt)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

blob_has_marker() {
  local rev=$1 file=$2
  if ! git cat-file -e "${rev}:${file}" 2>/dev/null; then
    return 1
  fi
  git show "${rev}:${file}" | grep -F -q -- "$fixture_marker"
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

  local report err code parsed scan_root archive
  report=$(mktemp)
  err=$(mktemp)
  archive=""
  scan_root=$repo
  # Full mode scans the HEAD tree, not the working directory or gitignored files.
  if [[ "$mode" != "range" ]]; then
    archive=$(mktemp -d)
    git archive HEAD | tar -x -C "$archive"
    scan_root=$archive
  fi
  cleanup() {
    rm -f "$report" "$err"
    if [[ -n "$archive" ]]; then
      rm -rf "$archive"
    fi
  }
  trap cleanup EXIT

  # Range mode scans every commit in base..head. Full mode scans the archived HEAD tree.
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
      .
    )
  fi

  set +e
  if [[ "$mode" == "range" ]]; then
    gitleaks "${args[@]}" >/dev/null 2>"$err"
    code=$?
  else
    # Scan from the archive root so reported paths stay repo-relative.
    (
      cd "$scan_root"
      gitleaks "${args[@]}" >/dev/null 2>"$err"
    )
    code=$?
  fi
  set -e
  if [[ "$code" -ne 0 && "$code" -ne 1 ]]; then
    echo "gitleaks-failed" >&2
    exit 2
  fi

  set +e
  python3 - "$report" "$scan_root" << 'PY'
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
    png | jpg | jpeg | gif | heic | heif | tiff | webp | bmp | pdf | mov | mp4 | webm | mkv) ;;
    *) return 0 ;;
  esac
  local safe
  safe=${file//%/%25}
  safe=${safe//$'\n'/%0A}
  safe=${safe//$'\r'/%0D}
  printf '%s\n' "::warning file=${safe}::Added file may contain screen contents. This warning does not fail the check." >&2
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  if [[ "$summary_started" -eq 0 ]]; then
    printf '%s\n' "### Privacy scan warnings" >> "$GITHUB_STEP_SUMMARY"
    summary_started=1
  fi
  printf '%s\n' "- Warning: \`${file}\` was added. Image, video, and document files may contain screen contents. This warning does not fail the check." >> "$GITHUB_STEP_SUMMARY"
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
  if exact_fixture_path "$file" && blob_has_marker "$scan_rev" "$file"; then
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

# Range mode reads every commit message and every added diff line. A path that
# is added and later removed is still a finding. Deleted lines are not.
if [[ "$mode" == "range" ]]; then
  diff_hits=$(
    git rev-list --reverse "${range_base}..${range_head}" | while IFS= read -r commit; do
      [[ -z "$commit" ]] && continue
      skip_paths=""
      for fixture in \
        scripts/privacy-fixtures/fake-private-key.txt \
        scripts/privacy-fixtures/fake-user-path.txt \
        scripts/privacy-fixtures/fake-github-token.txt \
        scripts/privacy-fixtures/keychain-password \
        scripts/privacy-fixtures/clean-users-path.txt
      do
        if blob_has_marker "$commit" "$fixture"; then
          skip_paths+="${fixture}"$'\n'
        fi
      done
      # %B is the commit message. -p appends the patch, including ^+ lines.
      git log -1 -m -p -U0 --no-color --format=%B "$commit" | awk -v commit="$commit" -v skip="$skip_paths" '
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
        function emit(where, lineno, text) {
          if (bad_home(text)) {
            print where ":" lineno " users-path"
          }
          if (text ~ /BEGIN [A-Z ]*PRIVATE KEY/) {
            print where ":" lineno " private-key"
          }
          if (text ~ /ghp_[A-Za-z0-9]{36}/) {
            print where ":" lineno " github-token"
          }
        }
        function skipped(path,    n, i, parts) {
          n = split(skip, parts, "\n")
          for (i = 1; i <= n; i++) {
            if (parts[i] == path) {
              return 1
            }
          }
          return 0
        }
        BEGIN { in_patch = 0; msgline = 0; file = ""; newline = 0 }
        in_patch == 0 && /^diff --git / {
          in_patch = 1
          file = ""
          newline = 0
          next
        }
        in_patch == 0 {
          msgline++
          if ($0 != "") {
            emit(commit, msgline, $0)
          }
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
          if (file != "" && !skipped(file) && newline > 0) {
            emit(file, newline, substr($0, 2))
          }
          if (newline > 0) {
            newline++
          }
          next
        }
      '
    done
  )
  if [[ -n "$diff_hits" ]]; then
    printf '%s\n' "$diff_hits"
    found=1
  fi

  added_tmp=$(mktemp)
  # --no-renames reports a rename as a delete plus an add, so git mv notes.txt .env is visible.
  git log --reverse --no-renames --diff-filter=A --name-only --pretty=format: "${range_base}..${range_head}" > "$added_tmp"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if exact_fixture_path "$file"; then
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
