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
    /// The caller presented no credential, or one that does not verify (slice-02 half two, 5b).
    ///
    /// Distinct from `permission_denied`, because the caller's repair is different in kind: a denied
    /// permission means "you are known and the user said no", and asking again may work. This means
    /// "I do not know who you are", and no amount of retrying changes that — the fix is to enrol.
    /// FR10 is why the message names where to do it.
    case authRequired = "auth_required"
    /// Verified, but the client has been revoked. Kept apart from `auth_required` for the same
    /// reason: the credential is real and re-sending it will never help.
    case authRevoked = "auth_revoked"
    /// A path the user never picked. Distinct from `permissionDenied`: the fix is a file picker, not
    /// a capability grant.
    case accessDenied = "access_denied"
    /// The write did not say what it composed against (R5).
    case tokenRequired = "token_required"
    /// The write composed against state the port has moved past (R3). Carries `current`.
    case staleWrite = "stale_write"
    /// A path that would leave the data directory.
    case pathEscape = "escape"

    // MARK: The transport itself failed (slice-02, Part 0's ERRORS row)
    //
    // These come from the GATEWAY, not from a bridge method, and until now they were bare English
    // strings: "no host available", "host is offline", "failed to reach host". A caller could not
    // branch on them, and a remote caller through a relay meets them BEFORE it meets anything the
    // app says. They live in this enum rather than in Go so there is one list, published once, and a
    // gate asserts the gateway cannot spell a code this enum does not have.

    /// Nothing is registered as the host: Port42 is not running, or not connected to this gateway.
    case noHost = "no_host"
    /// A host was registered and its connection is gone. Distinct from `no_host` because the repair
    /// differs: this one usually fixes itself, so retry rather than go looking for the app.
    case hostOffline = "host_offline"
    /// The gateway reached the host and the send failed. Rare, and not the caller's fault.
    case transportFailed = "transport_failed"

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

    // MARK: - What the caller should DO about it
    //
    // **THE DOCS ARE GENERATED FROM HERE** (GM, 2026-07-30: "why not do it now?").
    //
    // The two files an agent reads used to carry this grouping as hand-written prose, so one list
    // lived in three places and a test checked they agreed. A gate detects drift; it does not remove
    // the duplicate — the same argument that deleted the second token implementation rather than
    // pinning it. Now the enum is the only list, both documents render from it, and drift is not
    // expressible.
    //
    // It also closes a hole the old gate could not see. That test only asked whether a code APPEARS
    // somewhere in the text, so a code filed under the wrong repair, or described in a way that
    // contradicted its behaviour, passed. Here the grouping IS the declaration.

    /// What the caller does next. This is the only reason two codes are kept apart — the register's
    /// own rule, and why `access_denied` was un-merged from `permission_denied` and `no_surface`
    /// stayed apart from `not_found`.
    public enum Repair: String, CaseIterable {
        case retryWithCurrent   = "RETRY WITH e.current"
        case fixYourCall        = "FIX YOUR CALL"
        case theTarget          = "THE TARGET"
        case changeStateRetry   = "CHANGE STATE, RETRY"
        case askTheUser         = "ASK THE USER"
        case enrolFirst         = "ENROL FIRST"
        case waitOrAllowLonger  = "WAIT OR ALLOW LONGER"
        case theGateway         = "THE GATEWAY"
        case doNotRetry         = "DO NOT RETRY"
        case somethingFailed    = "SOMETHING FAILED"
        case rarelySeen         = "RARELY SEEN"

    /// A note for the WHOLE repair group, where one sentence covers every code in it.
    ///
    /// Added because rendering exposed a flaw the hand-written block did not have: four codes shared
    /// one explanation, and per-code guidance repeated it four times — output strictly worse than what
    /// it replaced. Generating from a model shows you where the model is wrong, which is the point.
    var groupNote: String {
        switch self {
        case .rarelySeen:
            return "each names a specific absence: no in-process implementation, no signed-in user, "
                 + "no conversation, or no LLM companion"
        case .theGateway:
            return "your call never reached Port42, so nothing was executed and nothing changed. "
                 + "Retrying is always safe"
        default: return ""
        }
    }
    }

    public var repair: Repair {
        switch self {
        case .tokenRequired, .staleWrite:                   return .retryWithCurrent
        case .missingArg, .badArg, .unknownMethod, .jsSyntax: return .fixYourCall
        case .notFound, .noSurface, .portPaused:            return .theTarget
        case .wrongState:                                   return .changeStateRetry
        case .permissionDenied, .accessDenied:              return .askTheUser
        case .authRequired, .authRevoked:                   return .enrolFirst
        case .timedOut, .aiTimeout, .jsTimeout:             return .waitOrAllowLonger
        case .unsupported:                                  return .doNotRetry
        case .io, .deviceError, .browserError, .aiError,
             .scriptError, .jsError, .methodFailed, .pathEscape: return .somethingFailed
        case .noBody, .noUser, .noMessages, .notLLM:        return .rarelySeen
        case .noHost, .hostOffline, .transportFailed:       return .theGateway
        }
    }

    /// A parenthetical shown beside the code, when the code alone is not enough to act on. Empty
    /// when the name says it.
    public var guidance: String {
        switch self {
        case .notFound:        return "no such port/session/window"
        case .noSurface:       return "it exists but has nothing live to write to yet — wait or respawn"
        case .wrongState:      return "already streaming, not streaming, no active capture, session limit reached — stop or close one, then call again"
        case .permissionDenied: return "a capability: they grant it"
        case .accessDenied:    return "a path they never picked: they pick a file"
        case .authRequired:    return "Port42 does not know who you are — the user adds a client in Settings -> Access and you send it as `Authorization: Bearer <token>`"
        case .authRevoked:     return "it knew you and the user withdrew it; ask them, do not retry — the credential is real, so re-sending it will never help"
        case .jsTimeout:       return "usually means you returned a long-lived promise from port_exec — return a plain value instead"
        case .unsupported:     return "this macOS cannot do it; no user action fixes it"
        case .scriptError:     return "your AppleScript/JXA"
        case .pathEscape:      return "path left the data directory"
        case .noHost:          return "Port42 is not running, or not connected to this gateway — start it"
        case .hostOffline:     return "it was there and its connection dropped; retry shortly"
        case .transportFailed: return "the gateway could not hand your call over; retry"
        default:               return ""
        }
    }

    /// The marker both documents carry where this block goes. Substituted at LOAD, so there is no
    /// regeneration step to forget and no committed copy to go stale.
    public static let docsMarker = "{{ERROR_CODES}}"

    /// Render the published block, wrapped to fit and indented to sit in either document.
    public static func publishedBlock(indent: String = "  ", width: Int = 96) -> String {
        var lines: [String] = []
        for repair in Repair.allCases {
            let codes = allCases.filter { $0.repair == repair }
            guard !codes.isEmpty else { continue }
            var body = codes.map { c in
                c.guidance.isEmpty ? c.wire : "\(c.wire) (\(c.guidance))"
            }.joined(separator: " · ")
            if !repair.groupNote.isEmpty { body += " — \(repair.groupNote)" }

            let label = repair.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)
            let lead = indent + label + " "
            let hang = indent + String(repeating: " ", count: 23)
            var current = lead
            for word in body.split(separator: " ").map(String.init) {
                if current.count + word.count + 1 > width, current != lead, current != hang {
                    lines.append(current); current = hang
                }
                current += (current == lead || current == hang) ? word : " " + word
            }
            lines.append(current)
        }
        return lines.joined(separator: "\n")
    }

    /// Substitute the block into a document that carries the marker. A document without one is
    /// returned unchanged, so this is safe to apply to any resource.
    public static func publish(into text: String, indent: String = "  ") -> String {
        text.replacingOccurrences(of: docsMarker, with: publishedBlock(indent: indent))
    }

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
