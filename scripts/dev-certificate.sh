#!/bin/bash
set -euo pipefail

NAME="${1:-Lossless Dev}"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "signing identity '$NAME' already exists"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$WORK/dev.key" -out "$WORK/dev.crt" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -legacy -out "$WORK/dev.p12" \
    -inkey "$WORK/dev.key" -in "$WORK/dev.crt" -passout pass:lossless

security import "$WORK/dev.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P lossless -T /usr/bin/codesign -T /usr/bin/security

security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || \
    echo "note: could not pre-authorize the key; codesign may prompt once"

echo "created signing identity '$NAME'"
security find-identity -v -p codesigning
