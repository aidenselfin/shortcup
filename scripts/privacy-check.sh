#!/usr/bin/env bash
# Shared privacy check for the workflow and the optional pre-push hook.
# Prints "path:line rule" (or "commit:line rule" for commit messages) and nothing
# from the matched text. Exit 0 clean, 1 findings, 2 usage, bad revision, or tool failure.
# Must run on bash 3.2 and the awk shipped with macOS.
set -euo pipefail
export LC_ALL=C

usage() {
  cat >&2 << 'EOF'
usage: privacy-check.sh [--repo DIR] [--gitleaks] [--config FILE] [--tree REV] MODE
modes:
  --all                     files in HEAD; with --gitleaks also every commit on every ref
  --range BASE HEAD         commits BASE..HEAD, files changed in BASE...HEAD
  --new-branch HEAD REMOTE  commits in HEAD not on REMOTE, every file in HEAD
  --ci                      choose a mode from the GitHub Actions event
--tree REV reads file contents from REV instead of HEAD of the mode.
--gitleaks runs gitleaks instead of the built-in check.
EOF
  exit 2
}

repo=""
use_gitleaks=0
config=""
mode=""
arg_base=""
arg_head=""
arg_remote=""
tree_override=""

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
    --tree)
      [[ $# -ge 2 ]] || usage
      tree_override=$2
      shift 2
      ;;
    --all)
      mode=all
      shift
      ;;
    --range)
      [[ $# -ge 3 ]] || usage
      mode=range
      arg_base=$2
      arg_head=$3
      shift 3
      ;;
    --new-branch)
      [[ $# -ge 3 ]] || usage
      mode=new-branch
      arg_head=$2
      arg_remote=$3
      shift 3
      ;;
    --ci)
      mode=ci
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$mode" ]] || usage

if [[ -z "$repo" ]]; then
  repo=$(git rev-parse --show-toplevel)
fi
repo=$(cd "$repo" && pwd)
cd "$repo"

if [[ -z "$config" && -f "$repo/.gitleaks.toml" ]]; then
  config="$repo/.gitleaks.toml"
fi

zero_re='^0+$'

have_commit() {
  [[ -n "$1" && "$1" != -* ]] && git cat-file -e "${1}^{commit}" 2> /dev/null
}

resolve_commit() {
  local sha
  if ! have_commit "$1" || ! sha=$(git rev-parse --verify -q "${1}^{commit}"); then
    echo "missing-revision" >&2
    exit 2
  fi
  printf '%s\n' "$sha"
}

default_branch_base() {
  local ref branch=${DEFAULT_BRANCH:-main}
  for ref in \
    "refs/remotes/origin/${branch}" \
    "origin/${branch}" \
    refs/remotes/origin/main \
    origin/main \
    refs/remotes/origin/HEAD
  do
    if have_commit "$ref"; then
      git merge-base "$ref" "$1" 2> /dev/null || true
      return 0
    fi
  done
}

# Scan plan. history=1 means rev_args names the commits to scan; the file list is
# either the diff base...head or the full tree of head; contents come from scan_rev.
history=0
rev_args=()
files_kind=""
files_base=""
files_head=""
scan_rev=""
empty_ok=0

plan_range() {
  history=1
  rev_args=("${1}..${2}")
  files_kind=diff
  files_base=$1
  files_head=$2
  scan_rev=$2
}

plan_tree() {
  files_kind=tree
  files_head=$1
  scan_rev=$1
}

if [[ "$mode" == "ci" ]]; then
  case "${GITHUB_EVENT_NAME-}" in
    workflow_dispatch)
      mode=all
      ;;
    pull_request)
      base=$(resolve_commit "${PR_BASE-}")
      head=$(resolve_commit "${PR_HEAD-}")
      merge=$(resolve_commit "${GITHUB_SHA-}")
      mode=range
      plan_range "$base" "$head"
      # Contents come from the merge result; the file list from base...head.
      scan_rev=$merge
      ;;
    push)
      head=$(resolve_commit "${RANGE_AFTER-}")
      before=${RANGE_BEFORE-}
      mode=range
      empty_ok=1
      if [[ -n "$before" && ! "$before" =~ $zero_re ]] && have_commit "$before" &&
        git merge-base --is-ancestor "$before" "$head"; then
        plan_range "$(resolve_commit "$before")" "$head"
      else
        # New branch or force push: everything since the default branch.
        base=$(default_branch_base "$head")
        if [[ -n "$base" ]]; then
          echo "note: range from default branch merge-base" >&2
          plan_range "$(resolve_commit "$base")" "$head"
        else
          echo "note: no merge-base, scanning every commit of head" >&2
          history=1
          rev_args=("$head")
          plan_tree "$head"
        fi
      fi
      ;;
    *)
      echo "unsupported-event" >&2
      exit 2
      ;;
  esac
