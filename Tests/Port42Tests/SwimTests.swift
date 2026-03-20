import Testing
import Foundation
@testable import Port42Lib

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
        #expect(throws: AgentAuthError.self) {
            try engine.send(
                messages: [["role": "user", "content": "hi"]],
                systemPrompt: "test",
                delegate: delegate
            )
        }
    }

    @Test("SSE event parsing extracts text deltas")
    func sseParsingExtractsText() {
        let sseBlock = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """

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

    @Test("OAuth credential sets Bearer header, API key sets x-api-key")
    func authHeaderDifference() {
        let oauth = AuthCredential(token: "sk-ant-oat01-xxx", type: .oauthToken, source: .claudeCodeKeychain)
        let apiKey = AuthCredential(token: "sk-ant-api03-xxx", type: .apiKey, source: .manual)

        var oauthReq = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        oauthReq.applyAuth(oauth)
        #expect(oauthReq.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-xxx")
        #expect(oauthReq.value(forHTTPHeaderField: "x-api-key") == nil)

        var apiReq = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        apiReq.applyAuth(apiKey)
        #expect(apiReq.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-xxx")
        #expect(apiReq.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Keychain JSON parsing handles nested claudeAiOauth format")
    func keychainJsonParsing() throws {
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

        #expect(parsed["claudeAiOauth"] == nil)
        #expect(parsed["oauth_token"] as? String == "sk-flat-token")
    }
}

@Suite("Companion Management")
struct CompanionManagementTests {

    @MainActor
    func makeState() throws -> AppState {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Test")
        try db.saveUser(user)
        state.currentUser = user
        return state
    }

    @Test("Add companion persists to database")
    @MainActor
    func addCompanion() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

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

        #expect(state.activeSwimCompanion != nil)

        let companion = state.companions.first!
        state.deleteCompanion(companion)

        #expect(state.activeSwimCompanion == nil)
    }

    @Test("Start swim creates session with companion")
    @MainActor
    func startSwim() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        state.exitSwim()
        #expect(state.activeSwimCompanion == nil)

        let companion = state.companions.first!
        state.startSwim(with: companion)

        #expect(state.activeSwimCompanion != nil)
        #expect(state.activeSwimCompanion?.id == companion.id)
    }

    @Test("Exit swim clears session")
    @MainActor
    func exitSwim() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        #expect(state.activeSwimCompanion != nil)

        state.exitSwim()
        #expect(state.activeSwimCompanion == nil)
    }

    @Test("Onboarding creates Claude companion with correct system prompt")
    @MainActor
    func onboardingCompanionPrompt() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Alice")

        let companion = state.companions.first!
        #expect(companion.displayName == "echo")
        #expect(companion.systemPrompt?.contains("Alice") == true)
        #expect(companion.provider == .anthropic)
    }
}
