#!/bin/bash
# Build Port42.app
# Usage: ./build.sh [--release] [--run] [--no-dmg]
#   --no-dmg  Release build of the .app only — skip DMG/notarization/publish
#             (installing locally by hand; nothing is pushed anywhere)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Keep the SwiftPM build dir OUTSIDE Dropbox. Dropbox races/evicts files inside
# .build — that corrupts package resolution AND modifies the running app binary
# on disk (→ "CODESIGNING Invalid Page" SIGKILLs). So when this project lives
# under a Dropbox path, .build is a symlink to a local, un-synced directory.
# Auto-created here so it's never a manual step (and you can see where builds go).
if [[ "$DIR" == */Dropbox/* ]] && [ ! -L "$DIR/.build" ]; then
    EXTERNAL_BUILD="$HOME/port42-build"
    if [ -d "$DIR/.build" ]; then
        echo "[build] .build is a real dir inside Dropbox — relocating outside Dropbox..."
        rm -rf "$DIR/.build"
    fi
    mkdir -p "$EXTERNAL_BUILD"
    ln -s "$EXTERNAL_BUILD" "$DIR/.build"
    echo "[build] Linked .build -> $EXTERNAL_BUILD (outside Dropbox; builds live here, not in the repo)"
fi

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
NO_DMG=false

for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release" ;;
        --run)     RUN=true ;;
        --no-dmg)  NO_DMG=true ;;
    esac
done

# --- Dev/release identity split ---------------------------------------------------------------
# A debug build is an ISOLATED instance ("Port42 Dev") so it never collides with the installed
# daily-driver Port42: its own bundle id, data dir and gateway port. Release is unchanged — the
# DMG you install stays com.port42.app / Port42 / 4242. This is what lets you keep using Port42
# while we rebuild the dev instance beside it.
if [ "$CONFIG" = "release" ]; then
    APP_DIR_NAME="Port42"; EXEC="Port42"; BUNDLE_ID="com.port42.app"
    DISPLAY_NAME="Port42"; GW_PORT="4242"; DATA_DIR="Port42"; INVITE_NAME="com.port42.agent-invite"; DEV_ISO=false
else
    APP_DIR_NAME="Port42Dev"; EXEC="Port42Dev"; BUNDLE_ID="com.port42.dev"
    DISPLAY_NAME="Port42 Dev"; GW_PORT="4243"; DATA_DIR="Port42Dev"; INVITE_NAME="com.port42.dev.invite"; DEV_ISO=true
fi

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

# --- Download GhosttyKit.xcframework (native terminal engine) ---
GHOSTTY_COMMIT="fc2d507dcf4d67228e56c6d69ad9e9aa2080a6dc"
GHOSTTYKIT_SHA256="cbe4a8b5f8c00ea9ffe4274e5e764009b6efe2dc877646fd6fa12d34146ce8fe"  # verified 2026-06-24
GHOSTTYKIT_URL="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_COMMIT}-crashsubdir-cmux-crash-v1/GhosttyKit.xcframework.tar.gz"
GHOSTTY_SLICE="$DIR/GhosttyKit.xcframework/macos-arm64_x86_64"
if [ ! -d "$DIR/GhosttyKit.xcframework" ]; then
    # Prefer the vendored tarball (committed via Git LFS) so the build doesn't depend on an
    # external URL staying up. Fall back to downloading if it's absent (e.g. LFS not pulled).
    VENDORED_TARBALL="$DIR/vendor/GhosttyKit.xcframework.tar.gz"
    if [ -f "$VENDORED_TARBALL" ] && [ "$(wc -c < "$VENDORED_TARBALL")" -gt 1000000 ]; then
        echo "[build] Using vendored GhosttyKit (vendor/GhosttyKit.xcframework.tar.gz)..."
        GHOSTTYKIT_TARBALL="$VENDORED_TARBALL"
    else
        echo "[build] Downloading GhosttyKit ($GHOSTTY_COMMIT)..."
        curl -fL -o /tmp/ghosttykit.tar.gz "$GHOSTTYKIT_URL"
        GHOSTTYKIT_TARBALL=/tmp/ghosttykit.tar.gz
    fi
    echo "[build] Verifying checksum..."
    echo "$GHOSTTYKIT_SHA256  $GHOSTTYKIT_TARBALL" | shasum -a 256 -c -
    tar -xz -C "$DIR" -f "$GHOSTTYKIT_TARBALL"
    # The macOS slice ships as ghostty-internal.a (no lib prefix); SwiftPM
    # rejects static libraries that aren't lib-prefixed. Rename it and patch
    # the xcframework Info.plist to match. (iOS slices are already lib-prefixed.)
    if [ -f "$GHOSTTY_SLICE/ghostty-internal.a" ]; then
        mv "$GHOSTTY_SLICE/ghostty-internal.a" "$GHOSTTY_SLICE/libghostty-internal.a"
        sed -i '' 's|>ghostty-internal.a<|>libghostty-internal.a<|g' "$DIR/GhosttyKit.xcframework/Info.plist"
        echo "[build] Renamed macOS slice to libghostty-internal.a (SwiftPM lib-prefix requirement)."
    fi
    echo "[build] GhosttyKit.xcframework extracted."
fi

# Build Swift + Go
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
go build -ldflags "-X main.posthogAPIKey=${POSTHOG_API_KEY:-}" -o "$GATEWAY_BIN" .

# port42-claude-shim — standalone Go module (sibling of gateway/). PATH shim + hook
# notifier for the `claude` CLI in native Ghostty terminals (Step 7). Bundled in MacOS/.
echo "[build] Go shim (port42-claude-shim)..."
cd "$DIR/shim"
SHIM_BIN="$DIR/.build/port42-claude-shim"
go build -o "$SHIM_BIN" .

# Kill any running app + gateway BEFORE we overwrite/re-sign the bundle in place.
# `cp` and `codesign --force` modify Contents/MacOS/Port42 in place (same inode);
# doing that to a *live* process corrupts its memory mapping, and the next lazy
# page-in (e.g. a C++ static destructor at exit) is killed by the kernel with
# "EXC_BAD_ACCESS / SIGKILL (Code Signature Invalid) / CODESIGNING Invalid Page".
# We also kill the bundled gateway so the relaunched app gets a fresh one on
# port 4242 instead of talking to a stale process. This is the single place that
# owns "clean up before rebuild" — rebuild.sh just delegates here.
# Surgical: kill ONLY instances launched FROM THIS BUILD DIR (the bundle we're about to
# overwrite in place) — NEVER the installed daily-driver at /Applications, even on a
# release build (its process is also named "Port42"; a name-based pkill killed the app
# the user was working in). Same for the gateway: only kill a $GW_PORT listener whose
# binary lives under the build dir.
BUILD_REAL=$(cd "$DIR/.build" 2>/dev/null && pwd -P || echo "$DIR/.build")
echo "[build] Killing any running $DISPLAY_NAME launched from $BUILD_REAL (never the installed app)..."
pkill -f "$BUILD_REAL/$APP_DIR_NAME.app/Contents/MacOS/$EXEC" 2>/dev/null || true
for pid in $(lsof -ti "tcp:$GW_PORT" 2>/dev/null); do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in "$BUILD_REAL"*) kill "$pid" 2>/dev/null || true ;; esac
done
for i in {1..10}; do pgrep -f "$BUILD_REAL/$APP_DIR_NAME.app/Contents/MacOS/$EXEC" >/dev/null 2>&1 || break; sleep 0.3; done
pkill -9 -f "$BUILD_REAL/$APP_DIR_NAME.app/Contents/MacOS/$EXEC" 2>/dev/null || true
for pid in $(lsof -ti "tcp:$GW_PORT" 2>/dev/null); do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in "$BUILD_REAL"*) kill -9 "$pid" 2>/dev/null || true ;; esac
done
sleep 0.3

# --- Package the main app ---
APP="$DIR/.build/$APP_DIR_NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
# Repackage into a FRESH bundle each build. SwiftPM resource files (e.g.
# PrivacyInfo.xcprivacy) and signed framework files are read-only, so cp -R
# over an existing bundle fails with "Permission denied". Removing first makes
# packaging idempotent. (Previously masked because Dropbox wiped .build between
# builds; now that .build lives outside Dropbox, the stale bundle persists.)
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$DIR/.build/$CONFIG/Port42" "$MACOS/$EXEC"
cp "$GATEWAY_BIN" "$MACOS/port42-gateway"
cp "$SHIM_BIN" "$MACOS/port42-claude-shim"

# Add rpath so the binary can find frameworks in Contents/Frameworks/
install_name_tool -add_rpath "@loader_path/../Frameworks" "$MACOS/$EXEC" 2>/dev/null || true

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
if $DEV_ISO; then
    # Launcher (the bundle's main executable) sets the isolated data dir + gateway port, then
    # execs the real binary.
    cat > "$MACOS/$EXEC-Launcher" << EOF
#!/bin/bash
D="\$(cd "\$(dirname "\$0")" && pwd)"
export PORT42_DATA_DIR="$DATA_DIR"
export PORT42_GATEWAY_PORT="$GW_PORT"
exec "\$D/$EXEC"
EOF
    chmod +x "$MACOS/$EXEC-Launcher"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXEC-Launcher" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName '$DISPLAY_NAME'" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $INVITE_NAME" "$APP/Contents/Info.plist" 2>/dev/null || true
    echo "[build] Dev isolation: $BUNDLE_ID · data $DATA_DIR · gateway $GW_PORT"
fi
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
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$MACOS/port42-claude-shim"
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
else
    # Isolated dev (debug) build. Prefer the stable Apple Development identity over ad-hoc so the
    # code-signing identity is CONSISTENT across rebuilds → macOS TCC permission grants (screen,
    # camera, automation, etc.) PERSIST. Ad-hoc (`--sign -`) gets a fresh identity every build, so
    # TCC treats each rebuild as a new app and forgets/re-prompts. Apple Development can sign any
    # bundle id locally (no provisioning profile needed for these entitlements). Fall back to ad-hoc
    # if no Apple Development cert is present. The launcher script is the bundle's main executable,
    # so --deep also signs the real binary + gateway + shim.
    if [ -n "$DEV_IDENTITY" ] && codesign --deep --force --sign "$DEV_IDENTITY" --entitlements "$DIR/Port42.entitlements" "$APP" 2>/dev/null; then
        echo "[build] Signed with Apple Development (stable identity → TCC permissions persist): $BUNDLE_ID · data $DATA_DIR · gateway $GW_PORT"
    else
        codesign --deep --force --sign - --entitlements "$DIR/Port42.entitlements" "$APP"
        echo "[build] Signed ad-hoc — TCC grants won't persist across rebuilds (no Apple Development cert): $BUNDLE_ID · data $DATA_DIR · gateway $GW_PORT"
    fi
fi
echo "[build] Ready: $APP"

# --- Release: package DMG, notarize, staple, update dist ---
if [ "$CONFIG" = "release" ] && [ "$SIGN_IDENTITY" != "-" ] && ! $NO_DMG; then
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
    # Any prior instance was already killed before packaging (see the kill block
    # above), so nothing to stop here — just launch the freshly built bundle.
    open "$APP"
fi

