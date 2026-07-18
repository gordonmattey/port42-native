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

    public func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw BridgeError.missingArg(key) }
        return v
    }
}
