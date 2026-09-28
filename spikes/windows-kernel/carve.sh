#!/bin/bash
# Spike: how much of the kernel is actually platform-neutral?
#
# The claim under test is that Port42 splits into a kernel and a shell, and that the kernel does not
# depend on Apple frameworks. Today that is a property of a document, not of the compiler: kernel and
# shell are one target, so nothing stops a service importing AppKit.
#
# This carves the candidate kernel into its own SwiftPM package and builds it. On macOS the build
# catches references that reach OUT of the kernel (a service that needs AppState). On Linux and
# Windows it catches the rest. Nothing is copied into git: the package is generated here and ignored.
#
# Usage: ./carve.sh [--build]
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
OUT="$PWD/generated"
SRC="$OUT/Sources/Port42Kernel"

# Frameworks that make a file Apple-only. Security is here because its Keychain use goes with D9.
# Combine is on this list for the same reason as AppKit: it is Apple-only, and a service that is an
# ObservableObject is bound to Apple's observation model even when it imports no UI framework. Found
# by the Linux build, not by reading. CryptoKit is NOT here: swift-crypto is API-compatible and the
# conditional import below is the real fix, so those files stay in and are measured.
APPLE='^import (AppKit|SwiftUI|WebKit|GhosttyKit|ScreenCaptureKit|AVFoundation|AVKit|Speech|UserNotifications|Sparkle|AuthenticationServices|CoreMedia|PostHog|Security|Combine)'

# Deleted by nautilus Phase 1, so not part of the kernel that will exist. Carving them in would
# measure the cost of porting code that is about to go.
DOOMED='SyncService|LLMEngine|GeminiEngine|LLMBackend|LLMStreamCollector|BridgeServiceAI|AgentRouterLLM|AppState\+PortAI|AgentAuth|BridgeServiceKeeper|TunnelService|AppleAuthService|AgentInvite|OpenClawService|ChannelCrypto|SpaceCrypto'

rm -rf "$OUT"; mkdir -p "$SRC"
kept=0; lines=0
for f in $(find "$ROOT/Sources/Port42Lib/Services" "$ROOT/Sources/Port42Lib/Models" -name '*.swift' | sort); do
  base=$(basename "$f" .swift)
  grep -qE "$APPLE" "$f" && continue
  echo "$base" | grep -qE "^($DOOMED)$" && continue
  cp "$f" "$SRC/"
  # CryptoKit is Apple-only; swift-crypto is API-compatible. This is the shim a real port would use,
  # applied to the copy so the spike measures the move without editing the tree.
  # Portability shims, applied to the COPY. awk rather than perl or sed -i: BSD sed cannot put a
  # newline in a replacement and the Windows runner's perl behaved differently, which silently left
  # the shim unapplied and cost a CI round to notice.
  shim() { # file, module-to-guard, optional replacement module
    awk -v m="$2" -v alt="$3" '{
      if ($0 == "import " m) {
        print "#if canImport(" m ")"; print "import " m
        if (alt != "") { print "#else"; print "import " alt }
        print "#endif"
      } else print
    }' "$1" > "$1.shim" && mv "$1.shim" "$1"
  }
  # CryptoKit is Apple-only; swift-crypto is API-compatible. CoreGraphics is Apple-only but its
  # geometry types come from Foundation elsewhere, so guarding the import is the whole fix.
  shim "$SRC/$base.swift" CryptoKit Crypto
  shim "$SRC/$base.swift" CoreGraphics ""
  kept=$((kept + 1)); lines=$((lines + $(wc -l < "$f")))
done

mkdir -p "$OUT/Sources/GRDBProbe"
cat > "$OUT/Sources/GRDBProbe/Probe.swift" <<'PROBE'
import GRDB
// Question 2 of the spike: does GRDB build on this platform at all? DatabaseService is 2,133 lines
// on top of it, so the answer decides whether persistence ports or is rewritten. Kept as its own
// target so a GRDB failure cannot be mistaken for a kernel failure.
public enum GRDBProbe {
    public static func works() throws -> Int {
        let q = try DatabaseQueue()
        return try q.write { db in
            try db.execute(sql: "CREATE TABLE t (a INTEGER)")
            try db.execute(sql: "INSERT INTO t VALUES (42)")
            return try Int.fetchOne(db, sql: "SELECT a FROM t") ?? 0
        }
    }
}
PROBE

# One measured surgery, applied to the COPY only. BridgeValue distinguishes an NSNumber holding a
# bool from one holding a number using CFGetTypeID, which does not exist off Apple. It is four lines,
# and the Linux build showed it takes BridgeArgs, BridgeRegistry, NotifyBus and PublishedDocs down
# with it: one Apple-ism blocking the whole registry layer. objCType is the portable equivalent and
# swift-corelibs-foundation implements it. Patched here to measure what fixing it would unlock, NOT
# proposed as the final form.
if [ -f "$SRC/BridgeValue.swift" ]; then
  perl -0pi -e 's/if CFGetTypeID\(n\) == CFBooleanGetTypeID\(\) \{ return \.bool\(n\.boolValue\) \}/#if canImport(Darwin)\n            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }\n            #else\n            if String(cString: n.objCType) == "c" { return .bool(n.boolValue) }\n            #endif/' "$SRC/BridgeValue.swift"
fi

cat > "$OUT/Package.swift" <<'SPM'
// swift-tools-version: 5.9
import PackageDescription

// Generated by spikes/windows-kernel/carve.sh. Two targets, two questions: does the kernel compile
// off Apple, and does GRDB. Deliberately no platform restriction beyond the Apple deployment floor,
// so the compiler decides rather than a comment.
let package = Package(
    name: "Port42Kernel",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "Port42Kernel", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
        ]),
        .target(name: "GRDBProbe", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
SPM

echo "carved $kept files, $lines lines -> $OUT"
if [ "${1:-}" = "--build" ]; then
  cd "$OUT" && swift build 2>&1 | tail -40
fi

if [ "${1:-}" = "--prune" ]; then
  cd "$OUT"
  for round in 1 2 3 4 5 6 7 8; do
    out=$(swift build 2>&1 || true)
    bad=$(echo "$out" | grep -oE "/Port42Kernel/[A-Za-z+0-9]+\.swift[^ ]*: error:" \
          | sed -E "s|/Port42Kernel/([A-Za-z+0-9]+)\.swift.*|\1|" | sort -u)
    if [ -z "$bad" ]; then echo "GREEN after $((round-1)) prune round(s)"; break; fi
    for b in $bad; do echo "  round $round: dropping $b"; rm -f "Sources/Port42Kernel/$b.swift"; done
  done
  echo "--- survives standalone ---"
  ls Sources/Port42Kernel | wc -l | tr -d " " | xargs -I{} echo "{} files"
  cat Sources/Port42Kernel/*.swift | wc -l | tr -d " " | xargs -I{} echo "{} lines"
fi

# --prune: drop files that reference symbols outside the carve, repeatedly, until the build is green.
# What survives is the part of the kernel that is ALREADY self-contained; what was dropped is the
# list of seams to cut. Reported, never silent.
