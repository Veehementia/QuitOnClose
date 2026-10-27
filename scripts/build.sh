#!/bin/bash
# Builds build/QuitOnClose.app for Apple Silicon.
# Set SIGN_IDENTITY to a codesigning identity to sign with it (default: ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/QuitOnClose.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ ! -f Resources/AppIcon.icns ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    swift scripts/make-icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
    -module-name QuitOnClose Sources/App/*.swift -o "$APP/Contents/MacOS/QuitOnClose"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Localizations/*.lproj "$APP/Contents/Resources/"

codesign --force --sign "$SIGN_IDENTITY" --identifier com.matteonardone.QuitOnClose "$APP"

echo "Built $APP"
