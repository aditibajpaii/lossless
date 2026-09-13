#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
swift build -c "$CONFIGURATION" --product Lossless
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/Lossless"
APP="build/Lossless.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Lossless"
mkdir -p "$APP/Contents/Resources/page"
cp demo/page/index.html "$APP/Contents/Resources/page/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lossless</string>
  <key>CFBundleDisplayName</key><string>Lossless</string>
  <key>CFBundleIdentifier</key><string>com.lossless.app</string>
  <key>CFBundleExecutable</key><string>Lossless</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Lossless transcribes what you dictate.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${LOSSLESS_SIGNING_IDENTITY:-Lossless Dev}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP" || {
        echo "error: signing with '$IDENTITY' failed." >&2
        echo "error: the login keychain may be locked. Unlock it and rebuild." >&2
        exit 1
    }
else
    echo "warning: no '$IDENTITY' identity; falling back to ad-hoc." >&2
    echo "warning: macOS will reset permission grants on every rebuild." >&2
    echo "warning: run scripts/dev-certificate.sh once to fix that." >&2
    codesign --force --deep --sign - "$APP"
fi

REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | grep designated)"
echo "  ${REQUIREMENT#\# }"
case "$REQUIREMENT" in
    *"certificate leaf"*) ;;
    *) echo "warning: requirement is cdhash-based; grants reset on every rebuild." >&2 ;;
esac
echo "built $APP"
