import Foundation

// MARK: - BridgeArgs
//
// The one argument type a bridge method body reads from, so bodies stop hand-parsing `[String: Any]`
// (and stop the two paths parsing differently). The two surfaces deliver arguments in two shapes,
// and this normalizes them:
//
//   tool-use / gateway  → a NAMED dict already ({ "id": "…", "version": 3 }); use `init(_:)`.
//   port JS             → a POSITIONAL array (`port42.port.getHtml(id)` → ["…"]); use
//                         `init(positional:names:)`, zipping the array against the method's parameter
//                         names (carried on `BridgeMethod.paramNames`).
//
// This positional-vs-named split is a real divergence the unification has to absorb: a canonical body
// takes named args, and the port-JS adapter is the one place that maps positional → named.

public struct BridgeArgs {
    private let raw: [String: Any]

    /// Named form (tool-use / gateway): the JSON object as-is.
    public init(_ raw: [String: Any]) {
        self.raw = raw
    }

    /// Positional form (port JS): zip a positional argument array against the method's parameter
    /// names. Extra positional args past the names are dropped; missing ones are simply absent.
    public init(positional args: [Any], names: [String]) {
        var dict: [String: Any] = [:]
        for (i, name) in names.enumerated() where i < args.count {
            dict[name] = args[i]
        }
        self.raw = dict
    }

    public var isEmpty: Bool { raw.isEmpty }
    public func any(_ key: String) -> Any? { raw[key] }
    public var dictionary: [String: Any] { raw }

    // Lenient readers: accept the obvious cross-type coercions the two surfaces produce (JS numbers
    // arrive as Double; a gateway JSON int as Int; a stringified number from a shell caller).
    public func string(_ key: String) -> String? { raw[key] as? String }

    public func bool(_ key: String) -> Bool? {
        if let b = raw[key] as? Bool { return b }
        if let i = raw[key] as? Int { return i != 0 }
        return nil
    }

    public func int(_ key: String) -> Int? {
        if let i = raw[key] as? Int { return i }
        if let d = raw[key] as? Double { return Int(d) }
        if let s = raw[key] as? String { return Int(s) }
        return nil
    }

    public func double(_ key: String) -> Double? {
        if let d = raw[key] as? Double { return d }
        if let i = raw[key] as? Int { return Double(i) }
        if let s = raw[key] as? String { return Double(s) }
        return nil
    }

    public func object(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }
    public func array(_ key: String) -> [Any]? { raw[key] as? [Any] }

    // Required readers: throw a uniform BridgeError instead of each body inventing its own message.
    public func requireString(_ key: String) throws -> String {
        guard let v = string(key) else { throw BridgeError.missingArg(key) }
        return v
    }

    /// **PRESENCE, not type or emptiness** — the reader for a required argument whose value may
    /// legitimately be anything, including an explicit JSON null.
    ///
    /// `port.push` declared `data` required and then wrote `args.any("data") ?? NSNull()`, so a push
    /// naming the wrong param typed the string `null` into a live shell and answered `ok:true`
    /// (2026-07-26). The typed readers could not express what that body needed: `requireString`
    /// refuses a web port's perfectly good object payload, and `any` refuses nothing at all.
    ///
    /// The distinction this rests on is real on both surfaces. `init(positional:names:)` only assigns
    /// keys for indices the caller supplied, so an omitted argument leaves NO key, while a JS or JSON
    /// `null` arrives as `NSNull` under a key that IS present. Absent and null are different acts and
    /// the caller meant different things by them.
    public func requirePresent(_ key: String) throws -> Any {
        guard let v = raw[key] else { throw BridgeError.missingArg(key) }
        return v
    }

    /// Is the key present at all, whatever it holds. Companion to `requirePresent` for the bodies
    /// that branch rather than throw.
    public func has(_ key: String) -> Bool { raw[key] != nil }

    public func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw BridgeError.missingArg(key) }
        return v
    }
}
