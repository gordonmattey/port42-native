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
    /// **Does this write REPLACE the port's state, rather than append to it?** (2026-08-01, G1.)
    ///
    /// Decides whether a write announces `state` to subscribers. The distinction is the one
    /// `design-append-writes.md` names: `update`/`patch`/`rename`/`restore` replace what the port
    /// shows, so a watcher must re-read; `push`/`exec` deliver input, and a watcher converges by
    /// receiving that same input, exactly as the port's own JS does.
    ///
    /// **Declared rather than inferred**, and NOT defaulted to true for every write, because the
    /// first version of G1 announced on every write and drowned the topic: a terminal keystroke is a
    /// write, and `PortPresenceGateTests` caught it as "a burst of typing publishes ONCE". That test
    /// was right, and it was written about the driver rule for the same reason.
    public let replacesState: Bool
    /// **Does this write need the target's surface to be ALIVE?** (2026-07-29.)
    ///
    /// GM measured the fourth instance of register §5's class: four `port.push` calls to a terminal
    /// whose app had exited each returned `{"ok": true}` and advanced the activity token
    /// (`:0 → :1 → :3 → :5 → :8`), and nothing ran. The port was in `ports.list` throughout, because
    /// the DB row outlived the process. "Target present, argument fine, BACKING PROCESS DEAD", which
    /// neither of the earlier two fixes reached — those covered "target absent" and "argument wrong".
    ///
    /// **Worse than a plain lie, because it corrupts the token.** The counter moved, so a later CAS
    /// write believes it raced a real mutation. The register's own words: a token claims *has this
    /// port changed since I looked*, and that claim is false for any mutation that does not count —
    /// here a mutation counted that never happened.
    ///
    /// **Declared per verb rather than enforced for all writes**, because it is genuinely not
    /// uniform: `restore`, `rename` and `patch` operate on the STORED port and are documented to work
    /// on a DB-only one (`PortSurfaceKind.unknown` exists for exactly that). Only a write that
    /// DELIVERS to a live surface needs it. Declared here beside `writesTarget` for the same reason
    /// that one is: it is the same shape of decision, at the same choke point, and enforced once in
    /// `applyWriteSideEffects` so no verb can escape it.
    public let needsLiveSurface: Bool
    /// The single implementation. Named args in, one `BridgeValue` out, throws `BridgeError`.
    /// `@MainActor` because a body reaches into `AppState` (which is `@MainActor`), exactly as the
    /// two executors do today.
    public let run: @MainActor (Principal, BridgeArgs) async throws -> BridgeValue

    public init(permission: PortPermission?,
                paramNames: [String] = [],
                writesTarget: String? = nil,
                replacesState: Bool = false,
                needsLiveSurface: Bool = false,
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
        self.replacesState = replacesState
        self.needsLiveSurface = needsLiveSurface
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
                // REQUIRED since R5, and this said "Optional" until 2026-07-28 — in the GENERATED
                // tool schema, which is the text every agent actually reads. The rule and its own
                // documentation disagreed, so a model following the docs wrote a call that is
                // refused. Declaration and behaviour must agree; that is register §5's whole point.
                "description": "REQUIRED. The port's `token`, as it was when you composed this "
                             + "write — from ports_list, port_create, or whatever your last write "
                             + "returned. Without it the write is refused with 'token_required'; if "
                             + "the port has changed since, with 'stale_write'. Both carry the "
                             + "current token, so retry once with that instead of clobbering "
                             + "whoever moved it."
            ] as [String: Any]
            schema["properties"] = props
            // And REQUIRED in the schema, not just in the prose. A model reads the required array to
            // decide what it must supply; leaving the token out of it told every agent the rule was
            // optional in the one place a machine actually checks.
            var required = schema["required"] as? [String] ?? []
            if !required.contains(PortActivity.expectParam) { required.append(PortActivity.expectParam) }
            schema["required"] = required
        }
        return BridgeMethod(permission: permission,
                            paramNames: paramNames + [PortActivity.expectParam],
                            writesTarget: writesTarget,
                            // Third field to ride this copy; see the note below. Dropping it here
                            // would silently switch every state announcement off.
                            replacesState: replacesState,
                            // MUST be carried, and a test caught it being dropped. This copy runs on
                            // EVERY write verb (`mapValues { $0.acceptingExpect() }`), so a field
                            // missing here is silently erased from the whole registry: `port.push`
                            // declared `needsLiveSurface: true` and the dispatcher read `false`.
                            // A copy constructor that has to be kept in sync by hand is the hazard;
                            // `PortLiveSurfaceTests` asserts on the LIVE registry, after this copy,
                            // which is what made it visible.
                            needsLiveSurface: needsLiveSurface,
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
    /// The parameter naming the port this method WRITES to, or nil for a read (I2 · C5).
    ///
    /// Streaming had no such field until C5, so a streaming write verb would have moved no token,
    /// checked no CAS and recorded no presence, silently. Nothing escaped in practice because all
    /// three streaming methods happen to be reads, but "happens to be" is exactly the property the
    /// input seam exists to replace with a structural one. Same meaning as `BridgeMethod.writesTarget`
    /// and dispatched through the same `applyWriteSideEffects`.
    public let writesTarget: String?
    /// Same meaning as `BridgeMethod.replacesState`, and present for the same reason `writesTarget`
    /// is: the two registries must not be able to disagree about what a write is. Every streaming
    /// method is a read today, so nothing sets it — which is exactly the "happens to be" this seam
    /// exists to replace with something declared.
    public let replacesState: Bool
    /// Same meaning as `BridgeMethod.needsLiveSurface`, and present here for the same reason
    /// `writesTarget` is: the two registries must not be able to disagree about what a write is.
    /// C5's lesson was that a field existing on only one of them is a divergence waiting to happen.
    public let needsLiveSurface: Bool
    /// This method NEVER RETURNS ON ITS OWN: it runs until its task is cancelled. A subscription is
    /// endless; a completion is not.
    ///
    /// The distinction is load-bearing on a one-shot transport. `ai.complete` finishes, so
    /// collect-into-final gives an HTTP caller the whole answer. `port.subscribe` does not, so the
    /// same treatment gave them a hang and then a timeout. Declared here rather than inferred from
    /// the method name, so a caller-facing refusal cannot drift from what the method actually does.
    public let endless: Bool
    /// Streams tokens via `yield`, returns the final `BridgeValue`. Throws `BridgeError`.
    public let run: @MainActor (Principal, BridgeArgs, _ yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue

    public init(permission: PortPermission?,
                paramNames: [String] = [],
                toolExposed: Bool = true,
                writesTarget: String? = nil,
                replacesState: Bool = false,
                needsLiveSurface: Bool = false,
                description: String = "",
                inputSchema: [String: Any] = [:],
                endless: Bool = false,
                run: @escaping @MainActor (Principal, BridgeArgs, _ yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue) {
        self.permission = permission
        self.paramNames = paramNames
        self.toolExposed = toolExposed
        self.writesTarget = writesTarget
        self.replacesState = replacesState
        self.needsLiveSurface = needsLiveSurface
        self.description = description
        self.inputSchema = inputSchema
        self.endless = endless
        self.run = run
    }

    /// Streaming's twin of `BridgeMethod.acceptingExpect()`: a declared write gets the optional
    /// `expect` param so CAS is opt-in on this path too, injected centrally rather than per method.
    func acceptingExpect() -> BridgeStreamMethod {
        guard writesTarget != nil, !paramNames.contains(PortActivity.expectParam) else { return self }
        var schema = inputSchema
        if !schema.isEmpty {
            var props = schema["properties"] as? [String: Any] ?? [:]
            props[PortActivity.expectParam] = [
                "type": "string",
                // REQUIRED since R5, and this said "Optional" until 2026-07-28 — in the GENERATED
                // tool schema, which is the text every agent actually reads. The rule and its own
                // documentation disagreed, so a model following the docs wrote a call that is
                // refused. Declaration and behaviour must agree; that is register §5's whole point.
                "description": "REQUIRED. The port's `token`, as it was when you composed this "
                             + "write — from ports_list, port_create, or whatever your last write "
                             + "returned. Without it the write is refused with 'token_required'; if "
                             + "the port has changed since, with 'stale_write'. Both carry the "
                             + "current token, so retry once with that instead of clobbering "
                             + "whoever moved it."
            ] as [String: Any]
            schema["properties"] = props
            var required = schema["required"] as? [String] ?? []
            if !required.contains(PortActivity.expectParam) { required.append(PortActivity.expectParam) }
            schema["required"] = required
        }
        return BridgeStreamMethod(permission: permission,
                                  paramNames: paramNames + [PortActivity.expectParam],
                                  toolExposed: toolExposed, writesTarget: writesTarget,
                                  // FOURTH field to ride this copy. The comment below says a rebuild
                                  // that drops a declared property turns it off silently; this is the
                                  // one that would turn every state announcement off on this path.
                                  replacesState: replacesState,
                                  // Carried for the same reason as the one-shot copy above, and
                                  // fixed at the same time rather than waiting for the streaming
                                  // path to grow its first write verb and inherit the bug.
                                  needsLiveSurface: needsLiveSurface,
                                  // Carried for the third time for the third reason: a rebuild that
                                  // drops a declared property turns it off silently, and this struct
                                  // has now lost two fields that way.
                                  description: description, inputSchema: schema,
                                  endless: endless, run: run)
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


// MARK: - Undeclared arguments (nautilus Phase 0 step 6)
//
// AN ARGUMENT A METHOD DOES NOT DECLARE IS REFUSED, NOT IGNORED. Ignoring it is how a wrong answer
// looked right: on 2026-07-31 `terminal.exec` was called with an `id`, as if it addressed a terminal.
// It has no such parameter, so it ran on the machine, and a session spent time chasing a defect that
// did not exist. The audit for this plan passed `ports.list` an `all_spaces` it does not have, on every
// call, for a day (audit F13).
//
// A method declares its arguments twice over, in `paramNames` (the positional order port JS uses) and
// in its schema's `properties` (what the reference and the tool schema publish). The accepted set is
// the union. One exception: a method whose ONLY declared argument is an opaque `options` bag accepts
// its options flat as well, and its keys are not enumerated anywhere yet. Those stay open until each
// bag's keys are declared; `BridgeDeclaredArgsTests` lists them so the set can only shrink.

enum DeclaredArgs {
    static func names(paramNames: [String], inputSchema: [String: Any]) -> Set<String> {
        let props = (inputSchema["properties"] as? [String: Any]).map { Set($0.keys) } ?? []
        return Set(paramNames).union(props)
    }

    /// Only an opaque option bag (plus the write token every write verb gains) is declared.
    static func isOpenBag(_ declared: Set<String>) -> Bool {
        declared.subtracting([PortActivity.expectParam]) == ["options"]
    }

    /// The error for the names this call sent that the method does not take, or nil.
    static func refusal(method: String, declared: Set<String>, sent: [String]) -> BridgeError? {
        guard !isOpenBag(declared) else { return nil }
        // `token` is accepted everywhere: a write checks it, a read ignores it. Agents thread the
        // token through every call they make, and refusing it on a read would punish the habit the
        // write contract asks for.
        let unknown = sent.filter { !declared.contains($0) && $0 != PortActivity.expectParam }.sorted()
        guard !unknown.isEmpty else { return nil }
        let takes = declared.sorted().joined(separator: ", ")
        let what = unknown.count == 1 ? "argument '\(unknown[0])'" : "arguments " + unknown.map { "'\($0)'" }.joined(separator: ", ")
        return BridgeError(code: .badArg,
                           message: "\(method) does not take \(what). It takes: \(takes.isEmpty ? "no arguments" : takes).")
    }
}

extension BridgeMethod {
    var declaredArgs: Set<String> { DeclaredArgs.names(paramNames: paramNames, inputSchema: inputSchema) }
}

extension BridgeStreamMethod {
    var declaredArgs: Set<String> { DeclaredArgs.names(paramNames: paramNames, inputSchema: inputSchema) }
}
