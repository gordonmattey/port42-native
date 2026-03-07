import Testing
import Foundation
@testable import Port42Lib

@Suite("Agent Process")
struct AgentProcessTests {

    // MARK: - Process Lifecycle

    @Test("Spawn agent process with echo command")
    func spawnProcess() async throws {
        let config = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@echo-bot",
            command: "/bin/cat",
            trigger: .mentionOnly
        )

        let process = AgentProcess(config: config)
        try process.start()
        #expect(process.isRunning)

        process.stop()
        // Give it a moment to terminate
        try await Task.sleep(for: .milliseconds(100))
        #expect(!process.isRunning)
    }

    @Test("Send event and receive response")
    func sendAndReceive() async throws {
        // Use a shell script that echoes back a valid response
        let script = """
        #!/bin/bash
        while IFS= read -r line; do
            echo '{"content": "I heard you"}'
        done
        """
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-agent-\(UUID().uuidString).sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path
        )

        defer { try? FileManager.default.removeItem(at: scriptPath) }

        let config = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@test-bot",
            command: scriptPath.path,
            trigger: .mentionOnly
        )

        let process = AgentProcess(config: config)
        try process.start()

        let event = AgentEvent.mention(
            messageId: "msg-1", content: "@test-bot hello",
            sender: "Gordon", senderId: "u1",
            channel: "test", channelId: "c1",
            timestamp: Date(), history: []
        )

        let response = try await process.send(event, timeout: 5.0)
        #expect(response.content == "I heard you")

        process.stop()
    }

    @Test("Process timeout returns error")
    func processTimeout() async throws {
        // Agent that never responds
        let script = """
        #!/bin/bash
        while IFS= read -r line; do
            sleep 999
        done
        """
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-slow-agent-\(UUID().uuidString).sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path
        )

        defer { try? FileManager.default.removeItem(at: scriptPath) }

        let config = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@slow-bot",
            command: scriptPath.path,
            trigger: .mentionOnly
        )

        let process = AgentProcess(config: config)
        try process.start()

        let event = AgentEvent.mention(
            messageId: "msg-1", content: "@slow-bot hello",
            sender: "Gordon", senderId: "u1",
            channel: "test", channelId: "c1",
            timestamp: Date(), history: []
        )

        await #expect(throws: AgentProcessError.self) {
            try await process.send(event, timeout: 0.5)
        }

        process.stop()
    }

    @Test("Invalid command fails to start")
    func invalidCommand() throws {
        let config = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@bad-bot",
            command: "/nonexistent/path/to/agent",
            trigger: .mentionOnly
        )

        let process = AgentProcess(config: config)
        #expect(throws: (any Error).self) {
            try process.start()
        }
        #expect(!process.isRunning)
    }

    @Test("Agent logs capture stderr")
    func captureStderr() async throws {
        let script = """
        #!/bin/bash
        echo "debug info" >&2
        while IFS= read -r line; do
            echo '{"content": "ok"}'
        done
        """
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-stderr-agent-\(UUID().uuidString).sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path
        )

        defer { try? FileManager.default.removeItem(at: scriptPath) }

        let config = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@log-bot",
            command: scriptPath.path,
            trigger: .mentionOnly
        )

        let process = AgentProcess(config: config)
        try process.start()

        // Send a message and wait for response to ensure the script has fully started
        let event = AgentEvent.mention(
            messageId: "m", content: "@log-bot hi",
            sender: "X", senderId: "u", channel: "c", channelId: "ci",
            timestamp: Date(), history: []
        )
        _ = try await process.send(event, timeout: 5.0)

        // Now stderr should have been flushed
        try await Task.sleep(for: .milliseconds(100))
        let logs = process.getLogs()
        #expect(logs.contains("debug info"))

        process.stop()
    }

    @Test("Environment variables passed to agent")
    func envVars() async throws {
        let script = """
        #!/bin/bash
        while IFS= read -r line; do
            echo "{\\\"content\\\": \\\"key=$MY_KEY\\\"}"
        done
        """
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-env-agent-\(UUID().uuidString).sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path
        )

        defer { try? FileManager.default.removeItem(at: scriptPath) }

        let config = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@env-bot",
            command: scriptPath.path,
            envVars: ["MY_KEY": "secret-123"],
            trigger: .mentionOnly
        )

        let process = AgentProcess(config: config)
        try process.start()

        let event = AgentEvent.mention(
            messageId: "m", content: "@env-bot check",
            sender: "X", senderId: "u", channel: "c", channelId: "ci",
            timestamp: Date(), history: []
        )

        let response = try await process.send(event, timeout: 5.0)
        #expect(response.content == "key=secret-123")

        process.stop()
    }
}
