import Foundation
import GhosttyKit

// Step 1 probe: confirms GhosttyKit.xcframework is linked and its symbols
// resolve at runtime. ghostty_info() is a pure function (no app/surface
// setup, no mandatory callbacks) that returns the embedded Ghostty version
// and build mode — the cheapest possible call that actually exercises the
// static archive. Logging a real version string IS the linkage proof;
// because GhosttyKit ships as a static .a, it will NOT appear in
// `otool -L` (static symbols are folded into the binary). Verify with
// `nm <binary> | grep ghostty_info` instead.
@discardableResult
public func ghosttyProbe() -> Bool {
    let info = ghostty_info()

    let version: String
    if let ptr = info.version, info.version_len > 0 {
        version = ptr.withMemoryRebound(to: UInt8.self, capacity: Int(info.version_len)) {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(info.version_len)), as: UTF8.self)
        }
    } else {
        version = "unknown"
    }

    let mode: String
    switch info.build_mode {
    case GHOSTTY_BUILD_MODE_DEBUG: mode = "debug"
    case GHOSTTY_BUILD_MODE_RELEASE_SAFE: mode = "release-safe"
    case GHOSTTY_BUILD_MODE_RELEASE_FAST: mode = "release-fast"
    case GHOSTTY_BUILD_MODE_RELEASE_SMALL: mode = "release-small"
    default: mode = "unknown"
    }

    NSLog("[Port42] GhosttyKit probe: true (version=%@, build=%@)", version, mode)
    return true
}
