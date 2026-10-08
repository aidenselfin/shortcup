#!/usr/bin/env bash
# Installs a repository-local pre-push hook. Does not read or write global git config.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

hooks=$(git rev-parse --git-path hooks)
if [[ "$hooks" != /* ]]; then
  hooks="$root/$hooks"
fi
mkdir -p "$hooks"

cat > "$hooks/pre-push" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
check="$root/scripts/privacy-check.sh"
status=0

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  if [[ -z "${local_sha:-}" ]]; then
    continue
  fi
  if [[ "$local_sha" =~ ^0+$ ]]; then
    continue
  fi
  if [[ "$remote_sha" =~ ^0+$ ]]; then
    bash "$check" --repo "$root" --all || status=1
    if command -v gitleaks >/dev/null 2>&1; then
      bash "$check" --repo "$root" --all --gitleaks || status=1
    fi
  else
    bash "$check" --repo "$root" --range "$remote_sha" "$local_sha" || status=1
    if command -v gitleaks >/dev/null 2>&1; then
      bash "$check" --repo "$root" --range "$remote_sha" "$local_sha" --gitleaks || status=1
    fi
  fi
done

exit "$status"
EOF

chmod +x "$hooks/pre-push"
echo "installed repo-local pre-push hook"
