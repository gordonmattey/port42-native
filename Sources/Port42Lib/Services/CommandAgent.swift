import Foundation

// MARK: - Command Agent Protocol (F-405)
// Spawns an agent as a child process. Communicates via stdin/stdout NDJSON.
// Events to stdin: mention, message, shutdown
// Responses from stdout: streaming content lines
// Logs from stderr: captured via NSLog

// MARK: - Protocol types

struct CommandAgentEvent: Encodable {
    let type: String          // "mention", "message", "shutdown"
    let channelId: String?
    let senderId: String?
    let senderName: String?
    let content: String?
    let mentionedAgents: [String]?
}

struct CommandAgentResponse: Decodable {
    let type: String          // "content", "done", "error"
    let content: String?
    let replyTo: String?

    enum CodingKeys: String, CodingKey {
        case type, content
        case replyTo = "reply_to"
    }
}

// MARK: - Command Agent Handler

@MainActor
final class CommandAgentHandler {
    private let agent: AgentConfig
    private let channelId: String
    let messageId: String
    private weak var appState: AppState?

    private var process: Process?
    private var stdinPipe: Pipe?

    init(agent: AgentConfig, channelId: String, appState: AppState) {
        self.agent = agent
        self.channelId = channelId
        self.messageId = UUID().uuidString
        self.appState = appState
    }

    func start(triggerContent: String, senderId: String, senderName: String) {
        guard let command = agent.command else {
            NSLog("[Port42] Command agent has no command path")
            return
        }

        // Insert placeholder message
        let placeholder = Message(
            id: messageId,
            channelId: channelId,
            senderId: agent.id,
            senderName: agent.displayName,
            senderType: "agent",
            content: "",
            timestamp: Date(),
            replyToId: nil,
            syncStatus: "local",
            createdAt: Date(),
            senderOwner: appState?.currentUser?.displayName
        )
        appState?.messages.append(placeholder)

        // Spawn process off main thread
        let msgId = messageId
        let agentId = agent.id
        let agentArgs = agent.args ?? []
        let workDir = agent.workingDir
        let envVars = agent.envVars

        let event = CommandAgentEvent(
            type: "mention",
            channelId: channelId,
            senderId: senderId,
            senderName: senderName,
            content: triggerContent,
            mentionedAgents: [agent.displayName]
        )

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let process = Process()
                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = agentArgs
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if let workDir {
                    process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                }

                if let envVars {
                    var env = ProcessInfo.processInfo.environment
                    for (key, value) in envVars {
                        env[key] = value
                    }
                    process.environment = env
                }

                // Capture stderr for logging
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                        NSLog("[Port42] Command agent (%@) stderr: %@", agentId, line.trimmingCharacters(in: .newlines))
                    }
                }

                try process.run()

                await MainActor.run {
                    self.process = process
                    self.stdinPipe = stdinPipe
                }

                // Send the event via stdin
                let encoder = JSONEncoder()
                if let eventData = try? encoder.encode(event) {
                    stdinPipe.fileHandleForWriting.write(eventData)
                    stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
                }

                // Read stdout line by line
                let stdout = stdoutPipe.fileHandleForReading
                var buffer = Data()
                var fullContent = ""

                while process.isRunning || stdout.availableData.count > 0 {
                    let chunk = stdout.availableData
                    if chunk.isEmpty {
                        if !process.isRunning { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }
                    buffer.append(chunk)

                    // Process complete lines
                    while let newlineRange = buffer.range(of: "\n".data(using: .utf8)!) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                        guard let line = String(data: lineData, encoding: .utf8),
                              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                        let decoder = JSONDecoder()
                        guard let response = try? decoder.decode(CommandAgentResponse.self, from: lineData) else {
                            NSLog("[Port42] Command agent sent non-JSON line: %@", line)
                            continue
                        }

                        switch response.type {
                        case "content":
                            if let content = response.content {
                                fullContent += content
                                let snapshot = fullContent
                                await MainActor.run {
                                    guard let appState = self.appState,
                                          let idx = appState.messages.firstIndex(where: { $0.id == msgId }) else { return }
                                    appState.messages[idx].content = snapshot
                                }
                            }
                        case "done":
                            if let content = response.content {
                                fullContent = content
                                let snapshot = fullContent
                                await MainActor.run {
                                    guard let appState = self.appState,
                                          let idx = appState.messages.firstIndex(where: { $0.id == msgId }) else { return }
                                    appState.messages[idx].content = snapshot
                                }
                            }
                        case "error":
                            NSLog("[Port42] Command agent error: %@", response.content ?? "unknown")
                            await MainActor.run {
                                self.appState?.messages.removeAll { $0.id == msgId && $0.content.isEmpty }
                            }
                        default:
                            break
                        }
                    }
                }

                // Persist the completed message
                await MainActor.run {
                    guard let appState = self.appState,
                          let idx = appState.messages.firstIndex(where: { $0.id == msgId }) else { return }
                    appState.typingAgentNamesByChannel[self.channelId, default: []].remove(self.agent.displayName)
                    if !appState.messages[idx].content.isEmpty {
                        do {
                            try appState.db.saveMessage(appState.messages[idx])
                        } catch {
                            NSLog("[Port42] Failed to persist command agent message: %@", error.localizedDescription)
                        }
                    } else {
                        appState.messages.removeAll { $0.id == msgId }
                    }
                    appState.activeCommandHandlers.removeValue(forKey: msgId)
                }

                stderrPipe.fileHandleForReading.readabilityHandler = nil
            } catch {
                NSLog("[Port42] Failed to spawn command agent: %@", error.localizedDescription)
                await MainActor.run {
                    self.appState?.typingAgentNamesByChannel[self.channelId, default: []].remove(self.agent.displayName)
                    self.appState?.messages.removeAll { $0.id == msgId && $0.content.isEmpty }
                    self.appState?.activeCommandHandlers.removeValue(forKey: msgId)
                }
            }
        }
    }

    func sendShutdown() {
        let event = CommandAgentEvent(
            type: "shutdown",
            channelId: nil, senderId: nil, senderName: nil,
            content: nil, mentionedAgents: nil
        )
        if let data = try? JSONEncoder().encode(event) {
            stdinPipe?.fileHandleForWriting.write(data)
            stdinPipe?.fileHandleForWriting.write("\n".data(using: .utf8)!)
        }
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
    }
}
