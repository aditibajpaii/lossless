#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== format =="
xcrun swift-format lint --strict --recursive Sources Tests

echo "== build =="
swift build -Xswiftc -warnings-as-errors

echo "== test =="
swift test

echo "== bundle =="
scripts/bundle.sh debug

echo
echo "CHECKS: PASS"
