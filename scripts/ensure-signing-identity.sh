#!/usr/bin/env bash
#
# ensure-signing-identity.sh — guarantee a STABLE local code-signing identity
# exists, then print its SHA-1 hash on stdout (for `codesign --sign <hash>`).
#
# Why this exists
# ---------------
# macOS's permission system (TCC) remembers which app it granted Accessibility /
# Screen Recording to by the app's "Designated Requirement" — a rule derived from
# the code signature. An *ad-hoc* signature ("codesign -s -") has no certificate,
# so its Designated Requirement pins the exact `cdhash` of the binary. The cdhash
# changes on every rebuild, so after you rebuild, the app no longer matches the
# grant macOS stored — System Settings still shows the toggle "on" (a stale
# record), but the running app sees the permission as denied. That is the
# "I granted it but it says I didn't" bug.
#
# Signing with a real certificate — even a self-signed one created locally —
# anchors the Designated Requirement to the certificate ("certificate leaf =
# H\"…\"") instead of the cdhash. The certificate is stable across rebuilds, so
# the permission grant sticks. We create that certificate here, once, and reuse
# it forever. Nothing leaves the machine; it is not an Apple Developer ID and is
# only meant for running LocalClicky locally.
#
# Everything human-readable goes to stderr; only the identity hash goes to stdout.
set -euo pipefail

IDENTITY_NAME="LocalClicky Local Signing"
P12_PASSWORD="localclicky"   # local-only; the key never leaves this Mac.

log() { echo "$@" >&2; }

# Use a dedicated local keychain instead of the login keychain. That keeps the
# signing key non-interactive for scripts/build-app.sh while still giving TCC a
# stable certificate-anchored Designated Requirement across rebuilds.
KEYCHAIN_PASSWORD="localclicky-signing"
KEYCHAIN="$HOME/Library/Keychains/LocalClickySigning.keychain-db"

ensure_keychain() {
  if [ ! -f "$KEYCHAIN" ]; then
    log "==> Creating local signing keychain."
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1
  fi

  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
  security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null 2>&1 || true

  # Add the keychain to the user search list exactly once so codesign can find
  # the identity by hash without prompting.
  CURRENT_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | sed -E 's/^[[:space:]]+//')"
  if ! printf '%s\n' "$CURRENT_KEYCHAINS" | grep -Fxq "$KEYCHAIN"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN" $CURRENT_KEYCHAINS >/dev/null 2>&1 || true
  fi
}

ensure_keychain

# Returns the 40-hex SHA-1 of our identity if it already exists, else nothing.
existing_identity_hash() {
  security find-identity "$KEYCHAIN" 2>/dev/null \
    | grep -F "$IDENTITY_NAME" \
    | grep -oE '[0-9A-Fa-f]{40}' \
    | head -1
}

HASH="$(existing_identity_hash || true)"
if [ -n "$HASH" ]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
  log "==> Reusing existing local signing identity ($HASH)."
  echo "$HASH"
  exit 0
fi

log "==> Creating a one-time local code-signing identity \"$IDENTITY_NAME\"…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/csign.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 10-year self-signed cert + matching private key.
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/csign.cnf" >/dev/null 2>&1

# Bundle into a PKCS#12 (a non-empty password avoids macOS's MAC-verify quirk).
openssl pkcs12 -legacy -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -name "$IDENTITY_NAME" -passout pass:"$P12_PASSWORD" >/dev/null 2>&1

# Import into the local signing keychain. `-A` plus the partition list below lets
# codesign use the private key without prompting on every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
  -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1

# Let non-interactive build scripts use the private key. Without this, macOS can
# show a hidden keychain prompt and leave `codesign` stuck forever.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true

HASH="$(existing_identity_hash || true)"
if [ -z "$HASH" ]; then
  log "!! Failed to create the local signing identity. Falling back to ad-hoc (-)."
  log "   Permission grants may not persist across rebuilds in that mode."
  echo "-"
  exit 0
fi

log "==> Created local signing identity ($HASH)."
echo "$HASH"
