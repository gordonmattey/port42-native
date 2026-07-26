import Foundation

// MARK: - BridgeValue
//
// The one result shape every bridge method returns (API/tool-use unification, Phase 0). Each calling
// path renders it for its own surface, and only the tool-use rendering differs from plain JSON:
//
//   port JS   → toJSONObject()  (resolved into the page as a native JS value)
//   gateway   → toJSONObject()  (returned as JSON)
//   tool-use  → toToolBlocks()  (a text block for a string, a JSON text block for structured data,
//                                an image block for binary — what the model can read)
//
// This is what ends the split the todo names in one line: `ports.list` returned an array to a port
// and a text blob to an agent. With one BridgeValue, the array is the array everywhere; only the
// wrapper an agent needs is added at the edge.

public indirect enum BridgeValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([BridgeValue])
    case object([String: BridgeValue])
    /// Base64-carrying binary (the image methods: `screen.capture`, `camera.capture`). `mime` names
    /// the content (e.g. "image/png") so the tool-use surface can wrap it as a real image block.
    case data(base64: String, mime: String)

    /// Foundation JSON-compatible value. Used by the port-JS surface (native value into the page)
    /// and the gateway (JSON out) — they share this encoder; only tool-use differs (see
    /// `toToolBlocks`). `.data` becomes its base64 string, matching the current `{ image, width,
    /// height }` API where `image` is the base64 PNG.
    public func toJSONObject() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.toJSONObject() }
        case .object(let o): return o.mapValues { $0.toJSONObject() }
        case .data(let base64, _): return base64
        }
    }

    /// Build a BridgeValue from a Foundation JSON value (e.g. the output of `JSONSerialization`).
    /// Handles the NSNumber bool-vs-number trap so `true` does not come back as `1`.
    public static func fromJSONObject(_ obj: Any) -> BridgeValue {
        if obj is NSNull { return .null }
        if let n = obj as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 9e15 { return .int(n.intValue) }
            return .double(d)
        }
        if let s = obj as? String { return .string(s) }
        if let a = obj as? [Any] { return .array(a.map { fromJSONObject($0) }) }
        if let o = obj as? [String: Any] { return .object(o.mapValues { fromJSONObject($0) }) }
        return .null
    }

    /// Anthropic tool-result content blocks. A bare string is prose the model reads directly; a
    /// top-level image is an image block so the model can see it; anything structured is compact
    /// JSON in a text block so the model can parse it.
    public func toToolBlocks() -> [[String: Any]] {
        switch self {
        case .string(let s):
            return [["type": "text", "text": s]]
        case .data(let base64, let mime):
            return [["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]]]
        default:
            let obj = toJSONObject()
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed, .sortedKeys]),
               let s = String(data: d, encoding: .utf8) {
                return [["type": "text", "text": s]]
            }
            return [["type": "text", "text": "\(obj)"]]
        }
    }
}

// MARK: - BridgeError
//
// One error type, rendered once per surface. A method body throws it; the adapter renders it: JS and
// the gateway get `{ error, code }` (the existing `{error}` shape plus a machine code), tool-use gets
// an "Error: …" text block (the existing tool error shape). This is where the never-rejecting bridge
// gets fixed later (todo): the JS adapter can choose to `_reject` on a throw instead of resolving the
// error object — one place, in Phase 4.

public struct BridgeError: Error, Equatable {
    /// Machine-readable, e.g. "missing_arg", "not_found", "permission_denied".
    public let code: String
    /// Human-readable, shown to the caller.
    public let message: String
    /// Machine-readable extras the caller needs in order to ACT on the error, surfaced as top-level
    /// keys beside `code`. Added for R3's `stale_write`, which carries the port's `current` token:
    /// an error that only says "you are stale" leaves a caller stuck, while one that says what the
    /// current value IS turns the failure into a one-retry self-correction. Empty for every error
    /// where the code alone is the whole story.
    public let details: [String: String]

    public init(code: String, message: String, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    public func toJSONObject() -> Any {
        var o: [String: Any] = ["error": message, "code": code]
        for (k, v) in details where k != "error" && k != "code" { o[k] = v }
        return o
    }

    public func toToolBlocks() -> [[String: Any]] {
        // The details go in the TEXT too, not just the JSON: a companion reads prose, and an error
        // it cannot act on costs a whole turn.
        let extra = details.isEmpty ? ""
            : " (" + details.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + ")"
        return [["type": "text", "text": "Error: \(message)\(extra)"]]
    }

    // Common cases, so bodies don't each invent their own wording.
    public static func missingArg(_ key: String) -> BridgeError {
        BridgeError(code: "missing_arg", message: "missing required argument '\(key)'")
    }
    public static func notFound(_ what: String) -> BridgeError {
        BridgeError(code: "not_found", message: "\(what) not found")
    }
    public static func permissionDenied(_ perm: String) -> BridgeError {
        BridgeError(code: "permission_denied", message: "Permission denied: \(perm)")
    }
    public static func badArg(_ message: String) -> BridgeError {
        BridgeError(code: "bad_arg", message: message)
    }
}
