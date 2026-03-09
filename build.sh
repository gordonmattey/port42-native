#!/bin/bash
# Build Port42.app
# Usage: ./build.sh [--release] [--run] [--peer]
#   --peer   Build and launch a second instance (Port42-Peer.app) with
#            its own data directory and gateway port for local testing
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="debug"
RUN=false
PEER=false

for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release" ;;
        --run)     RUN=true ;;
        --peer)    PEER=true ;;
    esac
done

# --- Generate app icon assets from SVG ---
SVG="$DIR/Sources/Port42/Resources/port42-icon.svg"
ICNS="$DIR/Sources/Port42/Resources/AppIcon.icns"
LOGO_PNG="$DIR/Sources/Port42Lib/Resources/Media.xcassets/port42-logo.imageset/port42-logo.png"

if [ "$SVG" -nt "$ICNS" ] 2>/dev/null || [ ! -f "$ICNS" ]; then
    if ! command -v rsvg-convert &>/dev/null; then
        echo "[build] ERROR: rsvg-convert not found. Install with: brew install librsvg"
        exit 1
    fi

    echo "[build] Generating icon assets from SVG..."
    ICONSET=$(mktemp -d)/Port42.iconset
    mkdir -p "$ICONSET"

    for size in 16 32 128 256 512; do
        retina=$((size * 2))
        rsvg-convert -w $size -h $size "$SVG" -o "$ICONSET/icon_${size}x${size}.png"
        rsvg-convert -w $retina -h $retina "$SVG" -o "$ICONSET/icon_${size}x${size}@2x.png"
    done

    iconutil -c icns -o "$ICNS" "$ICONSET"
    rm -rf "$(dirname "$ICONSET")"

    # In-app logo (512px)
    rsvg-convert -w 512 -h 512 "$SVG" -o "$LOGO_PNG"

    echo "[build] Icon assets generated."
else
    echo "[build] Icon assets up to date."
fi

# Build Swift + Go (shared by both app and peer)
echo "[build] Swift ($CONFIG)..."
cd "$DIR"
if [ "$CONFIG" = "release" ]; then
    swift build -c release 2>&1 | tail -3
else
    swift build 2>&1 | tail -3
fi

echo "[build] Go gateway..."
cd "$DIR/gateway"
GATEWAY_BIN="$DIR/.build/port42-gateway"
go build -o "$GATEWAY_BIN" .

# --- Package the main app ---
APP="$DIR/.build/Port42.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RESOURCES"

cp "$DIR/.build/$CONFIG/Port42" "$MACOS/Port42"
cp "$GATEWAY_BIN" "$MACOS/port42-gateway"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Sources/Port42/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
for bundle in "$DIR/.build/$CONFIG"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$RESOURCES/"
done
# Auto-detect Developer ID signing identity if not explicitly set.
if [ -z "${PORT42_SIGN_IDENTITY:-}" ]; then
    DETECTED_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}')
    SIGN_IDENTITY="${DETECTED_IDENTITY:--}"
else
    SIGN_IDENTITY="$PORT42_SIGN_IDENTITY"
