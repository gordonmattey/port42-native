#!/bin/bash
# Build Port42.app
# Usage: ./build.sh [--release] [--run] [--peer]
#   --peer   Build and launch a second instance (Port42-Peer.app) with
#            its own data directory and gateway port for local testing
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Load secrets from .env and .secrets if present
if [ -f "$DIR/.env" ]; then
    set -a; source "$DIR/.env"; set +a
fi
if [ -f "$DIR/.secrets" ]; then
    set -a; source "$DIR/.secrets"; set +a
fi
# Read version from VERSION file
export APP_VERSION="$(cat "$DIR/VERSION" | tr -d '[:space:]')"

# Auto-increment build number
BUILD_FILE="$DIR/.build-number"
if [ -f "$BUILD_FILE" ]; then
    BUILD_NUMBER=$(($(cat "$BUILD_FILE") + 1))
else
    BUILD_NUMBER=1
fi
echo "$BUILD_NUMBER" > "$BUILD_FILE"
export BUILD_NUMBER

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

# Auto-bump patch version for release builds if not manually bumped
if [ "$CONFIG" = "release" ]; then
    LAST_RELEASE_FILE="$DIR/.last-release-version"
    LAST_RELEASE=$(cat "$LAST_RELEASE_FILE" 2>/dev/null || echo "")
    if [ "$APP_VERSION" = "$LAST_RELEASE" ]; then
        IFS='.' read -r major minor patch <<< "$APP_VERSION"
        APP_VERSION="$major.$minor.$((patch + 1))"
        echo "$APP_VERSION" > "$DIR/VERSION"
        echo "[build] Auto-bumped version to $APP_VERSION"
    fi
    echo "$APP_VERSION" > "$LAST_RELEASE_FILE"
fi
export APP_VERSION

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
    swift build -c release -Xswiftc -DRELEASE 2>&1 | tail -3
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

# Add rpath so the binary can find frameworks in Contents/Frameworks/
install_name_tool -add_rpath "@loader_path/../Frameworks" "$MACOS/Port42" 2>/dev/null || true

# Bundle Sparkle.framework
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
SPARKLE_FW="$DIR/.build/arm64-apple-macosx/$CONFIG/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$FRAMEWORKS/"
else
    echo "[build] WARNING: Sparkle.framework not found at $SPARKLE_FW"
fi

envsubst < "$DIR/Info.plist" > "$APP/Contents/Info.plist"
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
    # Sign Sparkle framework and all nested components (inside-out)
    if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
        SPARKLE_ENT="$DIR/Sparkle.entitlements"
        # Sign nested executables first
        find "$FRAMEWORKS/Sparkle.framework" -type f -perm +111 -not -name "*.plist" -not -name "*.h" -not -name "*.modulemap" | while read binary; do
            codesign --force --sign "$SIGN_IDENTITY" --entitlements "$SPARKLE_ENT" --options runtime --timestamp "$binary"
        done
        # Sign nested bundles
        find "$FRAMEWORKS/Sparkle.framework" \( -name "*.app" -o -name "*.xpc" \) | while read nested; do
            codesign --force --sign "$SIGN_IDENTITY" --entitlements "$SPARKLE_ENT" --options runtime --timestamp "$nested"
        done
        # Sign the framework itself
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$FRAMEWORKS/Sparkle.framework"
    fi
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$DIR/Port42.release.entitlements" --options runtime --timestamp "$APP"
elif [ -n "$DEV_IDENTITY" ] && [ -f "$DEV_PROFILE" ]; then
    # Debug with Apple Development cert + dev profile: Sign in with Apple enabled
    cp "$DEV_PROFILE" "$APP/Contents/embedded.provisionprofile"
    if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
        codesign --force --sign "$DEV_IDENTITY" "$FRAMEWORKS/Sparkle.framework"
    fi
    codesign --force --sign "$DEV_IDENTITY" --entitlements "$DIR/Port42.dev.entitlements" "$APP"
    echo "[build] Signed with Apple Development (Sign in with Apple enabled)"
