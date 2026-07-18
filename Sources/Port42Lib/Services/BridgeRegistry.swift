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
    /// Whether the calling-path adapters route to this method yet. Default true. Set false for a method
    /// that is extracted + unit-tested but whose live adapter switch waits on other work — e.g. `fs.*`,
    /// whose registry impl is a data-dir sandbox while port JS still relies on the picked-path model,
    /// reconciled in Phase 3 (picked-path grant on the principal). `bridgeHandles` excludes unwired
    /// methods, so they keep running on the old path until then.
    public let wired: Bool
    /// Self-describing metadata (the big-bang's single source): a human/model description and a
    /// JSON-Schema for the method's input, mirroring `BridgeStreamMethod`. `anthropicToolSchema`
    /// generates the tool-use schema from these, so `ToolDefinitions` can be flipped to generated and
    /// deleted. Defaulted empty so the field is additive; a method in the tool-parity set with empty
    /// metadata fails `BridgeSchemaParityTests`, which is how coverage is enforced (test, not compiler).
    public let description: String
    public let inputSchema: [String: Any]
    /// The single implementation. Named args in, one `BridgeValue` out, throws `BridgeError`.
    /// `@MainActor` because a body reaches into `AppState` (which is `@MainActor`), exactly as the
    /// two executors do today.
    public let run: @MainActor (Principal, BridgeArgs) async throws -> BridgeValue

    public init(permission: PortPermission?,
                paramNames: [String] = [],
                wired: Bool = true,
                description: String = "",
                inputSchema: [String: Any] = [:],
                run: @escaping @MainActor (Principal, BridgeArgs) async throws -> BridgeValue) {
        self.permission = permission
        self.paramNames = paramNames
        self.wired = wired
        self.description = description
        self.inputSchema = inputSchema
        self.run = run
    }
}

/// Canonical method name → its single implementation.
public typealias BridgeRegistry = [String: BridgeMethod]

// MARK: - BridgeStreamMethod (the streaming contract — item 8)
//
// `ai.complete` streams tokens and then resolves; `BridgeValue` is one-value-out, so streaming needs
// its own shape. A stream method yields intermediate tokens via `yield` and returns the FINAL value.
// Dispatch / principal / permission stay unified (same as `BridgeMethod`); only the delivery differs,
// and each calling-path adapter wires `yield` to its surface: port JS → `_tokenCallback`, gateway →
// chunked, tool-use → collect into the final text. This is what lets `ai.complete` join the registry
// instead of being a special case, and it is where the never-rejecting-bridge fix lands (a thrown
// `BridgeError` becomes a real reject, not a resolved `{error}`).
public struct BridgeStreamMethod {
    public let permission: PortPermission?
    public let paramNames: [String]
    /// Self-describing metadata (item 8 spike): a human/model description and a JSON-Schema for the
    /// method's input. `anthropicToolSchema` generates the tool-use schema from these instead of a
    /// hand-maintained parallel list — the pattern the big-bang rolls across every method.
    public let description: String
    public let inputSchema: [String: Any]
    /// Streams tokens via `yield`, returns the final `BridgeValue`. Throws `BridgeError`.
    public let run: @MainActor (Principal, BridgeArgs, _ yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue

    public init(permission: PortPermission?,
                paramNames: [String] = [],
                description: String = "",
                inputSchema: [String: Any] = [:],
                run: @escaping @MainActor (Principal, BridgeArgs, _ yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue) {
        self.permission = permission
        self.paramNames = paramNames
        self.description = description
        self.inputSchema = inputSchema
        self.run = run
    }
}

/// Generate an Anthropic tool-use schema from a method's self-describing metadata. One place (the
/// registration) produces the tool schema, instead of a hand-written `ToolDefinitions` entry
/// maintained in parallel. Snake tool name comes from `ToolNaming` (so the override table is proven
/// complete by parity). Overloaded for one-shot and streaming methods; both share this core.
@MainActor
public func anthropicToolSchema(canonical: String,
                                description: String,
                                inputSchema: [String: Any]) -> [String: Any] {
    [
        "name": ToolNaming.tool(fromCanonical: canonical),
        "description": description,
        "input_schema": inputSchema
    ]
}

@MainActor
public func anthropicToolSchema(canonical: String, method: BridgeMethod) -> [String: Any] {
    anthropicToolSchema(canonical: canonical, description: method.description, inputSchema: method.inputSchema)
}

@MainActor
public func anthropicToolSchema(canonical: String, method: BridgeStreamMethod) -> [String: Any] {
    anthropicToolSchema(canonical: canonical, description: method.description, inputSchema: method.inputSchema)
}

/// Canonical method name → its streaming implementation (separate from the one-shot registry).
public typealias BridgeStreamRegistry = [String: BridgeStreamMethod]