elif [[ "$mode" == "range" ]]; then
  base=$(resolve_commit "$arg_base")
  head=$(resolve_commit "$arg_head")
  plan_range "$base" "$head"
elif [[ "$mode" == "new-branch" ]]; then
  head=$(resolve_commit "$arg_head")
  if [[ -z "$arg_remote" || "$arg_remote" == -* ]]; then
    usage
  fi
  history=1
  rev_args=("$head" --not "--remotes=${arg_remote}")
  plan_tree "$head"
  mode=range
  empty_ok=1
else
  plan_tree "$(resolve_commit HEAD)"
fi

if [[ -n "$tree_override" ]]; then
  scan_rev=$(resolve_commit "$tree_override")
fi

commit_count=0
if [[ "$history" -eq 1 ]]; then
  commit_count=$(git rev-list --count "${rev_args[@]}")
  if [[ "$commit_count" -eq 0 ]]; then
    if [[ "$empty_ok" -ne 1 ]]; then
      echo "empty-range" >&2
      exit 2
    fi
    # A pushed branch with no new commits: nothing new to read in history, so
    # scan its whole tree instead.
    echo "note: no new commits, scanning the head tree" >&2
    history=0
    plan_tree "$files_head"
    if [[ -n "$tree_override" ]]; then
      scan_rev=$(resolve_commit "$tree_override")
    fi
  fi
fi

work=$(mktemp -d)
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

# Self-test fixtures: exact paths only, and a line is skipped only when it carries
# the fake marker itself. Same rule as the fixture allowlist in .gitleaks.toml.
# keychain-password and fake-github-token.txt are not in HEAD; they exist only in
# the first commits of this check and stay listed so those commits can skip them.
fixture_marker="fake self-test fixture"
fixture_paths="scripts/privacy-fixtures/fake-private-key.txt
scripts/privacy-fixtures/fake-user-path.txt
scripts/privacy-fixtures/fake-device-name.txt
scripts/privacy-fixtures/clean-users-path.txt
scripts/privacy-fixtures/keychain-password
scripts/privacy-fixtures/fake-github-token.txt"

# Commits of this check written before the current fixture rules. "fixture" skips a
# fixture path whose blob has the marker (one marker per file back then); any other
# entry skips that exact path in that exact commit.
legacy_paths="94d496732e60e1551155b01aea4ec3ca5b2b2d04 fixture
2542ec18fff050c167074836f8120369f5cd28d0 fixture
e02dcd713c1e20ce619e5961da4a585dd918d36b scripts/privacy-check-selftest.sh
e02dcd713c1e20ce619e5961da4a585dd918d36b .gitleaks.toml"

# Public history from before this check. Only the named rule is ignored, and only
# for that exact commit. Mirrored in .gitleaks.toml.
historical_allow="d8001e780038c391f69367999cc41cbe9336dafa users-path
6ef593ad25b96559b67dde593ffc5bd978689d16 users-path
ae5c13d06ac9670c96955ece48257abdf88b9e84 owner-device
f7c8745f7cc94f03a33b3df5167a1f76ee8dcfa1 owner-device
c5e8e8b546bd72ae9211f84afb922d09c72cbc48 owner-device"

legacy_skips() {
  local commit=$1 sha entry path
  while read -r sha entry; do
    [[ "$sha" == "$commit" ]] || continue
    if [[ "$entry" != fixture ]]; then
      printf '%s\n' "$entry"
      continue
    fi
    while IFS= read -r path; do
      if [[ "$(git cat-file -t "${commit}:${path}" 2> /dev/null)" == blob ]] &&
        git cat-file blob "${commit}:${path}" > "$work/legacy" &&
        grep -F -q -- "$fixture_marker" "$work/legacy"; then
        printf '%s\n' "$path"
      fi
    done <<< "$fixture_paths"
  done <<< "$legacy_paths"
}