elif [ "$SIGN_IDENTITY" != "-" ]; then
    # Debug with Developer ID: no applesignin (requires notarization)
    if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
        codesign --force --sign "$SIGN_IDENTITY" --options runtime "$FRAMEWORKS/Sparkle.framework"
    fi
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$DIR/Port42.entitlements" --options runtime "$APP"
else
    # Debug ad-hoc fallback
    if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
        codesign --force --sign - "$FRAMEWORKS/Sparkle.framework"
    fi
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

    # Eject any mounted Port42 volumes before creating DMG
    hdiutil detach /Volumes/Port42 -force 2>/dev/null || true

    # Create DMG with Applications symlink for drag-and-drop install
    rm -f "$DMG"
    echo "[build] Creating DMG..."
    DMG_STAGING=$(mktemp -d)/Port42
    mkdir -p "$DMG_STAGING"
    cp -R "$DIST/Port42.app" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create -volname "Port42 Companion Computing" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG" 2>&1
    rm -rf "$(dirname "$DMG_STAGING")"

    # Sign DMG
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
    echo "[build] DMG signed."

    # Notarize
    echo "[build] Submitting for notarization..."
    xcrun notarytool submit "$DMG" --keychain-profile "notarytool" --wait 2>&1 | tail -5

    # Staple
    xcrun stapler staple "$DMG" 2>&1 | tail -1

    # Generate Sparkle appcast (temporary prefix, will be fixed below)
    GENERATE_APPCAST=$(ls /opt/homebrew/Caskroom/sparkle/*/bin/generate_appcast 2>/dev/null | head -1 || true)
    if [ -n "$GENERATE_APPCAST" ] && [ -x "$GENERATE_APPCAST" ]; then
        echo "[build] Generating Sparkle appcast..."
        "$GENERATE_APPCAST" --download-url-prefix "https://github.com/gordonmattey/port42-native/releases/download/v${APP_VERSION}/" "$DIST"
        echo "[build] Appcast generated: $DIST/appcast.xml"
    else
        echo "[build] WARNING: generate_appcast not found, skipping appcast generation"
        echo "[build] Install with: brew install --cask sparkle"
    fi

    # Create GitHub Release and upload DMG
    echo "[build] Creating GitHub Release v${APP_VERSION}..."
    gh release create "v${APP_VERSION}" "$DMG" \
        --title "v${APP_VERSION}" \
        --notes "Port42 v${APP_VERSION}" 2>&1 || echo "[build] WARNING: GitHub Release creation failed (may already exist)"

    # Push appcast and dist to git
    echo "[build] Pushing appcast to git..."
    cd "$DIR"
    git add dist/appcast.xml
    git commit -m "Update appcast for v${APP_VERSION}" 2>&1 | tail -1
    git push 2>&1 | tail -2

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
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$PEER_MACOS/Port42-Peer" 2>/dev/null || true
    cp "$GATEWAY_BIN" "$PEER_MACOS/port42-gateway"
    cp "$DIR/Sources/Port42/Resources/AppIcon.icns" "$PEER_RESOURCES/AppIcon.icns"
    for bundle in "$DIR/.build/$CONFIG"/*.bundle; do
        [ -d "$bundle" ] && cp -R "$bundle" "$PEER_RESOURCES/"
    done

    # Copy Sparkle framework to peer
    PEER_FRAMEWORKS="$PEER_APP/Contents/Frameworks"
    mkdir -p "$PEER_FRAMEWORKS"
    if [ -d "$SPARKLE_FW" ]; then
        cp -R "$SPARKLE_FW" "$PEER_FRAMEWORKS/"
    fi

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

    codesign --deep --force --sign - --entitlements "$DIR/Port42.entitlements" "$PEER_APP"

    echo "[build] Ready: $PEER_APP"
    echo "[build] Launching peer (data: Port42-Peer, gateway: 4243)..."
    open "$PEER_APP"
fi
