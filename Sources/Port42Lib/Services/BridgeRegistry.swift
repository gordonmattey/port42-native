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
    /// The permission this method requires, or nil if it needs none. THE permission table — the
    /// two old parallel copies (the PortPermission method switch and the ToolDefinitions table)
    /// are both dead; nothing else may map methods to permissions.
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
    /// Whether this method is exposed as an LLM tool (i.e. appears in the generated `ToolDefinitions`).
    /// Default true. False for methods that are registry-reachable but not companion tools:
    /// `audio.play`/`audio.stop` (no tool today) and the streaming `ai.complete`/`companions.invoke`
    /// (a companion uses its own model, it does not call these as tools).
    public let toolExposed: Bool
    /// Self-describing metadata (the big-bang's single source): a human/model description and a
    /// JSON-Schema for the method's input, mirroring `BridgeStreamMethod`. `anthropicToolSchema`
    /// generates the tool-use schema from these, so `ToolDefinitions` can be flipped to generated and
    /// deleted. Defaulted empty so the field is additive; a method in the tool-parity set with empty
    /// metadata fails `BridgeSchemaParityTests`, which is how coverage is enforced (test, not compiler).
    public let description: String
    public let inputSchema: [String: Any]
    /// RIGHT-OF-WAY (L2): the paramName carrying the port this method WRITES to, or nil for a read.
    /// Declared here, beside `permission`, because it is the same shape of decision and belongs at
    /// the same choke point — a new write verb that forgets to declare it is caught by
    /// `BridgeParamConsistencyTests` rather than silently escaping the lease.
    /// Reading is not driving: `getHtml`/`history`/`info`/`position`/`subscribe` stay nil.
    public let writesTarget: String?
    /// The single implementation. Named args in, one `BridgeValue` out, throws `BridgeError`.
    /// `@MainActor` because a body reaches into `AppState` (which is `@MainActor`), exactly as the
    /// two executors do today.
    public let run: @MainActor (Principal, BridgeArgs) async throws -> BridgeValue

    public init(permission: PortPermission?,
                paramNames: [String] = [],
                writesTarget: String? = nil,
                wired: Bool = true,
                toolExposed: Bool = true,
                description: String = "",
                inputSchema: [String: Any] = [:],
                run: @escaping @MainActor (Principal, BridgeArgs) async throws -> BridgeValue) {
        self.permission = permission
        self.paramNames = paramNames
        self.wired = wired
        self.toolExposed = toolExposed
        self.description = description
        self.inputSchema = inputSchema
        self.writesTarget = writesTarget
        self.run = run
    }
}

public extension BridgeMethod {
    /// R3 — give this method the optional `expect` token if it WRITES.
    ///
    /// Applied centrally to the finished registry rather than typed into eight declarations, for the
    /// same reason `writesTarget` is declared rather than scattered: a new write verb must not be
    /// able to arrive without CAS. Declaring it per-method would make compare-and-swap depend on
    /// whoever added the verb having remembered, which is the failure mode this whole phase exists
    /// to stop (finding 7).
    ///
    /// `expect` is APPENDED to `paramNames`, never inserted. `BridgeArgs(positional:names:)` maps
    /// positional args in order, so a trailing name cannot disturb an existing positional JS caller;
    /// anywhere else would silently reassign their arguments (finding 5).
    func acceptingExpect() -> BridgeMethod {
        guard writesTarget != nil, !paramNames.contains(PortActivity.expectParam) else { return self }
        var schema = inputSchema
        if !schema.isEmpty {
            var props = schema["properties"] as? [String: Any] ?? [:]
            props[PortActivity.expectParam] = [
                "type": "string",
                // Names `ports_list`, NOT `port_info`: port_info is `toolExposed: false`, so a
                // companion can never call it — pointing there would send the model to a tool that
                // does not exist for it. ports_list is the call it already makes to find the id.
                "description": "Optional. The port's `token` from ports_list, as it was when you "
                             + "composed this write. If the port has changed since, the write is "
                             + "refused with code 'stale_write' carrying the current token — retry "
                             + "with that instead of clobbering whoever moved it."
            ] as [String: Any]
            schema["properties"] = props
        }
        return BridgeMethod(permission: permission,
                            paramNames: paramNames + [PortActivity.expectParam],
                            writesTarget: writesTarget,
                            wired: wired,
                            toolExposed: toolExposed,
                            description: description,
                            inputSchema: schema,
                            run: run)
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
    /// Whether this method is exposed as an LLM tool. False for `ai.complete`/`companions.invoke`
    /// (a companion uses its own model, not these as tools). See `BridgeMethod.toolExposed`.
    public let toolExposed: Bool
    /// Streams tokens via `yield`, returns the final `BridgeValue`. Throws `BridgeError`.
    public let run: @MainActor (Principal, BridgeArgs, _ yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue

    public init(permission: PortPermission?,
                paramNames: [String] = [],
                toolExposed: Bool = true,
                description: String = "",
                inputSchema: [String: Any] = [:],
                run: @escaping @MainActor (Principal, BridgeArgs, _ yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue) {
        self.permission = permission
        self.paramNames = paramNames
        self.toolExposed = toolExposed
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