allowed_rules() {
  local commit=$1 sha rule
  while read -r sha rule; do
    if [[ "$sha" == "$commit" ]]; then
      printf '%s ' "$rule"
    fi
  done <<< "$historical_allow"
}

read -r -d '' awk_lib << 'AWK' || true
function trim_name(seg) {
  sub(/\.+$/, "", seg)
  return tolower(seg)
}
function users_hit(text,    rest, seg, name) {
  rest = text
  while (match(rest, /[\/\\]+[Uu][Ss][Ee][Rr][Ss][\/\\]+[^ \t\/\\"'<>:;,|(){}*$?=&#%!@+~`[]+/)) {
    seg = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/^[\/\\]+[Uu][Ss][Ee][Rr][Ss][\/\\]+/, "", seg)
    name = trim_name(seg)
    if (name != "" && name != "runner" && name != "shared") {
      return 1
    }
  }
  return 0
}
function home_hit(text,    rest, seg, name) {
  rest = text
  while (match(rest, /[\/\\]+[Hh][Oo][Mm][Ee][\/\\]+[^ \t\/\\"'<>:;,|(){}*$?=&#%!@+~`[]+/)) {
    seg = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/^[\/\\]+[Hh][Oo][Mm][Ee][\/\\]+/, "", seg)
    name = trim_name(seg)
    if (name != "" && name != "runner") {
      return 1
    }
  }
  return 0
}
function token_hit(text,    rest) {
  rest = text
  while (match(rest, /ghp_[A-Za-z0-9]+/)) {
    if (RLENGTH >= 40) {
      return 1
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  return 0
}
function in_list(list, item,    n, i, parts) {
  n = split(list, parts, "\n")
  for (i = 1; i <= n; i++) {
    if (parts[i] != "" && parts[i] == item) {
      return 1
    }
  }
  return 0
}
function say(where, n, rule) {
  if (index(" " allow " ", " " rule " ") == 0) {
    print where ":" n " " rule
  }
}
function report(where, n, text) {
  if (in_list(legacy, where)) return
  if (in_list(fixtures, where) && index(text, marker) > 0) return
  if (users_hit(text)) say(where, n, "users-path")
  if (home_hit(text)) say(where, n, "home-path")
  if (text ~ /(의|'s|’s) (Mac|MacBook|iMac|iPhone|iPad)/) say(where, n, "owner-device")
  if (tolower(text) ~ /[a-z0-9]+-(macbook|imac|mac-mini|mac-studio)(-pro|-air)?(\.local)?/) say(where, n, "host-device")
  if (text ~ /BEGIN [A-Z ]*PRIVATE KEY/) say(where, n, "private-key")
  if (token_hit(text)) say(where, n, "github-token")
}
function name_rules(path,    lower, base) {
  if (in_list(legacy, path)) return
  lower = tolower(path)
  base = lower
  sub(/.*\//, "", base)
  if (("/" lower) ~ /\/\.config\/shortcup\// || ("/" lower) ~ /\/xcuserdata\// ||
    base ~ /\.(p12|pem|key|cer|p8|pfx|mobileprovision|provisionprofile|keychain|keychain-db|certsigningrequest)$/ ||
    base == "keychain-password" || base == ".env" || base ~ /^\.env\./) {
    say(path, 1, "forbidden-filename")
  }
  if (base ~ /^validation-(events|state|results)/ || ("/" lower) ~ /\/validation-fixtures\//) {
    say(path, 1, "runtime-output")
  }
  if (users_hit("/" path)) say(path, 1, "users-path-in-name")
  if (home_hit("/" path)) say(path, 1, "home-path-in-name")
}
AWK

# Values go through ENVIRON because awk -v would rewrite backslashes in file names.
run_awk() {
  local body=$4
  PC_FIXTURES=$fixture_paths PC_MARKER=$fixture_marker PC_LEGACY=$1 PC_ALLOW=$2 PC_WHERE=$3 \
    awk "${awk_lib}
BEGIN {
  fixtures = ENVIRON[\"PC_FIXTURES\"]
  marker = ENVIRON[\"PC_MARKER\"]
  legacy = ENVIRON[\"PC_LEGACY\"]
  allow = ENVIRON[\"PC_ALLOW\"]
  where = ENVIRON[\"PC_WHERE\"]
}
${body}" "${@:5}"
}

# Path segments after users/ or home/ are replaced before anything is printed.
redact() {
  sed -E 's#(^|[/\\])([Uu][Ss][Ee][Rr][Ss]|[Hh][Oo][Mm][Ee])([/\\]+)[^/\\:]+#\1\2\3<redacted>#g'
}

found_file="$work/found"
: > "$found_file"

list_files() {
  if [[ "$files_kind" == diff ]]; then
    git diff --name-only -z --no-renames --diff-filter=d "${files_base}...${files_head}"
  else
    git ls-tree -r -z --name-only "$files_head"
  fi
}
list_files > "$work/files"

# UTF-16 with a BOM becomes UTF-8. Other blobs drop NUL so a binary patch is text.
decode_blob() {
  local rev=$1 file=$2 dest=$3 bom
  git cat-file blob "${rev}:${file}" > "$work/blob"
  bom=$(head -c 2 "$work/blob" | od -An -tx1 | tr -d ' \n')
  if [[ "$bom" == fffe || "$bom" == feff ]] &&
    iconv -f UTF-16 -t UTF-8 < "$work/blob" > "$dest" 2> /dev/null; then
    return 0
  fi
  tr -d '\000' < "$work/blob" > "$dest"
}

# gitleaks exits 1 on its own errors too, so leaks get a distinct code.
leak_code=77

parse_report() {
  python3 - "$1" << 'PY'
import json
import os
import sys

path = sys.argv[1]
if not os.path.isfile(path):
    sys.exit(2)
try:
    with open(path) as handle:
        data = json.load(handle)
except Exception:
    sys.exit(2)
if not isinstance(data, list):
    sys.exit(2)
for item in data:
    if not isinstance(item, dict):
        sys.exit(2)
    name = str(item.get("File") or "")
    if name.startswith("./"):
        name = name[2:]
    try:
        line = max(int(item.get("StartLine") or 1), 1)
    except (TypeError, ValueError):
        line = 1
    rule = str(item.get("RuleID") or "unknown")
    if not name or any(c in name for c in "\n\r") or any(c in rule for c in "\n\r \t"):
        name = "<unprintable>"
    sys.stdout.write(f"{name}:{line} {rule}\n")
PY
}

# Any exit code other than 0 or leak_code, any ERR log line, an unreadable report,
# a report that disagrees with the exit code, or a history scan of 0 commits is a
# tool failure (exit 2), never a pass.
run_one_gitleaks() {
  local report=$1 expect_commits=$2 code n scanned
  shift 2
  set +e
  gitleaks "$@" --no-banner --redact --no-color --exit-code "$leak_code" \
    --report-format json --report-path "$report" --config "$config" > /dev/null 2> "$work/gitleaks.err"
  code=$?
  set -e
  if [[ "$code" -ne 0 && "$code" -ne "$leak_code" ]]; then
    echo "gitleaks-failed" >&2
    exit 2
  fi
  if grep -E -q '(^|[[:space:]])ERR([[:space:]]|$)' "$work/gitleaks.err"; then
    echo "gitleaks-error-log" >&2
    exit 2
  fi
  if [[ "$expect_commits" -gt 0 ]]; then
    scanned=$(sed -n -E 's/.*[[:space:]]([0-9]+) commits scanned.*/\1/p' "$work/gitleaks.err" | tail -n 1)
    if [[ -z "$scanned" || "$scanned" -eq 0 ]]; then
      echo "gitleaks-scanned-no-commits" >&2
      exit 2
    fi
  fi
  if ! parse_report "$report" > "$work/parsed"; then
    echo "gitleaks-report-unreadable" >&2
    exit 2
  fi
  n=$(wc -l < "$work/parsed" | tr -d ' ')
  if [[ "$code" -eq 0 && "$n" -ne 0 ]] || [[ "$code" -eq "$leak_code" && "$n" -eq 0 ]]; then
    echo "gitleaks-report-mismatch" >&2
    exit 2
  fi
  cat "$work/parsed" >> "$found_file"
}

run_gitleaks() {
  if ! command -v gitleaks > /dev/null 2>&1; then
    echo "gitleaks-not-found" >&2
    exit 2
  fi
  if ! command -v python3 > /dev/null 2>&1; then
    echo "python3-not-found" >&2
    exit 2
  fi
  if [[ -z "$config" || ! -f "$config" ]]; then
    echo "gitleaks-config-missing" >&2
    exit 2
  fi
  config=$(cd "$(dirname "$config")" && pwd)/$(basename "$config")

  # History. -m shows each merge against every parent, so content that exists only
  # in a merge commit is scanned too. --no-renames makes a pure rename an add, so
  # path rules see the new name.
  # --text so a blob with NUL is a patch, not "Binary files differ". Without it
  # gitleaks reports 0 commits for a PNG-only change and the check would error.
  if [[ "$mode" == all ]]; then
    run_one_gitleaks "$work/history.json" "$(git rev-list --count --all)" \
      git --log-opts="--all --text -m --no-renames" "$repo"
  elif [[ "$history" -eq 1 ]]; then
    run_one_gitleaks "$work/history.json" "$commit_count" \
      git --log-opts="--text -m --no-renames ${rev_args[*]}" "$repo"
  fi

  # Tree. The listed files as they are in scan_rev (the merge result on PRs),
  # never the working directory. Decode so UTF-16 and NUL blobs are readable.
  local tree="$work/tree" file commit
  mkdir -p "$tree"
  while IFS= read -r -d '' file; do
    [[ "$(git cat-file -t "${scan_rev}:${file}" 2> /dev/null)" == blob ]] || continue
    mkdir -p "$tree/$(dirname "$file")"
    decode_blob "$scan_rev" "$file" "$tree/$file"
  done < "$work/files"
  (
    cd "$tree"
    run_one_gitleaks "$work/tree.json" 0 dir .
  )

  # Range only: blobs that git log still hides (UTF-16), as a tree so names stay
  # repo-relative. Not used in --all, where a flattened tree would drop the
  # commit-SHA allowlist and re-flag historical files.
  if [[ "$history" -eq 1 ]]; then
    local decoded="$work/decoded"
    mkdir -p "$decoded"
    git rev-list "${rev_args[@]}" > "$work/commits"
    while IFS= read -r commit; do
      [[ -n "$commit" ]] || continue
      git diff-tree -z -r -m --root --no-commit-id --no-renames --diff-filter=A --name-only "$commit" > "$work/added"
      while IFS= read -r -d '' file; do
        [[ -n "$file" ]] || continue
        [[ "$(git cat-file -t "${commit}:${file}" 2> /dev/null)" == blob ]] || continue
        mkdir -p "$decoded/${commit}/$(dirname "$file")"
        decode_blob "$commit" "$file" "$decoded/${commit}/${file}"
      done < "$work/added"
    done < "$work/commits"
    if [[ -n "$(find "$decoded" -type f -print -quit 2> /dev/null)" ]]; then
      (
        cd "$decoded"
        run_one_gitleaks "$work/decoded.json" 0 dir .
      )
      # Findings keep repo-relative names; the commit directory is only storage.
      if [[ -s "$found_file" ]]; then
        sed -E 's#^[0-9a-f]{40}/##' "$found_file" > "$work/stripped" && mv "$work/stripped" "$found_file"
      fi
    fi
  fi
}

is_media() {
  local ext
  [[ "$1" == *.* ]] || return 1
  ext=$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    png | jpg | jpeg | gif | heic | heif | tiff | webp | bmp | pdf | mov | mp4 | webm | mkv) return 0 ;;
    *) return 1 ;;
  esac
}

summary_started=0
warn_media() {
  local safe
  safe=$(printf '%s\n' "$1" | redact)
  safe=${safe//%/%25}
  safe=${safe//$'\r'/%0D}
  safe=${safe//,/%2C}
  safe=${safe//::/%3A%3A}
  printf '%s\n' "::warning file=${safe}::Added image, video, or PDF may contain screen contents. Warning only." >&2
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  if [[ "$summary_started" -eq 0 ]]; then
    printf '%s\n' "### Privacy scan warnings" >> "$GITHUB_STEP_SUMMARY"
    summary_started=1
  fi
  printf '%s\n' "- Warning: \`${safe}\` was added. Image, video, and PDF files may contain screen contents. This does not fail the check." >> "$GITHUB_STEP_SUMMARY"
}

builtin_check() {
  local file kind bom commit legacy allow

  # Files: names, then contents as of scan_rev. NUL bytes are dropped and UTF-16
  # with a BOM is converted, so binary and UTF-16 files are still read.
  tr '\000' '\n' < "$work/files" | run_awk "" "" "" '{ name_rules($0) }' >> "$found_file"

  while IFS= read -r -d '' file; do
    kind=$(git cat-file -t "${scan_rev}:${file}" 2> /dev/null || true)
    [[ "$kind" == blob ]] || continue
    decode_blob "$scan_rev" "$file" "$work/text"
    run_awk "" "" "$file" '{ report(where, FNR, $0) }' "$work/text" >> "$found_file"
  done < "$work/files"

  # Full mode also reads every commit message. File contents stay the HEAD tree.
  if [[ "$mode" == all ]]; then
    git rev-list --all > "$work/commits"
    while IFS= read -r commit; do
      [[ -n "$commit" ]] || continue
      allow=$(allowed_rules "$commit")
      git log -1 --format=%B "$commit" | tr -d '\000' |
        run_awk "" "$allow" "$commit" '$0 != "" { report(where, FNR, $0) }' >> "$found_file"
    done < "$work/commits"
    return 0
  fi

  [[ "$history" -eq 1 ]] || return 0

  # Commits: every message and every added line, merges against each parent.
  # A line added and removed again inside the range is still a finding.
  git rev-list --reverse "${rev_args[@]}" > "$work/commits"
  local warned=$'\n'
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    legacy=$(legacy_skips "$commit")
    allow=$(allowed_rules "$commit")

    git log -1 --format=%B "$commit" | tr -d '\000' |
      run_awk "" "$allow" "$commit" '$0 != "" { report(where, FNR, $0) }' >> "$found_file"

    # Headers are read only until the first @@ of each file, so an added line whose
    # text looks like "++ /dev/null" is still treated as content.
    git -c core.quotePath=false log -1 -m -p -U0 --text --no-color --no-ext-diff --format= "$commit" |
      tr -d '\000' |
      run_awk "$legacy" "$allow" "" '
        /^diff --git / { file = ""; header = 1; newline = 0; next }
        header == 1 && /^\+\+\+ / {
          file = substr($0, 5)
          sub(/^b\//, "", file)
          if (file == "/dev/null") {
            file = ""
          }
          next
        }
        /^@@ / {
          header = 0
          newline = 0
          if (match($0, /\+[0-9]+/)) {
            newline = substr($0, RSTART + 1, RLENGTH - 1) + 0
          }
          next
        }
        header == 1 { next }
        /^\+/ {
          if (file != "" && newline > 0) {
            report(file, newline, substr($0, 2))
          }
          if (newline > 0) {
            newline++
          }
        }
      ' >> "$found_file"

    # Added names of this commit only (git log --diff-filter would walk back to an
    # earlier commit). --no-renames turns a rename into delete plus add, -m covers
    # each merge parent, and -z keeps non-ASCII names unquoted.
    git diff-tree -z -r -m --root --no-commit-id --no-renames --diff-filter=A --name-only "$commit" > "$work/added"
    tr '\000' '\n' < "$work/added" |
      run_awk "$legacy" "$allow" "" '$0 != "" { name_rules($0) }' >> "$found_file"

    while IFS= read -r -d '' file; do
      [[ -n "$file" ]] || continue
      case "$warned" in
        *$'\n'"$file"$'\n'*) continue ;;
      esac
      if is_media "$file"; then
        warned+="$file"$'\n'
        warn_media "$file"
      fi
    done < "$work/added"
  done < "$work/commits"
}

if [[ "$use_gitleaks" -eq 1 ]]; then
  run_gitleaks
else
  builtin_check
fi

if [[ -s "$found_file" ]]; then
  redact < "$found_file" | awk '!seen[$0]++'
  exit 1
fi
exit 0