fi
# Provisioning profiles
DEV_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/Port 42 Local Development.provisionprofile"
RELEASE_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/Port42 Provisioning Profile.provisionprofile"
# Apple Development identity for debug builds with Sign in with Apple
DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
if [ "$CONFIG" = "release" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    # Release: hardened runtime + timestamp + embedded profile
    [ -f "$RELEASE_PROFILE" ] && cp "$RELEASE_PROFILE" "$APP/Contents/embedded.provisionprofile"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$MACOS/port42-gateway"
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$DIR/Port42.release.entitlements" --options runtime --timestamp "$APP"
elif [ -n "$DEV_IDENTITY" ] && [ -f "$DEV_PROFILE" ]; then
    # Debug with Apple Development cert + dev profile: Sign in with Apple enabled
    cp "$DEV_PROFILE" "$APP/Contents/embedded.provisionprofile"
    codesign --force --sign "$DEV_IDENTITY" --entitlements "$DIR/Port42.release.entitlements" "$APP"
    echo "[build] Signed with Apple Development (Sign in with Apple enabled)"
elif [ "$SIGN_IDENTITY" != "-" ]; then
    # Debug with Developer ID: no applesignin (requires notarization)
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$DIR/Port42.entitlements" --options runtime "$APP"
else
    # Debug ad-hoc fallback
    codesign --force --sign - --entitlements "$DIR/Port42.entitlements" "$APP"
fi
echo "[build] Ready: $APP"

# --- Release: package DMG, notarize, staple, update dist ---
if [ "$CONFIG" = "release" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    DIST="$DIR/dist"
    DMG="$DIST/Port42.dmg"
    mkdir -p "$DIST"

    # Copy app to dist
    rm -rf "$DIST/Port42.app"
    cp -R "$APP" "$DIST/Port42.app"

    # Create DMG
    rm -f "$DMG"
    echo "[build] Creating DMG..."
    hdiutil create -volname "Port42" -srcfolder "$DIST/Port42.app" -ov -format UDZO "$DMG" >/dev/null 2>&1

    # Sign DMG
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
    echo "[build] DMG signed."

    # Notarize
    echo "[build] Submitting for notarization..."
    xcrun notarytool submit "$DMG" --keychain-profile "notarytool" --wait 2>&1 | tail -5

    # Staple
    xcrun stapler staple "$DMG" 2>&1 | tail -1
    echo "[build] Release ready: $DMG"
fi

if $RUN; then
    echo "[build] Launching..."
    open "$APP"
fi

# --- Build and launch the peer (if requested) ---
if $PEER; then
    PEER_APP="$DIR/.build/Port42-Peer.app"
    PEER_MACOS="$PEER_APP/Contents/MacOS"
    PEER_RESOURCES="$PEER_APP/Contents/Resources"
    mkdir -p "$PEER_MACOS" "$PEER_RESOURCES"

    cp "$DIR/.build/$CONFIG/Port42" "$PEER_MACOS/Port42-Peer"
    cp "$GATEWAY_BIN" "$PEER_MACOS/port42-gateway"
    cp "$DIR/Sources/Port42/Resources/AppIcon.icns" "$PEER_RESOURCES/AppIcon.icns"
    for bundle in "$DIR/.build/$CONFIG"/*.bundle; do
        [ -d "$bundle" ] && cp -R "$bundle" "$PEER_RESOURCES/"
    done

    # Peer gets a different bundle ID and name
    sed -e 's/com.port42.app/com.port42.peer/' \
        -e 's/<string>Port42<\/string>/<string>Port42-Peer<\/string>/' \
        "$DIR/Info.plist" > "$PEER_APP/Contents/Info.plist"

    # Wrapper script that sets env vars and execs the real binary
    cat > "$PEER_MACOS/Port42-Peer-Launcher" << 'EOF'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
export PORT42_DATA_DIR="Port42-Peer"
export PORT42_GATEWAY_PORT="4243"
exec "$DIR/Port42-Peer"
EOF
    chmod +x "$PEER_MACOS/Port42-Peer-Launcher"

    # Point Info.plist at the launcher
    sed -i '' 's/<string>Port42-Peer<\/string>/<string>Port42-Peer-Launcher<\/string>/' \
        "$PEER_APP/Contents/Info.plist"
    # Fix: only replace the CFBundleExecutable value, not CFBundleName
    # The sed above is too broad. Let's just write it properly:
    cat > "$PEER_APP/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Port42-Peer-Launcher</string>
	<key>CFBundleIdentifier</key>
	<string>com.port42.peer</string>
	<key>CFBundleName</key>
	<string>Port42-Peer</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST_EOF

    codesign --force --sign - --entitlements "$DIR/Port42.entitlements" "$PEER_APP"

    echo "[build] Ready: $PEER_APP"
    echo "[build] Launching peer (data: Port42-Peer, gateway: 4243)..."
    open "$PEER_APP"
fi
