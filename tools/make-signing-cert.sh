#!/bin/bash
# Creates a local code-signing identity so Accessibility grants survive rebuilds.
#
# The problem: an ad-hoc signature makes the app's designated requirement a hash of
# the binary, so every rebuild looks like a different program to macOS. The
# Accessibility entry you granted stays in the list, still switched on, but no longer
# matches — which reads as "I enabled it and it still says I didn't".
#
# With this certificate the requirement becomes
#     identifier "com.btr.voice" and certificate leaf = H"<cert>"
# which doesn't change when the binary does. Grant once, keep it.
#
# Runs unattended, is idempotent, and touches only your login keychain.

set -euo pipefail

NAME="BtrVoice Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

existing="$(security find-identity -v "$KEYCHAIN" 2>/dev/null | grep -F "$NAME" | head -1 || true)"
if [[ -z "$existing" ]]; then
    existing="$(security find-identity "$KEYCHAIN" 2>/dev/null | grep -F "$NAME" | head -1 || true)"
fi
if [[ -n "$existing" ]]; then
    echo "Already present: $(echo "$existing" | sed 's/^ *[0-9]*) *//')"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "${TMP}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = ${NAME}
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

echo "==> Generating certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "${TMP}/openssl.cnf" \
    -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" 2>/dev/null

# Apple's keychain importer can't read OpenSSL 3's default PKCS#12 encryption,
# so ask for the legacy algorithms it does understand.
openssl pkcs12 -export -out "${TMP}/identity.p12" \
    -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -name "$NAME" -passout pass:btrvoice \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into the login keychain"
# -A lets codesign use the key without a per-signature authorisation prompt.
security import "${TMP}/identity.p12" -k "$KEYCHAIN" -P btrvoice -T /usr/bin/codesign -A >/dev/null

hash="$(security find-identity "$KEYCHAIN" 2>/dev/null | grep -F "$NAME" | head -1 | awk '{print $2}')"
if [[ -z "$hash" ]]; then
    echo "Import succeeded but the identity is not visible — sign ad-hoc instead." >&2
    exit 1
fi

echo "==> Created \"${NAME}\" (${hash})"
echo "    build.sh will pick this up automatically from now on."
echo
echo "    The certificate is self-signed and untrusted, which is fine: codesign only"
echo "    needs it to produce a stable identity, and the app is never distributed."
