import SwiftUI

private func p42log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    let dir = NSHomeDirectory() + "/Library/Application Support/Port42"
    let path = dir + "/swim.log"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    }
    // Also NSLog so it shows in Console.app
    NSLog("[Port42] %@", msg)
}

// MARK: - Swim Session (1:1 companion conversation state)

@MainActor
public final class SwimSession: ObservableObject, LLMStreamDelegate {
    @Published public var messages: [SwimMessage] = []
    @Published public var isStreaming = false
    @Published public var draft = ""
    @Published public var error: String?

    public let companion: AgentConfig
    private let engine = LLMEngine()
    private weak var db: DatabaseService?
    private var pendingResponse = ""
    var fileResolver: FileResolver?
    /// Returns the display names of all current companions (for dynamic prompt context)
    var companionNamesProvider: (() -> [String])?

    public init(companion: AgentConfig, db: DatabaseService? = nil, savedMessages: [SwimMessage] = []) {
        self.companion = companion
        self.db = db
        self.messages = savedMessages
    }

    public func send(_ content: String? = nil) {
        let text = content ?? draft.trimmingCharacters(in: .whitespacesAndNewlines)
        p42log("send() called, text='\(text.prefix(50))', isStreaming=\(isStreaming)")
        guard !text.isEmpty, !isStreaming else {
            p42log("send() early return: text.isEmpty=\(text.isEmpty), isStreaming=\(isStreaming)")
            return
        }

        draft = ""
        error = nil
        messages.append(SwimMessage(role: .user, content: text))

        // Build API messages from conversation history (exclude empty placeholders)
        // Resolve file paths in user messages so companions can see file contents
        let swimChannelId = "swim-\(companion.id)"
        let apiMessages = messages.compactMap { msg -> [String: String]? in
            guard !msg.content.isEmpty else { return nil }
            let content = msg.role == .user
                ? (fileResolver?.resolve(msg.content, channelId: swimChannelId) ?? msg.content)
                : msg.content
            return ["role": msg.role == .user ? "user" : "assistant", "content": content]
        }

        // Add placeholder for streaming response
        pendingResponse = ""
        messages.append(SwimMessage(role: .assistant, content: ""))
        isStreaming = true

        let modelName = companion.model ?? "unknown"
        p42log("[Port42] Swim sending \(apiMessages.count) messages to \(modelName)")

        // Build system prompt with dynamic companion list
        var prompt = companion.systemPrompt ?? "You are a helpful companion."
        let others = (companionNamesProvider?() ?? [])
            .filter { $0.lowercased() != companion.displayName.lowercased() }
        if !others.isEmpty {
            let list = others.map { "@\($0)" }.joined(separator: ", ")
            prompt += "\n\nyour fellow companions in this port42 instance: \(list). the user can @mention any of them in channels or start a swim with them directly."
        }
        if let url = Bundle.port42.url(forResource: "ports-context", withExtension: "txt"),
           let portsContext = try? String(contentsOf: url, encoding: .utf8) {
            prompt += "\n\n" + portsContext
        }

        do {
            let lastMsg = text.lowercased()
            let portHint = ["port", "build", "dashboard", "interactive", "visualiz", "widget", "tool"]
                .contains { lastMsg.contains($0) }
            try engine.send(
                messages: apiMessages,
                systemPrompt: prompt,
                model: companion.model ?? "claude-opus-4-6",
                maxTokens: portHint ? 16384 : 4096,
                delegate: self
            )
            p42log("[Port42] Swim engine.send() succeeded, waiting for stream...")
        } catch {
            p42log("[Port42] Swim send error: \(error)")
            isStreaming = false
            messages.removeLast() // remove empty placeholder
            self.error = error.localizedDescription
        }
    }

    public func stop() {
        engine.cancel()
        isStreaming = false
    }

    public func retry() {
        engine.cancel()
        error = nil
        // Clear stale cached token so we pick up refreshed credentials
        AgentAuthResolver.shared.clearCache()
        // Re-send the last user message if available
        if let lastUser = messages.last(where: { $0.role == .user }) {
            send(lastUser.content)
        }
    }

    private func persistMessages() {
        guard let db else { return }
        // Only persist non-empty messages
        let toSave = messages.filter { !$0.content.isEmpty }
        do {
            try db.saveSwimMessages(companionId: companion.id, messages: toSave)
        } catch {
            p42log("[Port42] Failed to persist swim messages: \(error)")
        }
    }

    /// Convert swim messages to unified ChatEntry array
    public func chatEntries(userName: String) -> [ChatEntry] {
        messages.compactMap { msg in
            // Hide empty placeholder messages (typing indicator handles streaming state)
            if msg.role == .assistant && msg.content.isEmpty { return nil }
            return ChatEntry(
                id: msg.id.uuidString,
                senderName: msg.role == .user ? userName : companion.displayName,
                content: msg.content,
                isAgent: msg.role == .assistant,
                isPlaceholder: false
            )
        }
    }

    // MARK: - LLMStreamDelegate

    nonisolated public func llmDidReceiveToken(_ token: String) {
        Task { @MainActor in
            self.pendingResponse += token
        }
    }

    nonisolated public func llmDidFinish(fullResponse: String) {
        p42log("[Port42] Swim finished, response length: \(fullResponse.count)")
        Task { @MainActor in
            self.isStreaming = false
            self.pendingResponse = ""
            // Replace the empty placeholder with the complete response
            if let last = self.messages.last, last.role == .assistant {
                self.messages[self.messages.count - 1].content = fullResponse
            }
            self.persistMessages()
        }
    }

    nonisolated public func llmDidError(_ error: Error) {
        p42log("[Port42] Swim error: \(error)")
        Task { @MainActor in
            isStreaming = false
            self.error = error.localizedDescription
            // Remove empty placeholder if no content streamed
            if let last = messages.last, last.role == .assistant, last.content.isEmpty {
                messages.removeLast()
            }
        }
    }
}

// MARK: - Swim Message

public struct SwimMessage: Identifiable {
    public let id = UUID()
    public var role: Role
    public var content: String
    public let timestamp = Date()

    public enum Role {
        case user
        case assistant
    }
}

// MARK: - Swim View

public struct SwimView: View {
    @ObservedObject var session: SwimSession
    let userName: String
    let onExit: () -> Void

    public init(session: SwimSession, userName: String = "You", onExit: @escaping () -> Void) {
        self.session = session
        self.userName = userName
        self.onExit = onExit
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onExit) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Port42Theme.accent)

                Circle()
                    .fill(Port42Theme.textAgent)
                    .frame(width: 8, height: 8)

                Text(session.companion.displayName)
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.textAgent)

                Text("🏊")
                    .font(.system(size: 12))

                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Port42Theme.bgPrimary)

            Divider().background(Port42Theme.border)

            ConversationContent(
                entries: session.chatEntries(userName: userName),
                placeholder: "Message \(session.companion.displayName)...",
                isStreaming: session.isStreaming,
                error: session.error,
                typingNames: session.isStreaming ? [session.companion.displayName] : [],
                onSend: { content in session.send(content) },
                onStop: { session.stop() },
                onRetry: { session.retry() },
                onDismissError: { session.error = nil }
            )
        }
        .background(Port42Theme.bgPrimary)
    }
}
