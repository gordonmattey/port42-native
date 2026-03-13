import Testing
import Foundation
@testable import Port42Lib

@Suite("Agent Auth")
struct AgentAuthTests {

    // MARK: - Auth Resolution

    @Test("Resolve auth from Claude Code OAuth token")
    func resolveClaudeCodeOAuth() throws {
        // Create a mock token file in a temp directory
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
        let auth = try resolver.resolve(config: .claudeCodeOAuth)

        #expect(auth.token == "test-oauth-token-12345")
        #expect(auth.source == .claudeCodeOAuth)
    }

    @Test("Resolve auth from manual API key")
    func resolveManualAPIKey() throws {
        let resolver = AgentAuthResolver(claudeConfigDir: "/nonexistent")
        let auth = try resolver.resolve(config: .apiKey("sk-ant-test-key"))

        #expect(auth.token == "sk-ant-test-key")
        #expect(auth.source == .apiKey)
    }

    @Test("Claude Code OAuth fails gracefully when no token file")
    func missingOAuthToken() {
        let resolver = AgentAuthResolver(claudeConfigDir: "/nonexistent/path")

        #expect(throws: AgentAuthError.self) {
            try resolver.resolve(config: .claudeCodeOAuth)
        }
    }

    @Test("Auth config enum covers both modes")
    func authConfigModes() {
        let oauth = AgentAuthConfig.claudeCodeOAuth
        let apiKey = AgentAuthConfig.apiKey("sk-test")

        switch oauth {
        case .claudeCodeOAuth: break // expected
        case .apiKey: Issue.record("Should be OAuth")
        case .claudeManualToken: Issue.record("Should be OAuth")
        }

        switch apiKey {
        case .apiKey(let key): #expect(key == "sk-test")
        case .claudeCodeOAuth: Issue.record("Should be API key")
        case .claudeManualToken: Issue.record("Should be API key")
        }
    }

    // MARK: - Auth Auto-Detection

    @Test("Auto-detect prefers Claude Code OAuth when available")
    func autoDetectPrefersOAuth() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tokenData = """
        {"oauth_token": "auto-detected-token"}
        """
        try tokenData.write(
            to: tempDir.appendingPathComponent("credentials.json"),
            atomically: true, encoding: .utf8
        )

        let resolver = AgentAuthResolver(claudeConfigDir: tempDir.path)
        let detected = resolver.autoDetect()

        #expect(detected == .claudeCodeOAuth)
    }

    @Test("Auto-detect returns nil when no OAuth available")
    func autoDetectReturnsNil() {
        let resolver = AgentAuthResolver(claudeConfigDir: "/nonexistent/path")
        let detected = resolver.autoDetect()

        #expect(detected == nil)
    }
}
