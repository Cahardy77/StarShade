#!/bin/bash
# Create a self-signed code signing certificate for StarShade
# This gives the app a stable identity so macOS Screen Recording
# permission persists across rebuilds.
#
# You only need to run this ONCE.
set -euo pipefail

CERT_NAME="StarShade Dev"

# Check if cert already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' already exists"
    security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"
    echo ""
    echo "You're all set! Just run: ./build.sh"
    exit 0
fi

echo "Creating self-signed code signing certificate: '$CERT_NAME'"
echo "This gives the app a stable identity for macOS permissions."
echo ""

# Create temp directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create certificate config
cat > "$TMPDIR/cert.cfg" <<'CERTCFG'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_code_sign

[dn]
CN = StarShade Dev

[v3_code_sign]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:FALSE
CERTCFG

# Generate key and certificate
echo "Generating certificate..."
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -days 3650 -nodes \
    -config "$TMPDIR/cert.cfg" 2>/dev/null

# Import certificate and private key as PEM (works with all OpenSSL versions)
echo "Importing into login keychain..."
security import "$TMPDIR/cert.pem" \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign 2>/dev/null || true
security import "$TMPDIR/key.pem" \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign 2>/dev/null || true

# Trust the certificate for code signing
echo "Trusting certificate for code signing..."
security add-trusted-cert -d \
    -r trustRoot \
    -p codeSign \
    -k ~/Library/Keychains/login.keychain-db \
    "$TMPDIR/cert.pem" 2>/dev/null || {
    echo ""
    echo "⚠️  Automatic trust failed — you may need to trust manually:"
    echo "   1. Open Keychain Access"
    echo "   2. Find '$CERT_NAME' in login keychain"
    echo "   3. Double-click → Trust → Code Signing → Always Trust"
}

echo ""

# Verify
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' created and ready!"
    security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"
else
    echo "⚠️  Certificate was imported but may need manual trust."
    echo "   Open Keychain Access, find '$CERT_NAME', double-click it,"
    echo "   expand 'Trust', and set Code Signing to 'Always Trust'."
fi

echo ""
echo "Next steps:"
echo "  1. Rebuild:  ./build.sh"
echo "  2. Reset Screen Recording permission (one-time):"
echo "     tccutil reset ScreenCapture com.starshade.app"
echo "  3. Launch:   open 'StarShade.app'"
echo "  4. Grant Screen Recording permission when prompted"
echo ""
echo "After this, permission will persist across rebuilds!"
