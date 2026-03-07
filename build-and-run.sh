#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$DIR/Port42.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

echo "[Port42] Building..."
cd "$DIR"
swift build 2>&1

echo "[Port42] Packaging..."
mkdir -p "$MACOS_DIR"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
mkdir -p "$RESOURCES_DIR"
cp .build/debug/Port42 "$MACOS_DIR/Port42"
cp "$DIR/port42-gateway" "$MACOS_DIR/port42-gateway" 2>/dev/null || true
cp "$DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy resource bundles (videos, assets, etc.)
for bundle in .build/debug/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$RESOURCES_DIR/"
done

# Sign the bundle so Keychain "Always Allow" persists across launches
codesign --force --sign - --entitlements "$DIR/Port42.entitlements" "$APP_BUNDLE"

echo "[Port42] Launching..."
open "$APP_BUNDLE"
