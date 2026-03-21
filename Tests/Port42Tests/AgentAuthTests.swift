import Testing
import Foundation
@testable import Port42Lib

@Suite("Agent Auth")
struct AgentAuthTests {

    // MARK: - Token Detection

    @Test("Detect OAuth token from prefix")
    func detectOAuthToken() {
        #expect(TokenDetector.detect("sk-ant-oat01-abc123") == .oauthToken)
    }

    @Test("Detect API key from prefix")
    func detectApiKey() {
        #expect(TokenDetector.detect("sk-ant-api03-abc123") == .apiKey)
    }

    @Test("Detect unknown token")
    func detectUnknown() {
        #expect(TokenDetector.detect("random-garbage") == .unknown)
        #expect(TokenDetector.detect("") == .unknown)
    }

    @Test("Human labels for credential types")
    func humanLabels() {
        #expect(TokenDetector.humanLabel(.oauthToken) == "OAuth session token")
        #expect(TokenDetector.humanLabel(.apiKey) == "API key")
        #expect(TokenDetector.humanLabel(.unknown) == "unrecognized token format")
    }

    // MARK: - Auth Resolution

    @Test("Resolve auth from Claude Code OAuth token")
    func resolveClaudeCodeOAuth() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tokenData = """
        {"oauth_token": "test-oauth-token-12345"}
        """
        try tokenData.write(
            to: tempDir.appendingPathComponent("credentials.json"),
            atomically: true, encoding: .utf8
        )

        let resolver = AgentAuthResolver(claudeConfigDir: tempDir.path)
        let auth = try resolver.resolve()

