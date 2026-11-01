#!/bin/zsh
# Builds a release binary and assembles "build/Better Preview.app" (ad-hoc signed).
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Better Preview.app"
PLIST="$APP/Contents/Info.plist"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BetterPreview"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BetterPreview"
cp Resources/Info.plist "$PLIST"
codesign --force --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"

echo "Built $APP"
