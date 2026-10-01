import Testing
import Foundation
@testable import Port42Lib

// API parity, Phase A (docs/plan-api-parity.md): companions.update and companions.delete, so everything
// a companion's settings box changes can be changed from an agent. Found when a companion was made with
// an unfilled {{USER}} in its prompt and the API could not fix it.

@Suite("companions.update and companions.delete")
@MainActor
struct CompanionUpdateTests {
    let person = Principal.human(id: "alice", displayName: "Alice", spaceId: nil)

    func call(_ w: ParityWorld, _ method: String, _ p: Principal, _ args: [String: Any]) async throws -> [String: Any] {
        let v = try await w.state.runBridgeMethod(method, principal: p, args: BridgeArgs(args))
        return v.toJSONObject() as? [String: Any] ?? [:]
    }

    func member(_ w: ParityWorld, _ name: String, prompt: String? = "you are {{USER}}'s helper") throws -> AgentConfig {
        let a = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                          systemPrompt: prompt, trigger: .mentionOnly)
        try w.state.db.saveAgent(a)
        w.state.companions.append(a)
        w.state.joinCompanionToSpace(a, spaceId: w.space.id)
        return a
    }

    func asCompanion(_ w: ParityWorld, _ a: AgentConfig) -> Principal {
        Principal.companion(id: a.id, displayName: a.displayName, spaceId: w.space.id)
    }

    func stored(_ w: ParityWorld, _ a: AgentConfig) throws -> AgentConfig? {
        try w.state.db.getAllAgents().first { $0.id == a.id }
    }

    @Test("the person changes a prompt, name, folder, trigger and where it runs, and it is saved")
    func personUpdates() async throws {
        let w = try makeParityWorld()
        let echo = try member(w, "helper")
        let out = try await call(w, "companions.update", person, [
            "companion": "helper", "prompt": "you are Gordon's helper", "name": "helper-2", "cwd": "/tmp/echo",
            "trigger": "allMessages", "runs": "running"])
        #expect((out["changed"] as? [String])?.sorted() == ["cwd", "name", "prompt", "runs", "trigger"])
        let c = try #require(try stored(w, echo))
        #expect(c.systemPrompt == "you are Gordon's helper", "prompt: \(String(describing: c.systemPrompt))")
        #expect(c.displayName == "helper-2", "name: \(c.displayName)")
        #expect(c.workingDir == "/tmp/echo", "cwd: \(String(describing: c.workingDir))")
        #expect(c.trigger == .allMessages, "trigger: \(c.trigger)")
        #expect(c.runsHidden, "runs")
    }

    @Test("a companion may change itself, and not another companion")
    func ownSettingsOnly() async throws {
        let w = try makeParityWorld()
        let a = try member(w, "alpha"), b = try member(w, "beta")
        _ = try await call(w, "companions.update", asCompanion(w, a), ["companion": "alpha", "prompt": "mine"])
        #expect(try stored(w, a)?.systemPrompt == "mine")
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "companions.update", self.asCompanion(w, a), ["companion": "beta", "prompt": "hijacked"])
        }
        #expect(try stored(w, b)?.systemPrompt != "hijacked", "a companion rewrote another companion's prompt")
    }

    @Test("a name another companion holds is refused, and an update with nothing to change is refused")
    func refusals() async throws {
        let w = try makeParityWorld()
        _ = try member(w, "one"); _ = try member(w, "two")
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "companions.update", self.person, ["companion": "one", "name": "TWO"])
        }
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "companions.update", self.person, ["companion": "one"])
        }
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "companions.update", self.person, ["companion": "one", "trigger": "sometimes"])
        }
    }

    @Test("a companion in no space the caller shares is not found")
    func scope() async throws {
        let w = try makeParityWorld()
        let stranger = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "stranger", command: "claude",
                                                 systemPrompt: nil, trigger: .mentionOnly)
        try w.state.db.saveAgent(stranger); w.state.companions.append(stranger)       // on no roster
        let caller = try member(w, "caller")
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "companions.update", self.asCompanion(w, caller), ["companion": "stranger", "prompt": "x"])
        }
    }

    @Test("the person deletes a companion outright; it leaves the roster and the store")
    func personDeletes() async throws {
        let w = try makeParityWorld()
        let a = try member(w, "doomed")
        let out = try await call(w, "companions.delete", person, ["companion": "doomed"])
        #expect(out["deleted"] as? String == a.id)
        #expect(try stored(w, a) == nil, "still in the store")
        #expect(!w.state.companions.contains { $0.id == a.id })
    }

    @Test("anyone else asks the person, naming the companion; a no keeps it; a yes is not remembered")
    func agentAsks() async throws {
        let w = try makeParityWorld()
        let caller = try member(w, "caller"), victim = try member(w, "victim")
        let first = Task { @MainActor in try await self.call(w, "companions.delete", self.asCompanion(w, caller), ["companion": "victim"]) }
        for _ in 0..<400 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.permission == .deleteCompanion, "a companion deleted another without asking")
        #expect(w.state.permissions.current?.detail?.contains("victim") == true, "the card did not name the companion")
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await first.value }
        #expect(try stored(w, victim) != nil, "a refused delete deleted it")

        let second = Task { @MainActor in try await self.call(w, "companions.delete", self.asCompanion(w, caller), ["companion": "victim"]) }
        for _ in 0..<400 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current != nil, "the first answer was remembered; a delete asks every time")
        w.state.permissions.resolveCurrent(granted: true)
        _ = try await second.value
        #expect(try stored(w, victim) == nil)
    }
}
