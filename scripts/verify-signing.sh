#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

requirement() { codesign -d -r- build/Lossless.app 2>&1 | grep designated; }
cdhash() { codesign -dv --verbose=4 build/Lossless.app 2>&1 | grep "^CDHash"; }

scripts/bundle.sh debug >/dev/null 2>&1
BEFORE_REQ="$(requirement)"; BEFORE_HASH="$(cdhash)"

MARKER="Sources/LosslessApp/SigningProbe.swift"
printf 'enum SigningProbe {\n    static let stamp = "%s"\n}\n' "$(date +%s)" > "$MARKER"
scripts/bundle.sh debug >/dev/null 2>&1
rm -f "$MARKER"

AFTER_REQ="$(requirement)"; AFTER_HASH="$(cdhash)"
scripts/bundle.sh debug >/dev/null 2>&1

echo "  cdhash before : $BEFORE_HASH"
echo "  cdhash after  : $AFTER_HASH"
echo "  requirement   : $AFTER_REQ"

[ "$BEFORE_HASH" != "$AFTER_HASH" ] || { echo "FAIL: binary did not change, test is meaningless"; exit 1; }
[ "$BEFORE_REQ" = "$AFTER_REQ" ] || { echo "FAIL: designated requirement changed, TCC grants will reset"; exit 1; }
case "$AFTER_REQ" in
    *"certificate leaf"*) echo "signing: requirement is certificate-based and survived a rebuild" ;;
    *) echo "FAIL: requirement is not certificate-based: $AFTER_REQ"; exit 1 ;;
esac
