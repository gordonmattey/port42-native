import Testing
import Foundation
@testable import Port42Lib

/// **The share card says what is given, and a yes covers only that** (NAU-03).
///
/// An agent sharing a port raised a card reading only "Share '<title>' with another machine": not
/// which rights, not what the port can reach here. And the yes was saved against the port alone, so
/// it silently covered every later invite for that port, `edit` and `move` included.
@Suite("Share card consent (NAU-03)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ShareCardConsentTests {

    func makePort(_ w: ParityWorld) throws -> String {
        let created = w.state.createPort(
            type: "web", title: "Board", html: "<title>Board</title>", command: nil, cwd: nil,
            systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    /// Call invite.create as the companion. Returns the card's text if a card was raised (answered
    /// yes), or nil if the call went through without asking. The invite itself then fails for want
    /// of a gateway, which is not what these tests are about.
    func share(_ w: ParityWorld, _ port: String, _ rights: [String]) async throws -> String? {
        let method = try #require(w.registry["invite.create"])
        let p = w.principal
        final class Done { var value = false }
        let done = Done()
        let task = Task { @MainActor in
            _ = try? await method.run(p, BridgeArgs(["port": port, "rights": rights]))
            done.value = true
        }
        // Wait for whichever comes first: a card, or the call finishing without one. No fixed
        // number of yields, which a loaded machine outlasts. Sleeps rather than yields: a yield
        // loop spins the main actor the awaited call also needs, which under load is what made
        // this test outrun its time limit.
        var detail: String?
        while !done.value {
            if let card = w.state.permissions.current {
                detail = card.detail
                w.state.permissions.resolveCurrent(granted: true)
                break
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        _ = await task.value
        return detail
    }

    @Test("the card names the rights and what the port can reach on this machine")
    func cardSaysWhatIsGiven() async throws {
        let w = try makeParityWorld()
        w.state.saveGrants([.clipboard], grantee: w.companion.id, on: .machine, zone: w.space.id)
        let id = try makePort(w)

        let detail = try #require(try await share(w, id, ["see", "use"]))
        #expect(detail.contains("Board"))
        #expect(detail.contains("see it"))
        #expect(detail.contains("use it"))
        #expect(detail.contains("clipboard"), "the port's reach on this machine must be on the card")
        #expect(!detail.contains("change its code"))
    }

    @Test("a yes covers that port with those rights only: wider rights ask again")
    func approvalKeyedOnRights() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)

        #expect(try await share(w, id, ["see"]) != nil, "first share asks")
        #expect(try await share(w, id, ["see"]) == nil, "the same rights again do not")
        #expect(try await share(w, id, ["see", "use", "wake_agents"]) != nil, "wider rights ask again")
    }

    @Test("edit and move are asked every time, never remembered")
    func editAndMoveAlwaysAsk() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)
        for rights in [["see", "edit"], ["move"]] {
            let first = try #require(try await share(w, id, rights))
            #expect(try await share(w, id, rights) != nil, "\(rights) must ask again")
            if rights.contains("edit") { #expect(first.contains("change its code")) }
        }
    }
}
