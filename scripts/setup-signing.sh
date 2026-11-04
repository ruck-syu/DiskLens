#!/bin/bash
# One-time setup: creates a self-signed code signing certificate in its own
# keychain at ~/.disklens-signing (your login keychain is not touched).
# To sign CI builds with the same certificate, upload it as repo secrets:
#   base64 -i ~/.disklens-signing/signing.p12 | gh secret set SIGNING_CERT_P12_BASE64
#   gh secret set SIGNING_CERT_PASSWORD < ~/.disklens-signing/p12-password.txt
set -euo pipefail
D="$HOME/.disklens-signing"
KC="$D/signing.keychain-db"
NAME="DiskLens Self-Signed Code Signing"
if [ -f "$KC" ]; then echo "Already set up: $KC"; exit 0; fi

mkdir -p "$D" && chmod 700 "$D" && cd "$D"
PASS="$(openssl rand -hex 16)";   printf %s "$PASS"   > p12-password.txt
KCPASS="$(openssl rand -hex 16)"; printf %s "$KCPASS" > keychain-password.txt
chmod 600 p12-password.txt keychain-password.txt

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" -out signing.p12 -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out signing.p12 -passout "pass:$PASS"
rm key.pem && chmod 600 signing.p12

security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import signing.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null
echo "Created signing identity in $KC"
