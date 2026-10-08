#!/bin/zsh
# One-time Shortcup dev signing identity.
# Dedicated keychain only (not the login keychain). No TCC changes.
# Trust settings are not required to sign. Re-running is safe.
set -eu
NAME="Shortcup Dev"
CONF_DIR="${HOME}/.config/shortcup"
PW_FILE="${CONF_DIR}/keychain-password"
KEYCHAIN="${HOME}/Library/Keychains/shortcup-dev.keychain-db"
MARKER="${CONF_DIR}/dev-identity-version"
VERSION=2
PYTHON=/usr/bin/python3
SECURITY=/usr/bin/security
OPENSSL=/usr/bin/openssl
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

if [[ ! -f "$PW_FILE" ]]; then
  "$OPENSSL" rand -base64 32 > "$PW_FILE"
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
  done < <("$SECURITY" list-keychains -d user)
  "$SECURITY" list-keychains -d user -s "${cleaned[@]}" "$KEYCHAIN"
}

remove_from_search_list() {
  local -a cleaned
  local line trimmed
  while IFS= read -r line; do
    trimmed="${line//\"/}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" || "$trimmed" == "$KEYCHAIN" ]] && continue
    [[ -f "$trimmed" ]] && cleaned+=("$trimmed")
  done < <("$SECURITY" list-keychains -d user)
  if (( ${#cleaned[@]} )); then
    "$SECURITY" list-keychains -d user -s "${cleaned[@]}"
  fi
}

keychain_in_search_list() {
  local line trimmed
  while IFS= read -r line; do
    trimmed="${line//\"/}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ "$trimmed" == "$KEYCHAIN" ]] && return 0
  done < <("$SECURITY" list-keychains -d user)
  return 1
}

ensure_private_mode() {
  local f mode
  for f in "$PW_FILE" "${CONF_DIR}/dev-key.pem" "${CONF_DIR}/dev-cert.pem" "$MARKER"; do
    [[ -f "$f" ]] || continue
    chmod 600 "$f"
    mode="$(stat -f '%Lp' "$f")"
    [[ "$mode" == "600" ]]
  done
}

delete_dedicated_keychain() {
  # Dedicated Shortcup keychain only. Never the login keychain.
  if [[ -f "$KEYCHAIN" ]]; then
    "$PYTHON" "$PWD/scripts/keychain.py" lock "$KEYCHAIN" || true
  fi
  remove_from_search_list
  if [[ -f "$KEYCHAIN" ]]; then
    "$SECURITY" delete-keychain "$KEYCHAIN" || true
  fi
  rm -f "$KEYCHAIN" "${KEYCHAIN}-shm" "${KEYCHAIN}-wal" "${KEYCHAIN}.old"
  rm -f "${CONF_DIR}/dev-key.pem" "${CONF_DIR}/dev-cert.pem"
}

create_identity() {
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
  if ! "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cs.cnf" -extensions ext \
    -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null; then
    print -- "ERROR: could not create the dedicated signing certificate" >&2
    exit 1
  fi
  chmod 600 "$work/key.pem" "$work/cert.pem"
  cp "$work/key.pem" "${CONF_DIR}/dev-key.pem"
  cp "$work/cert.pem" "${CONF_DIR}/dev-cert.pem"
  chmod 600 "${CONF_DIR}/dev-key.pem" "${CONF_DIR}/dev-cert.pem"
  if [[ ! -f "$KEYCHAIN" ]]; then
    "$PYTHON" "$PWD/scripts/keychain.py" create "$KEYCHAIN" "$PW_FILE"
  fi
  if ! keychain_in_search_list; then
    append_search_list
  fi
  "$SECURITY" set-keychain-settings "$KEYCHAIN"
  "$PYTHON" "$PWD/scripts/keychain.py" unlock "$KEYCHAIN" "$PW_FILE"
  # PKCS#8 PEM keys do not pair with the certificate on import. A legacy PKCS#12
  # does. Its wrapping password is a temp file, not the keychain password.
  umask 077
  print -n -- "import-once" > "$work/p12pass"
  if ! "$OPENSSL" pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/dev.p12" -passout "file:$work/p12pass" >/dev/null; then
    print -- "ERROR: could not wrap the dedicated signing identity" >&2
    exit 1
  fi
  if ! "$SECURITY" import "$work/dev.p12" -k "$KEYCHAIN" -P import-once -T /usr/bin/codesign; then
    print -- "ERROR: could not import the dedicated signing identity" >&2
    exit 1
  fi
  if ! "$PYTHON" "$PWD/scripts/keychain.py" set-partition-list "$KEYCHAIN" "$PW_FILE"; then
    print -- "ERROR: could not set the dedicated keychain partition list" >&2
    "$PYTHON" "$PWD/scripts/keychain.py" lock "$KEYCHAIN" || true
    exit 1
  fi
  "$PYTHON" "$PWD/scripts/keychain.py" lock "$KEYCHAIN"
  rm -rf "$work"
  trap - EXIT
  print -n -- "$VERSION" > "$MARKER"
  chmod 600 "$MARKER"
}

need_recreate=0
if [[ ! -f "$MARKER" ]]; then
  need_recreate=1
else
  got="$(tr -dc '0-9' < "$MARKER")"
  [[ "$got" == "$VERSION" ]] || need_recreate=1
fi

if [[ "$need_recreate" == 1 ]]; then
  delete_dedicated_keychain
  create_identity
elif ! "$SECURITY" find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  create_identity
else
  if ! keychain_in_search_list; then
    append_search_list
  fi
fi
ensure_private_mode

echo "identity=Shortcup Dev"
echo "keychain=~/Library/Keychains/${KEYCHAIN:t}"
"$SECURITY" find-identity -p codesigning "$KEYCHAIN"
