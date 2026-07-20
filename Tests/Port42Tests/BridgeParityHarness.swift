import Testing
import Foundation
@testable import Port42Lib

// MARK: - BridgeParityHarness
//
// The spine of Phase 1: prove the new registry body produces the same result as the old path before
// the old switches are deleted. A case runs BOTH in the same in-memory world and compares their
// tool-use rendering, canonicalized so JSON key order and prose both compare correctly. This same
// harness is reused for every method family.
//
// (Phase-2 note: the plan calls for a "replay mode" against captured golden fixtures once the old
// paths are gone. Phase 1 is oracle mode — old path vs registry, live, side by side.)

/// A self-contained world: an in-memory DB, a user, one companion, one space. Mirrors the setup the
/// existing memory tests use (`D4MemoryScopeTests`).
@MainActor
struct ParityWorld {
    let state: AppState
    let companion: AgentConfig
    let space: Space

    /// The old path: an in-app companion executor bound to this space + companion.
    var exec: ToolExecutor {
        ToolExecutor(appState: state, spaceId: space.id, createdBy: companion.id)
    }

    /// The new path's caller identity: a companion principal, same id + space the executor uses.
    var principal: Principal {
        Principal(id: companion.id, displayName: companion.displayName, spaceId: space.id, kind: .companion)
    }

    /// The registry under test, built from this world's AppState.
    var registry: BridgeRegistry { buildBridgeRegistry(state) }
}

@MainActor
func makeParityWorld(companionName: String = "Echo", spaceName: String = "project") throws -> ParityWorld {
    let db = try DatabaseService(inMemory: true)
    let state = AppState(db: db)
    let user = AppUser.createForTesting(displayName: "Alice")
    try db.saveUser(user)
    state.currentUser = user
    let companion = AgentConfig.createLLM(
        ownerId: user.id, displayName: companionName,
        systemPrompt: "You are \(companionName).", provider: .anthropic,
        model: "claude-opus-4-6", trigger: .mentionOnly
    )
    try db.saveAgent(companion)
    let space = Space.create(name: spaceName)
    try db.saveSpace(space)
    // The real app populates these @Published arrays from the DB via restoreFromDB / observations;
    // in a headless world we mirror that so state-backed reads (space.list, companions.*) see them.
    state.spaces = [space]
    state.companions = [companion]
    return ParityWorld(state: state, companion: companion, space: space)
}

/// The registry's declared permission for a canonical (or aliased) method name, from a fresh
/// world. Checks both registries (one-shot + streaming). Tests that used to assert on the deleted
/// `PortPermission.permissionForMethod` table read THE permission table (the registry) instead.
@MainActor
func registryPermission(_ name: String) throws -> PortPermission? {
    let w = try makeParityWorld()
    let canonical = w.state.resolveBridgeAlias(name)
    if let m = w.registry[canonical] { return m.permission }
    if let sm = buildBridgeStreamRegistry(w.state)[canonical] { return sm.permission }
    return nil
}

/// The production LLM tool list (generated registry schemas + the hybrid holdouts), built from a
/// fresh world. This is what AppState serves to the engine since big-bang step 1; tests that used
/// to assert on the deleted hand-written `ToolDefinitions.all` read this instead.
@MainActor
func generatedToolList() throws -> [[String: Any]] {
    try makeParityWorld().state.generatedToolDefinitions()
}

// MARK: Canonicalization
//
// Reduce a tool-result block list to a comparable form: an image becomes "image:<mime>:<data>"; a text
// block that parses as JSON becomes "json:<sorted-keys serialization>" (so key order and the old
// `jsonString` sortedKeys output line up); any other text becomes "text:<raw>". Two results are equal
// iff their canonical forms are equal.
func canonicalizeBlocks(_ blocks: [[String: Any]]) -> [String] {
    blocks.map { b in
        if (b["type"] as? String) == "image" {
            let s = b["source"] as? [String: Any]
            return "image:\(s?["media_type"] ?? ""):\(s?["data"] ?? "")"
        }
        let text = (b["text"] as? String) ?? ""
        if let d = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
           (obj is [String: Any] || obj is [Any]),   // only treat containers as JSON; a bare "ok" stays text
           let canon = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let s = String(data: canon, encoding: .utf8) {
            return "json:\(s)"
        }
        return "text:\(text)"
    }
}

/// Old path (ToolExecutor) rendered + canonicalized.
@MainActor
func oldOutput(_ w: ParityWorld, tool: String, input: [String: Any]) async -> [String] {
    canonicalizeBlocks(await w.exec.execute(name: tool, input: input))
}

/// New path (registry body → tool blocks) rendered + canonicalized. A thrown BridgeError renders the
/// same way the Phase-2 tool adapter will render it, so error parity is testable here.
@MainActor
func newOutput(_ w: ParityWorld, canonical: String, input: [String: Any]) async -> [String] {
    guard let method = w.registry[canonical] else { return ["MISSING_REGISTRY_ENTRY:\(canonical)"] }
    let args = BridgeArgs(input)
    do {
        let value = try await method.run(w.principal, args)
        return canonicalizeBlocks(value.toToolBlocks())
    } catch let e as BridgeError {
        return canonicalizeBlocks(e.toToolBlocks())
    } catch {
        return canonicalizeBlocks([["type": "text", "text": "Error: \(error)"]])
    }
}
