#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Lossless.app"
[ -d "$APP" ] || { echo "no $APP; run scripts/bundle.sh first"; exit 1; }

pkill -f "$APP/Contents/MacOS/Lossless" 2>/dev/null || true
sleep 1
SINCE="$(date -u +%Y-%m-%d\ %H:%M:%S)"
open "$APP"
sleep 4

echo "signature"
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/  /'
case "$(codesign -d -r- "$APP" 2>&1)" in
    *"certificate leaf"*) echo "  stable: permission grants survive rebuilds" ;;
    *) echo "  UNSTABLE: ad-hoc signature, macOS resets grants on every rebuild" ;;
esac

echo "readiness as the launched app sees it"
LINE="$(log show --start "$SINCE" --predicate 'subsystem == "com.lossless.app"' \
    --style compact --info --debug 2>/dev/null | grep readiness | tail -1)"
if [ -z "$LINE" ]; then
    echo "  no readiness line logged; the app may not have launched"
    exit 1
fi
echo "  ${LINE#*] }"

case "$LINE" in
    *"microphone=3"*) ;;
    *) echo "  Microphone not authorized. Open Settings from the pill and press Grant." ;;
esac
case "$LINE" in
    *"inputMonitoring=true"*) ;;
    *) echo "  Input Monitoring missing. This is separate from Accessibility." ;;
esac
case "$LINE" in
    *"accessibility=true"*) ;;
    *) echo "  Accessibility missing." ;;
esac
