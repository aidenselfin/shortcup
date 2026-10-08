#!/usr/bin/env bash
# Installs a repository-local pre-push hook that runs the privacy check on the
# commits being pushed. Never writes git config, global or local.
# The scanner and gitleaks config are copied into the hooks directory, so the hook
# also works when pushing branches that do not contain scripts/.
set -euo pipefail

usage() {
  echo "usage: install-pre-push-hook.sh [--force]" >&2
  exit 2
}

force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

src=$(cd "$(dirname "$0")" && pwd)
scanner="$src/privacy-check.sh"
config="$src/../.gitleaks.toml"
if [[ ! -f "$scanner" || ! -f "$config" ]]; then
  echo "privacy-check.sh or .gitleaks.toml not found next to this script" >&2
  exit 1
fi

git rev-parse --git-dir > /dev/null
# The common dir is shared by every worktree, so one install covers all of them.
common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
hooks="$common/hooks"

if git config --get core.hooksPath > /dev/null 2>&1; then
  echo "warning: core.hooksPath is set, so git runs hooks from that directory and will not run this one." >&2
  echo "warning: this script does not change core.hooksPath." >&2
fi

if [[ -e "$hooks/pre-push" && "$force" -ne 1 ]]; then
  echo "a pre-push hook already exists; not replacing it. Rerun with --force to replace it." >&2
  exit 1
fi

mkdir -p "$hooks"
cp "$scanner" "$hooks/shortcup-privacy-check.sh"
cp "$config" "$hooks/shortcup-gitleaks.toml"

cat > "$hooks/pre-push.tmp" << 'EOF'
#!/usr/bin/env bash
# shortcup privacy pre-push hook (installed by scripts/install-pre-push-hook.sh)
set -euo pipefail

remote=${1:-origin}
hooks=$(cd "$(dirname "$0")" && pwd)
check="$hooks/shortcup-privacy-check.sh"
config="$hooks/shortcup-gitleaks.toml"
if [[ ! -f "$check" || ! -f "$config" ]]; then
  echo "privacy hook: scanner copy is missing; rerun scripts/install-pre-push-hook.sh --force" >&2
  exit 1
fi

use_gitleaks=1
if ! command -v gitleaks > /dev/null 2>&1; then
  if [[ "${SHORTCUP_PRIVACY_SKIP_GITLEAKS:-}" == 1 ]]; then
    echo "warning: gitleaks not found; skipping it because SHORTCUP_PRIVACY_SKIP_GITLEAKS=1" >&2
    use_gitleaks=0
  else
    echo "privacy hook: gitleaks not found. Install it, or set SHORTCUP_PRIVACY_SKIP_GITLEAKS=1 to push without it." >&2
    exit 1
  fi
fi

zero='^0+$'
status=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [[ -n "${local_sha:-}" ]] || continue
  # Branch deletion: nothing is published.
  [[ "$local_sha" =~ $zero ]] && continue
  # New branch, unknown remote commit, or force push: every pushed commit that is
  # not already on this remote, and every file in the pushed commit. Never HEAD or
  # the working tree.
  if [[ "$remote_sha" =~ $zero ]] || ! git cat-file -e "${remote_sha}^{commit}" 2> /dev/null ||
    ! git merge-base --is-ancestor "$remote_sha" "$local_sha"; then
    set -- --new-branch "$local_sha" "$remote"
  else
    set -- --range "$remote_sha" "$local_sha"
  fi
  bash "$check" --config "$config" "$@" < /dev/null || status=1
  if [[ "$use_gitleaks" -eq 1 ]]; then
    bash "$check" --config "$config" --gitleaks "$@" < /dev/null || status=1
  fi
done

if [[ "$status" -ne 0 ]]; then
  echo "privacy hook: push refused. Findings above are path:line rule only." >&2
fi
exit "$status"
EOF
chmod +x "$hooks/pre-push.tmp"
mv "$hooks/pre-push.tmp" "$hooks/pre-push"
echo "installed repo-local pre-push hook"
