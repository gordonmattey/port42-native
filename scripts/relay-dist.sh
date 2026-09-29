#!/bin/bash
# Build the relay's release binaries (nautilus Phase 4.9: a relay anyone can run).
#
#   scripts/relay-dist.sh [version]      # → dist/relay/port42-relay-<version>-<os>-<arch>.tar.gz (.zip for
#                                        #   Windows) + SHA256SUMS
#
# Static, no cgo: Linux x86_64 and ARM64, macOS ARM64 and x86_64, Windows x86_64 and ARM64. The macOS binaries are signed with the
# Developer ID when that identity is in the Keychain (a downloaded unsigned binary is refused by
# Gatekeeper); elsewhere they are left unsigned and the script says so. Nothing is uploaded: the GitHub
# workflow (.github/workflows/relay.yml) attaches these to a `relay-v*` release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
OUT="dist/relay"
rm -rf "$OUT"; mkdir -p "$OUT"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"   # the Keychain profile build.sh notarizes the app with
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o 'Developer ID Application: [^"]*' | head -1 || true)"

for target in linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64 windows/arm64; do
  os="${target%/*}"; arch="${target#*/}"
  name="port42-relay-${VERSION}-${os}-${arch}"
  exe="port42-relay"; [ "$os" = windows ] && exe="port42-relay.exe"
  mkdir -p "$OUT/$name"
  (cd gateway && CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" \
     go build -trimpath -ldflags="-s -w" -o "../$OUT/$name/$exe" ./cmd/port42-relay)
  if [ "$os" = darwin ]; then
    if [ -n "$IDENTITY" ]; then
      codesign --force --options runtime --timestamp --sign "$IDENTITY" "$OUT/$name/port42-relay"
      # Notarize as well (BLD-10), so Gatekeeper accepts the download without a right-click Open. A
      # bare binary cannot be stapled; Gatekeeper checks the ticket online on first run.
      if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        (cd "$OUT/$name" && ditto -c -k --keepParent port42-relay ../"$name-notarize.zip")
        xcrun notarytool submit "$OUT/$name-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
        rm -f "$OUT/$name-notarize.zip"
      else
        echo "[relay-dist] no '$NOTARY_PROFILE' notary profile: $name is signed but not notarized" >&2
      fi
    else
      echo "[relay-dist] no Developer ID identity: $name is unsigned" >&2
    fi
  fi
  cp gateway/relay-README.txt "$OUT/$name/README.txt"
  if [ "$os" = windows ]; then
    (cd "$OUT" && zip -qr "$name.zip" "$name"); pkg="$name.zip"
  else
    tar -C "$OUT" -czf "$OUT/$name.tar.gz" "$name"; pkg="$name.tar.gz"
  fi
  rm -rf "${OUT:?}/$name"
  echo "[relay-dist] $pkg"
done
(cd "$OUT" && shasum -a 256 -- *.tar.gz *.zip > SHA256SUMS)
echo "[relay-dist] done: $OUT"
