#!/bin/bash
# Builds a release fifi.app, installs it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(scripts/build.sh release | tail -1)"
pkill -x fifi 2>/dev/null || true
sleep 0.3
rm -rf /Applications/fifi.app
cp -R "$APP" /Applications/fifi.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/fifi.app
open /Applications/fifi.app
echo "installed /Applications/fifi.app"
