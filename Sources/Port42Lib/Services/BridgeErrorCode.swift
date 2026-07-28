import Foundation

// MARK: - What a caller can BRANCH on (architecture-invariants.md §5)
//
// A failure's `code` is the machine-readable half of an error; the message is for a human. Until
// now every code was a STRING LITERAL at its throw site, which is why the set drifted the way sets
// of literals always do. Measured 2026-07-28: twenty distinct codes, with `bad_args` beside
// `bad_arg`, `access_denied` beside `permission_denied`, and `no_port` beside `not_found` — same
// meaning, different spelling, so a caller matching one silently misses the other.
//
// `BridgeError` already had canonical helpers (`missingArg`, `notFound`, `badArg`,
// `permissionDenied`) and nothing routed through them, which is the register's recurring shape: a
// guarantee that depends on every author having remembered.
//
// THIS GOT MORE IMPORTANT, NOT LESS, WHEN CAS SHIPPED. R3 made errors actionable (`stale_write`
// carries `current`), R5 made a refusal the ordinary path rather than the rare one, and the whole
// conflict-then-retry design rests on a caller recognising WHICH refusal it got. An agent that
// cannot branch on failure cannot self-correct.
//
// WHAT WAS COLLAPSED, and what deliberately was not. Only true synonyms merged:
//
//     bad_args      → bad_arg              (a plural typo, not a distinction)
//     no_port       → not_found            (a port that does not exist IS not found)
//
// `access_denied` was ON that list and came back off it, because the test suite caught the merge and
// the criterion is the caller's FIX, not the English. `permission_denied` means a capability was not
// granted, and the user grants it; `access_denied` means a specific path was never picked, and the
// user picks a file. Two different repairs, so two codes.
//
// `no_surface` stayed separate from `not_found`, because "this terminal exists but has no live
// surface to write to" is a different situation with a different fix, and flattening it would cost
// a caller the ability to tell "wrong id" from "not ready". Same for `no_body`, `no_user`,
// `no_messages`: each names a specific absence a caller can act on.

/// Every code the bridge can return. One definition, so a code is a VALUE and not a literal — and
/// so the set is enumerable, which is what lets it be documented without going stale.
public enum BridgeErrorCode: String, CaseIterable, Equatable {

    // MARK: The caller got the request wrong
    case missingArg = "missing_arg"
    case badArg = "bad_arg"
    case unknownMethod = "unknown_method"

    // MARK: The target is not there (or not ready)
    case notFound = "not_found"
    /// The port exists; it has no live surface to write into (a terminal that has not spawned, or
    /// whose surface was torn down). Deliberately NOT `not_found`: the fix is to wait or respawn,
    /// not to correct the id.
    case noSurface = "no_surface"
    case portPaused = "port_paused"
    case noBody = "no_body"
    case noUser = "no_user"
    case noMessages = "no_messages"

    // MARK: Refused on purpose
    case permissionDenied = "permission_denied"
    /// A path the user never picked. Distinct from `permissionDenied`: the fix is a file picker, not
    /// a capability grant.
    case accessDenied = "access_denied"
    /// The write did not say what it composed against (R5).
    case tokenRequired = "token_required"
    /// The write composed against state the port has moved past (R3). Carries `current`.
    case staleWrite = "stale_write"
    /// A path that would leave the data directory.
    case pathEscape = "escape"

    // MARK: It went wrong out there
    case io
    case deviceError = "device_error"
    case browserError = "browser_error"
    case aiError = "ai_error"
    case aiTimeout = "ai_timeout"
    case notLLM = "not_llm"

    // MARK: port.exec
    /// Caller-supplied AppleScript or JXA failed. The parallel of `jsError`: `automation.*` runs
    /// source the caller wrote, exactly as `port.exec` does, so the failure is the SCRIPT's and not
    /// the device's. Measured live — `run_applescript` with `error "boom"` fell through to
    /// `method_failed`, which told a caller nothing about whose fault it was.
    case scriptError = "script_error"

    /// The JS did not compile. Usually a multi-statement body with no explicit `return`.
    case jsSyntax = "js_syntax"
    case jsError = "js_error"
    case jsTimeout = "js_timeout"

    /// The call is fine but the thing is in the wrong state for it: already streaming, not
    /// streaming, no active capture, session limit reached. **The caller can recover on its own** by
    /// changing that state and retrying, which is exactly what `device_error` hides.
    case wrongState = "wrong_state"

    /// It ran too long and was abandoned. Generic ON PURPOSE, unlike `js_timeout` and `ai_timeout`,
    /// which stay separate because their FIX is specific rather than "wait and retry": a JS timeout
    /// almost always means the body returned a long-lived promise, and an AI timeout is about the
    /// model call itself. Where the fix is just "retry, or allow longer", one code says it.
    case timedOut = "timed_out"

    /// This build of macOS cannot do it (`screen.record` needs macOS 15). Distinct because it is the
    /// one failure a caller must NOT retry, and no user action fixes it either.
    case unsupported

    /// A failure a body reported without naming a family. Better than nothing: a caller can at least
    /// tell "this did not work" from "this worked", which is the distinction that was missing.
    case methodFailed = "method_failed"

    public var wire: String { rawValue }

    /// The code for a failure reported by a method that did not name one, derived from the method's
    /// FAMILY rather than its individual message.
    ///
    /// This exists because ~90 device-bridge failures are returned as `["error": "…"]` dictionaries
    /// rather than thrown, so they arrive with nothing to branch on. The message is the only thing
    /// those sites produce, and a message cannot be parsed into a code without guessing. The family
    /// can: a screen failure is a device failure whatever went wrong inside it.
    ///
    /// Deliberately coarse. A per-site code is BETTER (a permission failure inside ScreenBridge
    /// deserves `permission_denied`, not `device_error`), and sharpening one is a one-line change on
    /// a surface that now carries a code at all. This is the floor, not the ceiling.
    public static func forMethod(_ method: String) -> BridgeErrorCode {
        switch method.split(separator: ".").first.map(String.init) ?? "" {
        case "screen", "camera", "audio", "clipboard", "notify": return .deviceError
        case "browser":                                          return .browserError
        case "automation":                                       return .scriptError
        case "ai":                                               return .aiError
        case "fs", "files", "file":                              return .io
        default:                                                 return .methodFailed
        }
    }

    /// True when a caller can fix this by re-reading state and trying once more — the
    /// conflict-then-retry loop CAS was built around. The single most useful question an agent asks
    /// of a failure, and it should not have to keep its own list of which codes qualify.
    public var isRetryableWithCurrentState: Bool {
        self == .staleWrite || self == .tokenRequired
    }
}
