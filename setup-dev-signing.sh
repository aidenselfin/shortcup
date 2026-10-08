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
VERSION=4
/bin/mkdir -p "$CONF_DIR"
/bin/chmod 700 "$CONF_DIR"

if [[ ! -f "$PW_FILE" ]]; then
  /usr/bin/openssl rand -base64 32 > "$PW_FILE"
  /bin/chmod 600 "$PW_FILE"
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
  done < <(/usr/bin/security list-keychains -d user)
  /usr/bin/security list-keychains -d user -s "${cleaned[@]}" "$KEYCHAIN"
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
  done < <(/usr/bin/security list-keychains -d user)
  if (( ${#cleaned[@]} )); then
    /usr/bin/security list-keychains -d user -s "${cleaned[@]}"
  fi
}

keychain_in_search_list() {
  local line trimmed
  while IFS= read -r line; do
    trimmed="${line//\"/}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ "$trimmed" == "$KEYCHAIN" ]] && return 0
  done < <(/usr/bin/security list-keychains -d user)
  return 1
}

ensure_private_mode() {
  local f mode
  for f in "$PW_FILE" "${CONF_DIR}/dev-cert.pem" "$MARKER"; do
    [[ -f "$f" ]] || continue
    /bin/chmod 600 "$f"
    mode="$(/usr/bin/stat -f '%Lp' "$f")"
    [[ "$mode" == "600" ]]
  done
}

delete_dedicated_keychain() {
  # Dedicated Shortcup keychain only. Never the login keychain.
  if [[ -f "$KEYCHAIN" ]]; then
    /usr/bin/python3 "$PWD/scripts/keychain.py" lock "$KEYCHAIN" || true
  fi
  remove_from_search_list
  if [[ -f "$KEYCHAIN" ]]; then
    /usr/bin/security delete-keychain "$KEYCHAIN" || true
  fi
  /bin/rm -f "$KEYCHAIN" "${KEYCHAIN}-shm" "${KEYCHAIN}-wal" "${KEYCHAIN}.old"
  /bin/rm -f "${CONF_DIR}/dev-key.pem" "${CONF_DIR}/dev-cert.pem"
}

create_identity() {
  work="$(/usr/bin/mktemp -d)"
  trap '/bin/rm -rf "$work"' EXIT
  /bin/cat > "$work/cs.cnf" <<'EOF'
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
  if ! /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cs.cnf" -extensions ext \
    -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null; then
    print -- "ERROR: could not create the dedicated signing certificate" >&2
    exit 1
  fi
  /bin/chmod 600 "$work/key.pem" "$work/cert.pem"
  /bin/cp "$work/cert.pem" "${CONF_DIR}/dev-cert.pem"
  /bin/chmod 600 "${CONF_DIR}/dev-cert.pem"
  if [[ ! -f "$KEYCHAIN" ]]; then
    /usr/bin/python3 "$PWD/scripts/keychain.py" create "$KEYCHAIN" "$PW_FILE"
  fi
  if ! keychain_in_search_list; then
    append_search_list
  fi
  /usr/bin/security set-keychain-settings -t 21600 "$KEYCHAIN"
  /usr/bin/python3 "$PWD/scripts/keychain.py" unlock "$KEYCHAIN" "$PW_FILE"
  # PKCS#8 PEM keys do not pair with the certificate on import. A PKCS#12
  # does. Its wrapping password is random, lives in a temp file for openssl,
  # and is passed in memory to SecPKCS12Import / SecItemImport. Never argv.
  umask 077
  /usr/bin/openssl rand -base64 32 | /usr/bin/tr -d '\n' > "$work/p12pass"
  /bin/chmod 600 "$work/p12pass"
  if ! /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/dev.p12" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "file:$work/p12pass" >/dev/null; then
    print -- "ERROR: could not wrap the dedicated signing identity" >&2
    exit 1
  fi
  if ! /usr/bin/python3 "$PWD/scripts/keychain.py" import-p12 "$KEYCHAIN" "$PW_FILE" "$work/dev.p12" "$work/p12pass"; then
    print -- "ERROR: could not import the dedicated signing identity" >&2
    exit 1
  fi
  /bin/rm -f "${CONF_DIR}/dev-key.pem"
  if ! /usr/bin/python3 "$PWD/scripts/keychain.py" set-partition-list "$KEYCHAIN" "$PW_FILE"; then
    print -- "ERROR: could not set the dedicated keychain partition list" >&2
    /usr/bin/python3 "$PWD/scripts/keychain.py" lock "$KEYCHAIN" || true
    exit 1
  fi
  /usr/bin/python3 "$PWD/scripts/keychain.py" lock "$KEYCHAIN"
  /bin/rm -rf "$work"
  trap - EXIT
  print -n -- "$VERSION" > "$MARKER"
  /bin/chmod 600 "$MARKER"
}

need_recreate=0
if [[ ! -f "$MARKER" ]]; then
  need_recreate=1
else
  got="$(/usr/bin/tr -dc '0-9' < "$MARKER")"
  [[ "$got" == "$VERSION" ]] || need_recreate=1
fi

if [[ "$need_recreate" == 1 ]]; then
  delete_dedicated_keychain
  create_identity
elif ! /usr/bin/security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  create_identity
else
  if ! keychain_in_search_list; then
    append_search_list
  fi
fi
/bin/rm -f "${CONF_DIR}/dev-key.pem"
ensure_private_mode

print -- "identity=Shortcup Dev"
print -- "keychain=~/Library/Keychains/${KEYCHAIN:t}"
/usr/bin/security find-identity -p codesigning "$KEYCHAIN"
