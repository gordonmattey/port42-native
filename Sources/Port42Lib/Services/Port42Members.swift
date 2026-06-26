import Foundation

/// Shared shaping for space-membership API responses so the two API surfaces — `ToolExecutor`
/// (tool-use / remote `curl` RPC) and `PortBridge` (webview JS) — return IDENTICAL data.
///
/// This is a deliberate down-payment on the larger ToolExecutor↔PortBridge unification
/// (see docs/plan-toolexecutor-portbridge-unification.md): the member/companion shaping logic
/// lives in ONE place instead of being hand-rolled (and drifting) on each surface.
enum Port42Members {
    /// Canonical JSON shape for one space member. `type` is "human" or "agent";
    /// `qualifiedName` includes the owner namespace when present (useful for @mentioning).
    static func dict(_ m: SpaceMember) -> [String: Any] {
        [
            "id": m.senderId,
            "name": m.name,
            "type": m.type,
            "owner": m.owner ?? "",
            "qualifiedName": m.qualifiedName
        ]
    }

    /// The companion roster, optionally filtered to those assigned to `spaceId`.
    /// No (or empty) spaceId → the full global roster, preserving prior behaviour.
    @MainActor
    static func companions(appState: AppState, spaceId: String?) -> [AgentConfig] {
        guard let spaceId, !spaceId.isEmpty else { return appState.companions }
        let assigned = Set(((try? appState.db.getAgentsForSpace(spaceId: spaceId)) ?? []).map { $0.id })
        return appState.companions.filter { assigned.contains($0.id) }
    }
}
