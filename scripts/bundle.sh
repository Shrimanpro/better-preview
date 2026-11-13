#!/bin/zsh
# Builds a release binary and assembles "build/Better Preview.app" (icon, ad-hoc signed).
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Better Preview.app"
PLIST="$APP/Contents/Info.plist"

# Regenerate the icon when missing or when the generator is newer.
if [[ ! -f Resources/AppIcon.icns || scripts/make-icon.swift -nt Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BetterPreview"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BetterPreview"
cp Resources/Info.plist "$PLIST"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
codesign --force --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"

echo "Built $APP"
