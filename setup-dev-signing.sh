#!/bin/zsh
# One-time Shortcup dev signing identity.
# Dedicated keychain only (not the login keychain). No TCC changes.
# Trust settings are not required to sign. Re-running is safe.
set -eu
NAME="Shortcup Dev"
CONF_DIR="${HOME}/.config/shortcup"
PW_FILE="${CONF_DIR}/keychain-password"
KEYCHAIN="${HOME}/Library/Keychains/shortcup-dev.keychain-db"
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

if [[ ! -f "$PW_FILE" ]]; then
  openssl rand -base64 32 > "$PW_FILE"
  chmod 600 "$PW_FILE"
fi
PW="$(cat "$PW_FILE")"

append_search_list() {
  local -a cleaned
  local line trimmed
  # zsh does not split unquoted variables. Read one keychain path per line.
  while IFS= read -r line; do
    trimmed="${line//\"/}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" || "$trimmed" == "$KEYCHAIN" ]] && continue
    [[ -f "$trimmed" ]] && cleaned+=("$trimmed")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${cleaned[@]}" "$KEYCHAIN"
}

if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  cat > "$work/cs.cnf" <<'EOF'
[req]
distinguished_name=dn
prompt=no
[dn]
CN=Shortcup Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cs.cnf" -extensions ext \
    -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
  chmod 600 "$work/key.pem" "$work/cert.pem"
  cp "$work/key.pem" "${CONF_DIR}/dev-key.pem"
  cp "$work/cert.pem" "${CONF_DIR}/dev-cert.pem"
  chmod 600 "${CONF_DIR}/dev-key.pem" "${CONF_DIR}/dev-cert.pem"
  if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$PW" "$KEYCHAIN"
  fi
  append_search_list
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$PW" "$KEYCHAIN"
  security import "$work/cert.pem" -k "$KEYCHAIN" >/dev/null
  security import "$work/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null
  rm -rf "$work"
  trap - EXIT
else
  append_search_list
  security unlock-keychain -p "$PW" "$KEYCHAIN"
fi

echo "identity=Shortcup Dev"
echo "keychain=$KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN"