        #expect(auth.token == "test-oauth-token-12345")
        #expect(auth.source == .claudeCodeKeychain)
    }

    @Test("Claude Code OAuth fails gracefully when no token file")
    func missingOAuthToken() {
        let resolver = AgentAuthResolver(claudeConfigDir: "/nonexistent/path")

        #expect(throws: AgentAuthError.self) {
            try resolver.resolve()
        }
    }

    // MARK: - Auth Status

    @Test("Check status returns noCredential when nothing configured")
    func checkStatusNoCredential() {
        let resolver = AgentAuthResolver(claudeConfigDir: "/nonexistent/path")
        let status = resolver.checkStatus()
        #expect(status == .noCredential)
    }

    @Test("Check status returns connected when token available")
    func checkStatusConnected() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        {"oauth_token": "test-token"}
        """.write(
            to: tempDir.appendingPathComponent("credentials.json"),
            atomically: true, encoding: .utf8
        )

        let resolver = AgentAuthResolver(claudeConfigDir: tempDir.path)
        let status = resolver.checkStatus()
        if case .connected = status {
            // expected
        } else {
            Issue.record("Expected connected status, got \(status)")
        }
    }

    // MARK: - Credential Types

    @Test("CredentialType enum cases")
    func credentialTypes() {
        let oauth = CredentialType.oauthToken
        let apiKey = CredentialType.apiKey
        let unknown = CredentialType.unknown

        #expect(oauth != apiKey)
        #expect(oauth != unknown)
        #expect(apiKey != unknown)
    }

    // MARK: - Auth Preference

    @Test("AuthPreference round-trips through raw value")
    func authPreferenceRoundTrip() {
        let auto = AuthPreference.autoDetect
        let manual = AuthPreference.manualEntry

        #expect(AuthPreference(rawValue: auto.rawValue) == .autoDetect)
        #expect(AuthPreference(rawValue: manual.rawValue) == .manualEntry)
    }

    // MARK: - useOAuthHeaders

    @Test("Keychain source always uses OAuth headers regardless of token prefix")
    func keychainSourceAlwaysOAuth() {
        // Even with unknown prefix, Keychain source means OAuth
        let unknown = AuthCredential(token: "some-weird-token", type: .unknown, source: .claudeCodeKeychain)
        #expect(unknown.useOAuthHeaders == true)

        let oat = AuthCredential(token: "sk-ant-oat01-x", type: .oauthToken, source: .claudeCodeKeychain)
        #expect(oat.useOAuthHeaders == true)

        let apiFromKeychain = AuthCredential(token: "sk-ant-api03-x", type: .apiKey, source: .claudeCodeKeychain)
        #expect(apiFromKeychain.useOAuthHeaders == true)
    }

    @Test("Manual OAuth token uses OAuth headers")
    func manualOAuthUsesOAuthHeaders() {
        let cred = AuthCredential(token: "sk-ant-oat01-x", type: .oauthToken, source: .manual)
        #expect(cred.useOAuthHeaders == true)
    }

    @Test("Manual API key does not use OAuth headers")
    func manualApiKeyNoOAuth() {
        let cred = AuthCredential(token: "sk-ant-api03-x", type: .apiKey, source: .manual)
        #expect(cred.useOAuthHeaders == false)
    }

    @Test("Manual unknown token does not use OAuth headers")
    func manualUnknownNoOAuth() {
        let cred = AuthCredential(token: "garbage", type: .unknown, source: .manual)
        #expect(cred.useOAuthHeaders == false)
    }

    // MARK: - applyAuth headers

    @Test("applyAuth sets Bearer + beta headers for OAuth credential")
    func applyAuthOAuth() {
        let cred = AuthCredential(token: "sk-ant-oat01-test", type: .oauthToken, source: .claudeCodeKeychain)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.applyAuth(cred)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,context-management-2025-06-27,prompt-caching-scope-2026-01-05,effort-2025-11-24")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("applyAuth sets x-api-key for API key credential")
    func applyAuthApiKey() {
        let cred = AuthCredential(token: "sk-ant-api03-test", type: .apiKey, source: .manual)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.applyAuth(cred)

        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test("applyAuth uses OAuth for Keychain token even with unknown prefix")
    func applyAuthKeychainUnknownPrefix() {
        let cred = AuthCredential(token: "weird-token-format", type: .unknown, source: .claudeCodeKeychain)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.applyAuth(cred)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer weird-token-format")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,context-management-2025-06-27,prompt-caching-scope-2026-01-05,effort-2025-11-24")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        // No x-app or User-Agent overrides - those cause 400s on the messages endpoint
    }

    // MARK: - Resolver source correctness

    @Test("Resolver returns claudeCodeKeychain source for auto-detect")
    func resolverAutoDetectSource() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        {"oauth_token": "sk-ant-oat01-from-keychain"}
        """.write(
            to: tempDir.appendingPathComponent("credentials.json"),
            atomically: true, encoding: .utf8
        )

        let resolver = AgentAuthResolver(claudeConfigDir: tempDir.path)
        let cred = try resolver.resolve()

        #expect(cred.source == .claudeCodeKeychain)
        #expect(cred.useOAuthHeaders == true)
    }

    @Test("Resolver returns claudeCodeKeychain source even for non-standard token format")
    func resolverKeychainNonStandardToken() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Token without recognized prefix
        try """
        {"oauth_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.some-jwt"}
        """.write(
            to: tempDir.appendingPathComponent("credentials.json"),
            atomically: true, encoding: .utf8
        )

        let resolver = AgentAuthResolver(claudeConfigDir: tempDir.path)
        let cred = try resolver.resolve()

        #expect(cred.source == .claudeCodeKeychain)
        #expect(cred.type == .unknown) // prefix doesn't match
        #expect(cred.useOAuthHeaders == true) // but source overrides
    }

    // MARK: - Gemini API key store
    // Note: these tests use a unique provider name to avoid stomping the real "gemini" Keychain slot

    @Test("Gemini API key save and load round-trips correctly")
    func geminiKeyRoundTrip() {
        let store = Port42AuthStore()
        let provider = "gemini-test-\(UUID().uuidString)"
        let testKey = "AIzaSyTest-abc123"
        defer { store.deleteCredential(provider: provider) }

        store.saveCredential(testKey, provider: provider)
        let loaded = store.loadCredential(provider: provider)
        #expect(loaded == testKey)
    }

    @Test("Gemini key returns nil when not set")
    func geminiKeyNilWhenNotSet() {
        let store = Port42AuthStore()
        let provider = "gemini-test-\(UUID().uuidString)"
        // Never saved — should be nil
        #expect(store.loadCredential(provider: provider) == nil)
    }

    @Test("Anthropic key unchanged after gemini key operations")
    func anthropicKeyUnchangedAfterGeminiOps() {
        let store = Port42AuthStore()
        let geminiProvider = "gemini-test-\(UUID().uuidString)"
        let geminiKey = "AIzaSy-gemini-test"
        defer { store.deleteCredential(provider: geminiProvider) }

        // Record current anthropic key state (do not modify it)
        let existingAnthropicKey = store.loadCredential(provider: "anthropic")

        store.saveCredential(geminiKey, provider: geminiProvider)
        store.deleteCredential(provider: geminiProvider)

        // Anthropic key should be exactly what it was before our operations
        #expect(store.loadCredential(provider: "anthropic") == existingAnthropicKey)
        #expect(store.loadCredential(provider: geminiProvider) == nil)
    }
}
