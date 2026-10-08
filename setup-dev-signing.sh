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

keychain_in_search_list() {
  local line trimmed
  while IFS= read -r line; do
    trimmed="${line//\"/}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ "$trimmed" == "$KEYCHAIN" ]] && return 0
  done < <(security list-keychains -d user)
  return 1
}

ensure_private_mode() {
  local f mode
  for f in "$PW_FILE" "${CONF_DIR}/dev-key.pem" "${CONF_DIR}/dev-cert.pem"; do
    [[ -f "$f" ]] || continue
    chmod 600 "$f"
    mode="$(stat -f '%Lp' "$f")"
    [[ "$mode" == "600" ]]
  done
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
    python3 "$PWD/scripts/keychain.py" create "$KEYCHAIN" "$PW_FILE"
  fi
  if ! keychain_in_search_list; then
    append_search_list
  fi
  security set-keychain-settings "$KEYCHAIN"
  python3 "$PWD/scripts/keychain.py" unlock "$KEYCHAIN" "$PW_FILE"
  # PKCS#8 PEM keys do not pair with the certificate on import. A legacy PKCS#12
  # does. Its wrapping password is a temp file, not the keychain password.
  # -A lets codesign use the key without set-key-partition-list, which prompts.
  umask 077
  print -n -- "import-once" > "$work/p12pass"
  openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/dev.p12" -passout "file:$work/p12pass" >/dev/null
  security import "$work/dev.p12" -k "$KEYCHAIN" -P import-once -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  python3 "$PWD/scripts/keychain.py" lock "$KEYCHAIN"
  rm -rf "$work"
  trap - EXIT
else
  if ! keychain_in_search_list; then
    append_search_list
  fi
fi
ensure_private_mode

echo "identity=Shortcup Dev"
echo "keychain=$KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN"
