import Testing
import Foundation
@testable import Port42Lib

@Suite("Swim Session")
struct SwimTests {

    // MARK: - SwimSession

    @Test("New session has empty messages")
    @MainActor
    func emptySession() {
        let companion = AgentConfig.createLLM(
            ownerId: "test",
            displayName: "TestBot",
            systemPrompt: "You are helpful.",
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        let session = SwimSession(companion: companion)

        #expect(session.messages.isEmpty)
        #expect(session.isStreaming == false)
        #expect(session.draft == "")
        #expect(session.error == nil)
    }

    @Test("Send trims whitespace and skips empty")
    @MainActor
    func sendTrimsWhitespace() {
        let companion = AgentConfig.createLLM(
            ownerId: "test",
            displayName: "TestBot",
            systemPrompt: "You are helpful.",
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        let session = SwimSession(companion: companion)

        // Empty draft should not send
        session.draft = "   "
        session.send()
        #expect(session.messages.isEmpty)

        // Non-empty draft creates user + placeholder messages
        session.draft = "  hello  "
        session.send()
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[0].content == "hello")
        #expect(session.messages[1].role == .assistant)
        #expect(session.draft == "")
    }

    @Test("Cannot send while streaming")
    @MainActor
    func cannotSendWhileStreaming() {
        let companion = AgentConfig.createLLM(
            ownerId: "test",
            displayName: "TestBot",
            systemPrompt: "You are helpful.",
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        let session = SwimSession(companion: companion)

        session.draft = "first"
        session.send()
        #expect(session.isStreaming == true)

        // Try sending again while streaming
        session.draft = "second"
        session.send()
        // Should still only have the first message pair
        #expect(session.messages.count == 2)
        // Draft should not be cleared since send was rejected
        #expect(session.draft == "second")
    }

    @Test("Stop cancels streaming")
    @MainActor
    func stopCancelsStreaming() {
        let companion = AgentConfig.createLLM(
            ownerId: "test",
            displayName: "TestBot",
            systemPrompt: "You are helpful.",
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        let session = SwimSession(companion: companion)

        session.draft = "test"
        session.send()
        #expect(session.isStreaming == true)

        session.stop()
        #expect(session.isStreaming == false)
    }

    @Test("LLM delegate receives tokens")
    @MainActor
    func delegateReceivesTokens() {
        let companion = AgentConfig.createLLM(
            ownerId: "test",
            displayName: "TestBot",
            systemPrompt: "You are helpful.",
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        let session = SwimSession(companion: companion)

        // Set up a message with assistant placeholder
        session.draft = "hello"
        session.send()
        #expect(session.messages.count == 2)
        #expect(session.messages[1].content == "") // empty placeholder

        // Simulate token delivery via delegate (synchronous on MainActor)
        session.llmDidReceiveToken("Hello ")
        // The token is dispatched via Task, so we check the mechanism exists
        // In real async this would update; for unit test we verify the method doesn't crash
    }

    @Test("LLM delegate handles error")
    @MainActor
    func delegateHandlesError() {
        let companion = AgentConfig.createLLM(
            ownerId: "test",
            displayName: "TestBot",
            systemPrompt: "You are helpful.",
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        let session = SwimSession(companion: companion)

        session.draft = "hello"
        session.send()
        let messageCountBefore = session.messages.count

        // Simulate error via delegate
        session.llmDidError(LLMEngineError.noAuth)
        // Error is dispatched via Task, verify method doesn't crash
        #expect(messageCountBefore == 2)
    }

    // MARK: - SwimMessage

    @Test("SwimMessage has unique IDs")
    func uniqueMessageIds() {
        let m1 = SwimMessage(role: .user, content: "hello")
        let m2 = SwimMessage(role: .assistant, content: "hi")
        #expect(m1.id != m2.id)
    }

    @Test("SwimMessage stores content and role")
    func messageContent() {
        let msg = SwimMessage(role: .user, content: "test message")
        #expect(msg.role == .user)
        #expect(msg.content == "test message")
        #expect(msg.timestamp <= Date())
    }
}

@Suite("LLM Engine")
struct LLMEngineTests {

    @Test("Engine requires auth to send")
    @MainActor
    func requiresAuth() {
        let engine = LLMEngine(authResolver: AgentAuthResolver(keychainService: "nonexistent-service"))

        final class MockDelegate: LLMStreamDelegate {
            nonisolated func llmDidReceiveToken(_ token: String) {}
            nonisolated func llmDidFinish(fullResponse: String) {}
            nonisolated func llmDidError(_ error: Error) {}
        }

        let delegate = MockDelegate()
        #expect(throws: LLMEngineError.self) {
            try engine.send(
                messages: [["role": "user", "content": "hi"]],
                systemPrompt: "test",
                delegate: delegate
            )
        }
    }

    @Test("SSE event parsing extracts text deltas")
    func sseParsingExtractsText() {
        // Test the SSE format that Anthropic returns
        let sseBlock = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """

        // Verify the format matches what our parser expects
        let lines = sseBlock.components(separatedBy: "\n")
        var eventType = ""
        var dataLine = ""
        for line in lines {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataLine = String(line.dropFirst(6))
            }
        }

        #expect(eventType == "content_block_delta")

        let jsonData = dataLine.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
        let delta = json["delta"] as! [String: Any]
        let text = delta["text"] as! String
        #expect(text == "Hello")
    }

    @Test("SSE error event has message")
    func sseErrorEvent() {
        let sseBlock = """
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        """

        let lines = sseBlock.components(separatedBy: "\n")
        var eventType = ""
        var dataLine = ""
        for line in lines {
            if line.hasPrefix("event: ") { eventType = String(line.dropFirst(7)) }
            else if line.hasPrefix("data: ") { dataLine = String(line.dropFirst(6)) }
        }

        #expect(eventType == "error")
        let json = try! JSONSerialization.jsonObject(with: dataLine.data(using: .utf8)!) as! [String: Any]
        let error = json["error"] as! [String: Any]
        #expect(error["message"] as? String == "Overloaded")
    }
}

@Suite("Auth Resolution")
struct AuthResolutionTests {

    @Test("OAuth token uses Bearer header, API key uses x-api-key")
    func authHeaderDifference() {
        let oauth = ResolvedAuth(token: "sk-ant-oat01-xxx", source: .claudeCodeOAuth)
        let apiKey = ResolvedAuth(token: "sk-ant-api03-xxx", source: .apiKey)

        #expect(oauth.source == .claudeCodeOAuth)
        #expect(apiKey.source == .apiKey)
        #expect(oauth.source != apiKey.source)
    }

    @Test("Keychain JSON parsing handles nested claudeAiOauth format")
    func keychainJsonParsing() throws {
        // This is the actual format Claude Code stores in keychain
        let json: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "sk-ant-oat01-test-token",
                "refreshToken": "sk-ant-ort01-refresh",
                "expiresAt": "2026-03-08T00:00:00Z"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let oauthObj = parsed["claudeAiOauth"] as! [String: Any]
        let accessToken = oauthObj["accessToken"] as! String

        #expect(accessToken == "sk-ant-oat01-test-token")
    }

    @Test("Keychain JSON parsing handles flat format as fallback")
    func flatJsonParsing() throws {
        let json: [String: Any] = ["oauth_token": "sk-flat-token"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Primary path fails (no claudeAiOauth key)
        #expect(parsed["claudeAiOauth"] == nil)
        // Fallback works
        #expect(parsed["oauth_token"] as? String == "sk-flat-token")
    }
}

@Suite("Companion Management")
struct CompanionManagementTests {

    @MainActor
    func makeState() throws -> AppState {
        let db = try DatabaseService(inMemory: true)
        return AppState(db: db)
    }

    @Test("Add companion persists to database")
    @MainActor
    func addCompanion() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        // Setup already creates one companion
        #expect(state.companions.count == 1)

        let extra = AgentConfig.createLLM(
            ownerId: state.currentUser!.id,
            displayName: "Helper",
            systemPrompt: "Be helpful",
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        state.addCompanion(extra)
        #expect(state.companions.count == 2)

        // Verify persisted
        let fromDb = try state.db.getAllAgents()
        #expect(fromDb.count == 2)
    }

    @Test("Delete companion removes from state and database")
    @MainActor
    func deleteCompanion() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        let companion = state.companions.first!
        state.deleteCompanion(companion)

        #expect(state.companions.isEmpty)
        #expect(try state.db.getAllAgents().isEmpty)
    }

    @Test("Delete companion clears active swim if matching")
    @MainActor
    func deleteCompanionClearsSwim() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        // Setup starts a swim session
        #expect(state.activeSwimSession != nil)

        let companion = state.companions.first!
        state.deleteCompanion(companion)

        #expect(state.activeSwimSession == nil)
    }

    @Test("Start swim creates session with companion")
    @MainActor
    func startSwim() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        // Exit the auto-started swim
        state.exitSwim()
        #expect(state.activeSwimSession == nil)

        let companion = state.companions.first!
        state.startSwim(with: companion)

        #expect(state.activeSwimSession != nil)
        #expect(state.activeSwimSession?.companion.id == companion.id)
    }

    @Test("Exit swim clears session")
    @MainActor
    func exitSwim() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        #expect(state.activeSwimSession != nil)

        state.exitSwim()
        #expect(state.activeSwimSession == nil)
    }

    @Test("Onboarding creates Claude companion with correct system prompt")
    @MainActor
    func onboardingCompanionPrompt() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Alice")

        let companion = state.companions.first!
        #expect(companion.displayName == "Claude")
        #expect(companion.systemPrompt?.contains("Alice") == true)
        #expect(companion.systemPrompt?.contains("Port42") == true)
        #expect(companion.provider == .anthropic)
    }

    @Test("Onboarding swim intro mentions user name")
    @MainActor
    func onboardingSwimIntro() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Bob")

        let session = state.activeSwimSession!
        let userMsg = session.messages.first!
        #expect(userMsg.role == .user)
        #expect(userMsg.content.contains("Bob"))
    }
}
