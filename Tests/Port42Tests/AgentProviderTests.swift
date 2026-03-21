import Testing
import Foundation
@testable import Port42Lib

@Suite("AgentProvider")
struct AgentProviderTests {

    // MARK: - Migration

    @Test("v23 migration runs cleanly and existing agents have providerBaseURL nil")
    func migrationAddsProviderBaseURL() throws {
        let db = try DatabaseService(inMemory: true)
        let user = try AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        // Create a companion (pre-migration shape is handled by migrations)
        var companion = AgentConfig.createLLM(
            ownerId: user.id,
            displayName: "Echo",
            systemPrompt: "You are Echo.",
            provider: .anthropic,
            model: "claude-haiku-4-5-20251001",
            trigger: .mentionOnly
        )
        try db.saveAgent(companion)

        // Fetch back — providerBaseURL should be nil for an existing anthropic companion
        let fetched = try db.getAllAgents().first(where: { $0.id == companion.id })
        #expect(fetched?.providerBaseURL == nil)
        #expect(fetched?.provider == .anthropic)
    }

    // MARK: - Existing anthropic companions unaffected

    @Test("Existing anthropic companions still route to LLMEngine")
    func anthropicRoutesToLLMEngine() throws {
        let db = try DatabaseService(inMemory: true)
        let user = try AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        var companion = AgentConfig.createLLM(
            ownerId: user.id,
            displayName: "Echo",
            systemPrompt: "You are Echo.",
            provider: .anthropic,
            model: "claude-haiku-4-5-20251001",
            trigger: .mentionOnly
        )
        try db.saveAgent(companion)

        let fetched = try db.getAllAgents().first(where: { $0.id == companion.id })
        #expect(fetched?.provider == .anthropic)
        let backend = makeLLMBackend(for: fetched!)
        #expect(backend is LLMEngine)
    }

    // MARK: - Gemini companion round-trip

    @Test("AgentConfig with provider .gemini round-trips through DB")
    func geminiRoundTrip() throws {
        let db = try DatabaseService(inMemory: true)
        let user = try AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        var companion = AgentConfig.createLLM(
            ownerId: user.id,
            displayName: "GeminiBot",
            systemPrompt: "You are a Gemini companion.",
            provider: .gemini,
            model: "gemini-2.0-flash",
            trigger: .mentionOnly
        )
        try db.saveAgent(companion)

        let fetched = try db.getAllAgents().first(where: { $0.id == companion.id })
        #expect(fetched?.provider == .gemini)
        #expect(fetched?.model == "gemini-2.0-flash")
        #expect(fetched?.providerBaseURL == nil)

        let backend = makeLLMBackend(for: fetched!)
        #expect(backend is GeminiEngine)
    }

    // MARK: - providerBaseURL stores and retrieves correctly

    @Test("providerBaseURL stores and retrieves correctly")
    func providerBaseURLRoundTrip() throws {
        let db = try DatabaseService(inMemory: true)
        let user = try AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        var companion = AgentConfig(
            id: UUID().uuidString,
            ownerId: user.id,
            displayName: "OllamaBot",
            mode: .llm,
            trigger: .mentionOnly,
            systemPrompt: "You are local.",
            provider: .compatibleEndpoint,
            providerBaseURL: "http://localhost:11434/v1",
            model: "llama3.2",
            command: nil,
            args: nil,
            workingDir: nil,
            envVars: nil,
            createdAt: Date()
        )
        try db.saveAgent(companion)

        let fetched = try db.getAllAgents().first(where: { $0.id == companion.id })
        #expect(fetched?.provider == .compatibleEndpoint)
        #expect(fetched?.providerBaseURL == "http://localhost:11434/v1")
        #expect(fetched?.model == "llama3.2")
    }

    @Test("providerBaseURL is nil when not set")
    func providerBaseURLNilWhenNotSet() throws {
        let db = try DatabaseService(inMemory: true)
        let user = try AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        let companion = AgentConfig.createLLM(
            ownerId: user.id,
            displayName: "NoBase",
            systemPrompt: "test",
            provider: .anthropic,
            model: "claude-haiku-4-5-20251001",
            trigger: .mentionOnly
        )
        try db.saveAgent(companion)

        let fetched = try db.getAllAgents().first(where: { $0.id == companion.id })
        #expect(fetched?.providerBaseURL == nil)
    }
}
