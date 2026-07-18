import Foundation

// MARK: - BridgeRegistry (skeleton — Phase 0)
//
// One entry per canonical method: the permission it needs, the parameter names (so the port-JS
// adapter can turn a positional call into named `BridgeArgs`), and the body. Phase 0 defines the
// shape; Phase 1 moves the two switch statements' bodies into `buildRegistry` one method-family at a
// time, verified against the old paths by `BridgeParityHarness`.
//
// The body signature deliberately omits `AppState`: Phase 1 builds the registry from an AppState and
// each closure captures it, exactly as the two executors capture it today. Keeping AppState out of
// the type here lets Phase 0 compile and be tested with no app dependency.

public struct BridgeMethod {
    /// The permission this method requires, or nil if it needs none. Replaces the two divergent
    /// tables (`PortPermission.permissionForMethod` and `ToolDefinitions.permission(for:)`).
    public let permission: PortPermission?
    /// Positional parameter names, in call order, for the port-JS surface (which calls positionally).
    /// Empty for methods only ever called with named args.
    public let paramNames: [String]
    /// The single implementation. Named args in, one `BridgeValue` out, throws `BridgeError`.
    public let run: (Principal, BridgeArgs) async throws -> BridgeValue

    public init(permission: PortPermission?,
                paramNames: [String] = [],
                run: @escaping (Principal, BridgeArgs) async throws -> BridgeValue) {
        self.permission = permission
        self.paramNames = paramNames
        self.run = run
    }
}

/// Canonical method name → its single implementation.
public typealias BridgeRegistry = [String: BridgeMethod]
