#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${LOSSLESS_DEVELOPER_ID:-}"
PROFILE="${LOSSLESS_NOTARY_PROFILE:-lossless}"
APP="build/Lossless.app"
DMG="build/Lossless.dmg"

if [ -z "$IDENTITY" ]; then
  echo "error: set LOSSLESS_DEVELOPER_ID to your Developer ID Application identity." >&2
  echo "       'security find-identity -p codesigning' lists what this machine has." >&2
  exit 1
fi
if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "error: no codesigning identity matching '$IDENTITY' in the keychain." >&2
  exit 1
fi

scripts/bundle.sh release

echo "== sign with hardened runtime and a secure timestamp =="
codesign --force --options runtime --timestamp \
  --entitlements Resources/Lossless.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "== package =="
rm -f "$DMG"
hdiutil create -quiet -volname Lossless -srcfolder "$APP" -ov -format ULFO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "== notarize =="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "== staple =="
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "notarized $DMG"
