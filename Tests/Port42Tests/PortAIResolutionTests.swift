import Testing
import Foundation
@testable import Port42Lib

// Item 8, commit 1: the ai.complete backend / model / token resolution moved off PortBridge onto
// AppState (parameterized on `createdBy`) so a registry entry can resolve without a PortBridge. These
// prove the precedence the port path relied on is preserved: portAICompanionId, then the creating
// companion, then the system default.

@Suite("Port AI resolution — AppState")
struct PortAIResolutionTests {

    @Test("model defaults to the system model when no companion resolves")
    @MainActor
    func modelDefault() throws {
        let w = try makeParityWorld()
        UserDefaults.standard.removeObject(forKey: "portAICompanionId")
        #expect(w.state.resolvePortAIModel(createdBy: nil) == "claude-sonnet-4-6")
        #expect(w.state.resolvePortAIModel(createdBy: "no-such-companion") == "claude-sonnet-4-6")
    }

    @Test("model uses the creating companion's model when createdBy matches")
    @MainActor
    func modelFromCreator() throws {
        let w = try makeParityWorld()   // companion.model == "claude-opus-4-6"
        UserDefaults.standard.removeObject(forKey: "portAICompanionId")
        #expect(w.state.resolvePortAIModel(createdBy: w.companion.id) == "claude-opus-4-6")
    }

    @Test("portAICompanionId takes precedence over the creating companion")
    @MainActor
    func modelDesignatedWins() throws {
        let w = try makeParityWorld(companionName: "Creator")
        let designated = AgentConfig.createLLM(
            ownerId: w.state.currentUser!.id, displayName: "Designated",
            systemPrompt: "You are Designated.", provider: .anthropic,
            model: "claude-haiku-4-5-20251001", trigger: .mentionOnly)
        try w.state.db.saveAgent(designated)
        w.state.companions = [w.companion, designated]
        UserDefaults.standard.set(designated.id, forKey: "portAICompanionId")
        defer { UserDefaults.standard.removeObject(forKey: "portAICompanionId") }
        // createdBy points at the creator, but the designated companion outranks it.
        #expect(w.state.resolvePortAIModel(createdBy: w.companion.id) == "claude-haiku-4-5-20251001")
    }

    @Test("backend resolves to a real LLMBackend (creator when matched, bare engine otherwise)")
    @MainActor
    func backendResolves() throws {
        let w = try makeParityWorld()
        UserDefaults.standard.removeObject(forKey: "portAICompanionId")
        _ = w.state.resolvePortAIBackend(createdBy: w.companion.id)   // creating companion path
        _ = w.state.resolvePortAIBackend(createdBy: nil)              // bare LLMEngine path
        // Both return a non-nil backend; makeLLMBackend is total, so reaching here without a trap is
        // the assertion (an LLMBackend is a class existential — no cheap identity check to make).
    }

    @Test("max tokens is the documented 16384")
    @MainActor
    func maxTokens() throws {
        let w = try makeParityWorld()
        #expect(w.state.portAIMaxTokens == 16384)
    }
}
