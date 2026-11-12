#!/bin/bash
# Builds build/fifi.app. Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/fifi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Fifi" "$APP/Contents/MacOS/fifi"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Sign with the local "fifi local" certificate when it exists (scripts/make-signing-cert.sh),
# so the Accessibility permission survives rebuilds; otherwise ad-hoc.
IDENTITY="-"
if security find-certificate -c "fifi local" >/dev/null 2>&1; then IDENTITY="fifi local"; fi
codesign --force --sign "$IDENTITY" "$APP" >/dev/null

echo "$APP"
