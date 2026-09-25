import Foundation

// MARK: - Command Agent Protocol (F-405)
// Spawns an agent as a child process. Communicates via stdin/stdout NDJSON.
// Events to stdin: mention, message, shutdown
// Responses from stdout: streaming content lines
// Logs from stderr: captured via NSLog

// MARK: - Protocol types

struct CommandAgentEvent: Encodable {
    let type: String          // "mention", "message", "shutdown"
    let spaceId: String?
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
    private let spaceId: String
    /// The chat that asked. The whole reply is posted there, as the companion, when the run ends.
    private let replyChat: String
    let handlerId: String
    private weak var appState: AppState?

    private var process: Process?
    private var stdinPipe: Pipe?

    init(agent: AgentConfig, spaceId: String, replyChat: String, appState: AppState) {
        self.agent = agent
        self.spaceId = spaceId
        self.replyChat = replyChat
        self.handlerId = UUID().uuidString
        self.appState = appState
    }

    /// The run ended: post what it said to the asking chat, clear its typing, forget the handler.
    private func finish(_ content: String) {
        guard let appState else { return }
        appState.typingAgentNamesBySpace[spaceId, default: []].remove(agent.displayName)
        appState.activeCommandHandlers.removeValue(forKey: handlerId)
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try appState.postToChat(key: replyChat, text: text,
                                    from: .companion(id: agent.id, displayName: agent.displayName, spaceId: spaceId))
        } catch {
            NSLog("[Port42] Command agent reply to %@ failed: %@", replyChat, error.localizedDescription)
        }
    }

    func start(triggerContent: String, senderId: String, senderName: String) {
        guard let command = agent.command else {
            NSLog("[Port42] Command agent has no command path")
            return
        }
        // Spawn process off main thread
        let agentId = agent.id
        let agentArgs = agent.args ?? []
        let workDir = agent.workingDir
        let envVars = agent.envVars

        let event = CommandAgentEvent(
            type: "mention",
            spaceId: spaceId,
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

                // If `command` is a real executable path, exec it directly (protocol agents:
                // args + NDJSON over stdin/stdout). Otherwise treat it as a shell command line
                // (e.g. "bash | printf …", "echo hi") so pipes/globs work and its stdout is
                // captured + posted — a literal path can't express a pipeline.
                let runViaShell = !FileManager.default.isExecutableFile(atPath: command)
                if runViaShell {
                    let shellLine = agentArgs.isEmpty ? command : ([command] + agentArgs).joined(separator: " ")
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", shellLine]
                } else {
                    process.executableURL = URL(fileURLWithPath: command)
                    process.arguments = agentArgs
                }
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

                // Protocol agents get the trigger event as NDJSON on stdin. Shell commands don't
                // speak the protocol — close stdin so a command that reads it (e.g. bash) gets
                // EOF and exits instead of hanging.
                if runViaShell {
                    try? stdinPipe.fileHandleForWriting.close()
                } else {
                    let encoder = JSONEncoder()
                    if let eventData = try? encoder.encode(event) {
                        stdinPipe.fileHandleForWriting.write(eventData)
                        stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
                    }
                }

                // Read stdout to EOF.
                let stdout = stdoutPipe.fileHandleForReading
                var buffer = Data()
                var fullContent = ""
                var rawStdout = ""   // non-NDJSON output (a plain command like bash just prints text)
                let decoder = JSONDecoder()

                // Handle one output line: NDJSON protocol message, or raw text (accumulated and
                // posted at the end). Shared so the final newline-less remnant is handled too.
                func handleLine(_ lineData: Data) async {
                    guard let line = String(data: lineData, encoding: .utf8),
                          !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    guard let response = try? decoder.decode(CommandAgentResponse.self, from: lineData) else {
                        rawStdout += line + "\n"
                        return
                    }
                    switch response.type {
                    case "content", "done":
                        if let content = response.content {
                            fullContent = response.type == "done" ? content : fullContent + content
                        }
                    case "error":
                        NSLog("[Port42] Command agent error: %@", response.content ?? "unknown")
                    default:
                        break
                    }
                }

                // availableData blocks until data arrives or returns empty at EOF. Do NOT test
                // availableData in a loop condition — that read consumes a chunk that the body
                // then misses (lost the output of fast-exiting commands like `echo`).
                while true {
                    let chunk = stdout.availableData
                    if chunk.isEmpty { break }   // EOF: process exited and the pipe drained
                    buffer.append(chunk)
                    while let newlineRange = buffer.range(of: Data([0x0a])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
                        await handleLine(lineData)
                    }
                }
                // Final line with no trailing newline (e.g. `printf 'x'`).
                if !buffer.isEmpty { await handleLine(buffer) }

                // Fall back to raw stdout for commands that don't speak the NDJSON protocol.
                // Prefer explicitly-tagged <p42> content; otherwise post the raw output.
                if fullContent.isEmpty && !rawStdout.isEmpty {
                    let captured = rawStdout
                    fullContent = await MainActor.run { () -> String in
                        let tags = TerminalOutputProcessor.extractP42Tags(from: captured)
                        return tags.isEmpty
                            ? captured.trimmingCharacters(in: .whitespacesAndNewlines)
                            : tags.joined(separator: "\n")
                    }
                }

                let reply = fullContent
                await MainActor.run { self.finish(reply) }

                stderrPipe.fileHandleForReading.readabilityHandler = nil
            } catch {
                NSLog("[Port42] Failed to spawn command agent: %@", error.localizedDescription)
                await MainActor.run { self.finish("") }
            }
        }
    }

    func sendShutdown() {
        let event = CommandAgentEvent(
            type: "shutdown",
            spaceId: nil, senderId: nil, senderName: nil,
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
