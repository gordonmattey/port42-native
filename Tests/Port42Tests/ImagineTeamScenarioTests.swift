import Testing
import Foundation
@testable import Port42Lib

/// An imagine team can still build one port together after every authorization fix (GM, 2026-09-28).
/// APP-07 was held out of 1.0.0 because it stopped a team's engineers editing the lead's port once
/// the port held a grant they did not; every later tightening is checked against this before it ships.
///
/// A lead makes a web port in the team's space; two engineers read it, patch it, replace it, post in
/// its chat, read the chat, list it and subscribe to it. Then the lead is granted the microphone (a
/// port that reacts to music asked for it) and the engineers carry on.
@Suite("An imagine team builds one port together")
@MainActor
struct ImagineTeamScenarioTests {

    struct Team {
        let w: ParityWorld
        let lead: Principal, eng1: Principal, eng2: Principal
    }

    func team() throws -> Team {
        let w = try makeParityWorld(companionName: "starfield-lead", spaceName: "starfield")
        func add(_ name: String) throws -> AgentConfig {
            let a = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                              systemPrompt: nil, trigger: .mentionOnly)
            try w.state.db.saveAgent(a)
            w.state.companions.append(a)
            return a
        }
        let e1 = try add("starfield-eng-1"), e2 = try add("starfield-eng-2")
        func p(_ a: AgentConfig) -> Principal { .companion(id: a.id, displayName: a.displayName, spaceId: w.space.id) }
        return Team(w: w, lead: p(w.companion), eng1: p(e1), eng2: p(e2))
    }

    func call(_ t: Team, _ who: Principal, _ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        let v = try await t.w.state.runBridgeMethod(method, principal: who, args: BridgeArgs(args))
        return v.toJSONObject() as? [String: Any] ?? [:]
    }

    /// Each engineer's everyday work on the lead's port. Returns the port's latest token.
    func engineersWork(_ t: Team, port id: String, token: String, round: Int) async throws -> String {
        var tok = token
        let html = try await t.w.state.runBridgeMethod("port.getHtml", principal: t.eng1, args: BridgeArgs(["id": id]))
        #expect((html.toJSONObject() as? String)?.contains("starfield") == true, "an engineer could not read the lead's port")

        let patched = try await call(t, t.eng1, "port.patch", ["id": id, "search": "v\(round)", "replace": "v\(round + 1)", "token": tok])
        tok = try #require(patched["token"] as? String, "an engineer could not patch the lead's port (round \(round))")

        let replaced = try await call(t, t.eng2, "port.update",
                                      ["id": id, "html": "<title>starfield</title><p>v\(round + 2)</p>", "token": tok])
        tok = try #require(replaced["token"] as? String, "an engineer could not replace the lead's port (round \(round))")

        _ = try await call(t, t.eng1, "chat.post", ["port": id, "text": "round \(round) is in, @starfield-lead"])
        let chat = try await call(t, t.eng2, "chat.read", ["port": id])
        #expect(((chat["entries"] as? [[String: Any]]) ?? []).contains { ($0["text"] as? String)?.contains("round \(round)") == true })

        let listed = try await t.w.state.runBridgeMethod("ports.list", principal: t.eng2, args: BridgeArgs([:]))
        #expect(((listed.toJSONObject() as? [[String: Any]]) ?? []).contains { $0["id"] as? String == id },
                "an engineer cannot see the team's port in ports.list")
        return tok
    }

    @Test("a lead makes the port; the engineers read, patch, replace, chat and list it, before and after it holds the microphone")
    func teamBuildsOnePort() async throws {
        let t = try team()
        let made = try await call(t, t.lead, "port.create",
                                  ["type": "web", "title": "starfield", "html": "<title>starfield</title><p>v1</p>"])
        let id = try #require(made["id"] as? String)
        var tok = try #require(made["token"] as? String)

        tok = try await engineersWork(t, port: id, token: tok, round: 1)

        // The port asks for the microphone (a shader that reacts to music) and the person allows it for the lead.
        t.w.state.saveGrants([.microphone], grantee: t.lead.id, on: .machine, zone: t.w.space.id)
        let panel = try #require(t.w.state.portWindows.panels.first { $0.id == id || $0.udid == id })
        panel.bridge.grantedPermissions.insert(.microphone)

        let current = try #require(t.w.state.portWindows.panels.first { $0.id == id || $0.udid == id }).udid
        tok = t.w.state.portInput.token(for: current)
        _ = try await engineersWork(t, port: id, token: tok, round: 3)
    }
}
