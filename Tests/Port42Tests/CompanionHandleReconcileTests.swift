import Testing
import Foundation
@testable import Port42Lib

/// **Old companion handles are folded at boot, and the duplicates folding creates are reaped**
/// (2026-08-01).
///
/// Companion names used to be the port's TITLE verbatim, so rows like `codex 146` and
/// `teleport: main` exist in every database predating the fold. They were never addressable —
/// `@codex 146` parses as `@codex` — and once the spawn started folding names, a stale row also
/// stopped matching its own companion, so a second row appeared beside it. Both states were observed
/// live on Dev2: `codex 146` and `codex-146`, side by side.
///
/// GM: no backward compatibility wanted. So fold, and delete only what folding makes redundant.
@Suite("Companion handles reconcile at boot")
@MainActor
struct CompanionHandleReconcileTests {

    /// `agents.ownerId` is a foreign key, so a real user has to exist first.
    func world() throws -> (AppState, String) {
        let db = try DatabaseService(inMemory: true)
        let user = AppUser.createLocal(displayName: "gordon")
        try db.saveUser(user)
        return (AppState(db: db), user.id)
    }

    func addCompanion(_ state: AppState, _ owner: String, _ name: String) throws {
        let agent = AgentConfig.createCommand(ownerId: owner, displayName: name,
                                              command: "/bin/echo", openInTerminal: true,
                                              trigger: .mentionOnly)
        try state.db.saveAgent(agent)
    }

    func names(_ state: AppState) -> Set<String> {
        Set(((try? state.db.getAllAgents()) ?? []).map(\.displayName))
    }

    @Test("an unaddressable name is FOLDED when nothing else answers to the handle")
    func foldsLoneName() throws {
        let (state, owner) = try world()
        try addCompanion(state, owner, "teleport: main")

        let (folded, reaped) = state.reconcileCompanionHandles()
        #expect(folded == 1)
        #expect(reaped == 0)
        // Renamed, not deleted: this is a companion becoming reachable for the first time, and
        // deleting it would be data loss to fix a cosmetic problem.
        #expect(names(state) == ["teleport-main"])
    }

    @Test("the duplicate is REAPED when the folded handle already exists")
    func reapsDuplicate() throws {
        let (state, owner) = try world()
        try addCompanion(state, owner, "codex 146")     // the stale, unaddressable row
        try addCompanion(state, owner, "codex-146")     // the row that superseded it

        let (folded, reaped) = state.reconcileCompanionHandles()
        #expect(reaped == 1)
        #expect(folded == 0)
        #expect(names(state) == ["codex-146"], "the reachable row survives, the duplicate goes")
    }

    @Test("already-addressable names are untouched")
    func leavesGoodNamesAlone() throws {
        let (state, owner) = try world()
        try addCompanion(state, owner, "scout")
        try addCompanion(state, owner, "merry-raven")

        let (folded, reaped) = state.reconcileCompanionHandles()
        #expect(folded == 0 && reaped == 0)
        #expect(names(state) == ["scout", "merry-raven"])
    }

    @Test("running it twice changes nothing the second time")
    func isIdempotent() throws {
        let (state, owner) = try world()
        try addCompanion(state, owner, "codex 146")
        try addCompanion(state, owner, "teleport: main")

        _ = state.reconcileCompanionHandles()
        let after = names(state)
        // Safe on every boot: folding an already-folded name is a no-op, so a settled database
        // must not churn.
        let (folded, reaped) = state.reconcileCompanionHandles()
        #expect(folded == 0 && reaped == 0)
        #expect(names(state) == after)
    }

    @Test("every surviving handle is one MentionParser actually matches")
    func everySurvivorIsAddressable() throws {
        let (state, owner) = try world()
        for n in ["codex 146", "codex-146", "teleport: main", "scout", "Deploy Bot 3000"] {
            try addCompanion(state, owner, n)
        }
        _ = state.reconcileCompanionHandles()

        // The point of the whole exercise: after this runs, every companion in the roster can be
        // reached by typing its name.
        for name in names(state) {
            #expect(MentionParser.extractMentions(from: "hey @\(name)") == ["@\(name)"],
                    "'\(name)' survived reconciliation but cannot be mentioned")
        }
    }
}
