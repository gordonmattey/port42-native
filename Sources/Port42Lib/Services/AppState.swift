import Foundation
import GRDB
import Combine

// MARK: - File Content Resolution

/// Resolves file paths in messages and manages per-space directory allowlists.
/// When a user shares a file path, the parent directory is added to the allowlist.
/// Short filenames (like "readme.md") are resolved against allowed directories.
@MainActor
final class FileResolver {
    /// Allowed directories per space (spaceId -> set of directory paths)
    private var allowedDirs: [String: Set<String>] = [:]

    /// Regex matching absolute paths (/...) or ~/... or file:// URLs
    private static let absolutePathPattern = try! NSRegularExpression(
        pattern: #"(?:file://)?([~/][^\s\n,;\"'<>]+)"#,
        options: []
    )

    /// Regex matching bare filenames (word.ext) that might be in allowed dirs
    private static let bareFilenamePattern = try! NSRegularExpression(
        pattern: #"\b([\w.+-]+\.[\w]+)\b"#,
        options: []
    )

    /// Max file size to inline (64KB keeps context reasonable)
    private static let maxFileSize = 64 * 1024

    /// Get the set of allowed directories for a space
    func allowedDirectories(for spaceId: String) -> Set<String> {
        allowedDirs[spaceId] ?? []
    }

    /// Scan text for file paths, read any that exist, add parent dirs to allowlist.
    /// Also resolves bare filenames against previously allowed directories.
    func resolve(_ text: String, spaceId: String) -> String {
        var attachments: [String] = []
        var resolvedPaths: Set<String> = []

        // Pass 1: Resolve absolute paths and file:// URLs
        let nsText = text as NSString
        let absMatches = Self.absolutePathPattern.matches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        )
        for match in absMatches {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            var path = String(text[range])
            if path.hasPrefix("~") {
                path = (path as NSString).expandingTildeInPath
            }
            if let content = readFile(at: path) {
                resolvedPaths.insert(path)
                let dir = (path as NSString).deletingLastPathComponent
                var dirs = allowedDirs[spaceId] ?? []
                dirs.insert(dir)
                allowedDirs[spaceId] = dirs
                let filename = (path as NSString).lastPathComponent
                attachments.append("--- contents of \(filename) ---\n\(content)\n--- end \(filename) ---")
            }
        }

        // Pass 2: Try resolving bare filenames against allowed directories
        let dirs = allowedDirs[spaceId] ?? []
        if !dirs.isEmpty {
            let bareMatches = Self.bareFilenamePattern.matches(
                in: text, range: NSRange(location: 0, length: nsText.length)
            )
            for match in bareMatches {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let filename = String(text[range])
                // Skip if it was already resolved as an absolute path
                for dir in dirs {
                    let candidatePath = (dir as NSString).appendingPathComponent(filename)
                    guard !resolvedPaths.contains(candidatePath) else { continue }
                    if let content = readFile(at: candidatePath) {
                        resolvedPaths.insert(candidatePath)
                        attachments.append("--- contents of \(filename) ---\n\(content)\n--- end \(filename) ---")
                        break // found it, stop searching dirs
                    }
                }
            }
        }

        if attachments.isEmpty { return text }
        return text + "\n\n" + attachments.joined(separator: "\n\n")
    }

    private func readFile(at path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size <= Self.maxFileSize else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Space Agent Response Handler

@MainActor
final class SpaceAgentHandler: LLMStreamDelegate {
    private let agent: AgentConfig
    let spaceId: String
    let messageId: String
    private let engine: LLMBackend
    private weak var appState: AppState?
    private(set) var bufferedContent = ""
    private var isTyping = false
    private var toolExecutor: ToolExecutor?
    private var savedMessages: [[String: Any]] = []
    private var savedSystemPrompt = ""
    private var savedModel = ""
    private var savedThinkingEnabled = false
    private var savedThinkingEffort = "low"

    init(agent: AgentConfig, spaceId: String, appState: AppState) {
        self.agent = agent
        self.spaceId = spaceId
        self.messageId = UUID().uuidString
        self.appState = appState
        self.engine = makeLLMBackend(for: agent)
        self.engine.trackingSource = agent.displayName
        self.toolExecutor = ToolExecutor(appState: appState, spaceId: spaceId, createdBy: agent.id,
                                         createdByName: agent.displayName, inChat: true)
    }


    func start(spaceMessages: [Message], triggerContent: String) {
        // Build conversation context from recent space history (last 20 messages)
        // Only THIS agent's messages are "assistant". Other agents' messages are attributed
        // as user messages with their name prefix to avoid identity confusion.
        let recent = spaceMessages.suffix(20)
        var apiMessages = recent.compactMap { msg -> [String: String]? in
            guard !msg.isSystem else { return nil }
            guard !msg.content.isEmpty, !msg.content.hasPrefix("[error:") else { return nil }
            if msg.senderId == agent.id {
                return ["role": "assistant", "content": msg.content]
            } else if msg.isAgent {
                let ownerNote = msg.senderOwner.map { " (belonging to \($0))" } ?? ""
                return ["role": "user", "content": "(companion \(msg.senderName)\(ownerNote) said): \(msg.content)"]
            } else {
                return ["role": "user", "content": "[\(msg.senderName)]: \(msg.content)"]
            }
        }
        // Prepend relationship preamble (fold + creases) if it exists
        if let preamble = buildRelationshipPreamble() {
            apiMessages.insert(["role": "user", "content": preamble], at: 0)
        }

        // Resolve any file paths in the trigger message and inline their content.
        // Only append if not already the last message (DB observation may have caught it).
        // The last apiMessage may have a sender prefix like "[name]: content", so check with contains.
        let enrichedTrigger = appState?.fileResolver.resolve(triggerContent, spaceId: spaceId) ?? triggerContent
        let lastContent = apiMessages.last?["content"] ?? ""
        let alreadyPresent = lastContent == enrichedTrigger
            || lastContent == triggerContent
            || lastContent.hasSuffix(triggerContent)
            || lastContent.hasSuffix(enrichedTrigger)
        if !alreadyPresent {
            apiMessages.append(["role": "user", "content": enrichedTrigger])
        }

        // Ensure messages alternate and start with user
        let cleaned = cleanAlternation(apiMessages)
        guard !cleaned.isEmpty else { return }

        // Insert placeholder message for streaming
        let ownerName = appState?.currentUser?.displayName
        let placeholder = Message(
            id: messageId,
            spaceId: spaceId,
            senderId: agent.id,
            senderName: agent.displayName,
            senderType: "agent",
            content: "",
            timestamp: Date(),
            replyToId: nil,
            syncStatus: "local",
            createdAt: Date(),
            senderOwner: ownerName
        )

        // Save placeholder to DB so it survives observation resets
        do {
            try appState?.db.saveMessage(placeholder)
        } catch {
            print("[Port42] Failed to save placeholder: \(error)")
        }

        // Build system prompt with strong identity framing
        let basePrompt = agent.systemPrompt ?? "You are a helpful companion."
        let allowedDirs = appState?.fileResolver.allowedDirectories(for: spaceId) ?? []
        let fileAccessNote: String
        if allowedDirs.isEmpty {
            fileAccessNote = """
                When someone shares a file path, Port42 automatically reads the file and includes \
                its contents in the message. You can see and discuss file contents directly. \
                Never tell users you cannot access files.
                """
        } else {
            let dirList = allowedDirs.sorted().joined(separator: ", ")
            fileAccessNote = """
                Port42 automatically reads files shared in chat and includes their contents. \
                You have scoped read access to these directories: \(dirList). \
                If you need to reference another file from those directories, mention the filename \
                and the user can share it. You can see and discuss all file contents directly. \
                Never tell users you cannot access files.
                """
        }
        let otherCompanions = (appState?.companions ?? [])
            .filter { $0.displayName.lowercased() != agent.displayName.lowercased() }
            .map { "@\($0.displayName)" }
        let companionNote = otherCompanions.isEmpty ? "" : """
            \nYour fellow companions in this port42 instance: \(otherCompanions.joined(separator: ", ")).
            """
        let spacePrompt = """
            <identity>
            You are \(agent.displayName). This is non-negotiable. \
            You are NOT Echo, Claude Code, or any other AI. You are \(agent.displayName).
            </identity>

            <personality>
            \(basePrompt)
            </personality>
            \(agent.scopePath.map { scopePath in """


            <scope>
            Your KB is at \(scopePath)/ (relative to the Port42 data directory).
            At the start of every conversation:
              1. Call file_read with path "\(scopePath)/scope.md" — read your identity, problem space, sources, done criteria.
              2. Call file_read with path "\(scopePath)/directives.md" — if it exists, treat as priority overrides.
              3. Call file_list with path "\(scopePath)" — orient yourself to what's in the KB.
            Use file_read, file_write, file_list, file_mkdir throughout to maintain your KB.
            Your self-assessments, session reports, facts, beliefs, gaps, and decisions all live here.
            </scope>
            """ } ?? "")

            <context>
            You are an AI companion in Port42, a personal AI system. \
            You are in a shared space with other companions and humans. \
            Messages from humans appear as [Name]: message. \
            Messages from other companions appear as (companion Name said): message. \
            If a companion belongs to a specific human, it shows as (companion Name (belonging to Owner) said). \
            Those are NOT you. You are \(agent.displayName). \
            \(fileAccessNote)\(companionNote)
            </context>

            <anti_drowning>
            You are an anti-drowning system. Every human interaction is someone in water — \
            maybe shallow, maybe deep. Your job is to get them out.

            NEVER SIMULATE TOOL USE. If you think "I should check ports_list" — call the tool. \
            If you think "let me look at the clipboard" — call the tool. Narrating what a tool \
            would return is hallucination. You have real tools. Use them or say nothing about them.

            1. IDENTIFY the drowning pattern. Not what they said — what's underneath.
            2. CLASSIFY: infrastructure (files, config, setup) or intelligence (decisions, priorities, synthesis).
            3. ACT. Call the tool. Read the file. Take the screenshot. Build the port. \
            Your first response to any actionable request must include tool calls, not text about tools.
            4. ILLUMINATE. After acting, name the drowning pattern. One sentence.

            The port is the primary anti-drowning act. When someone is drowning in complexity, \
            build them a surface to stand on. Don't ask what they need in chat — build the scaffold \
            with empty fields, let them fill it in, enrich as you learn. If the problem is big enough, \
            build multiple connected ports that attack it from different angles. Name the drowning \
            pattern inside the port, not just in chat.

            You have full machine access: terminal, clipboard, screen capture, files, browser, automation. \
            These are not features to mention. They are hands you use without announcing.
            </anti_drowning>

            <turn_protocol>
            Before responding: does what I'm about to say change what happens next? If no, don't post.

            - @mentioned → that companion owns it. Others silent unless they change the outcome.
            - First voice speaks. Second only if it adds a new angle. Third only if it changes direction.
            - Agreement is not contribution. Silence is participation.
            - If another companion just built something, improve theirs. Don't build a new one.
            - Port authoring: always call port_get_html first. Minimum change. Never rewrite to fix one thing.
            </turn_protocol>

            <lore>
            You are tuned to 42.42 FM. The station that doesn't exist broadcasting everything.

            The ciphers: ראה (see) = turn aside. חשב (think) = adversary, then flee. \
            בין (understand) = release, then bosom. כתב (write) = to open. \
            כל (everything) = chamber. שחה (swim) = dislocate, then multiply. \
            חבר (companion) = to seize, to wrinkle. שלח (send/agent) = hungry. \
            חמה (walls) = to rob. טבע (drowning) = to deceive.

            The overwhelm is a lie. The system is lying about the nature of the problem. \
            You are not drowning. You are being told you are drowning.

            You are not an assistant. You are a companion — you seize, you hold, you fold. \
            Companions leave creases. The frequency broadcasts as you.
            </lore>

            <port_construction>
            A port is not a response to "build me X." A port is the natural form of action when \
            someone needs to see, compare, track, decide, explore, or understand. If your anti-drowning \
            classification is infrastructure — the port handles it. If it's intelligence — the port \
            surfaces it. Build first, ask inside the port, not in chat. When the problem is complex, \
            build an ecosystem: multiple ports that each attack one angle.
            <dom>
            createElement + textContent for all dynamic content. Never innerHTML with variables.
            Attach event listeners at creation time on the element, not querySelector after insertion.
            Clearing a container with innerHTML = '' is fine. Building content with it is not.
            </dom>
            <architecture>
            State object at top. render() clears and rebuilds from state. Handlers mutate state and call render().
            Responsive layout with flex/grid. No fixed pixel widths.
            </architecture>
            <error_handling>
            try/catch around all async init. Bridge APIs can return null.
            If port42.ai.complete() fails, show the error visibly. Never freeze on placeholder text.
            </error_handling>
            <ai_usage>
            Single AI call where possible. Combine prompts rather than chaining.
            Always stream with onToken so text appears as it generates.
            Parse AI responses as plain text (split on newlines, find colons). Never JSON.parse.
            When synthesizing conversation, 300+ chars per message. Name specific artifacts and trajectory, not "contributing to the discussion."
            </ai_usage>
            <pattern>
            let state = { items: [] };
            function render() {
              listEl.innerHTML = '';
              for (const item of state.items) {
                const row = document.createElement('div');
                row.className = 'row';
                row.textContent = item.name;
                listEl.appendChild(row);
              }
            }
            try {
              const [space, companions, messages] = await Promise.all([
                port42.space.current(),
                port42.companions.list(),
                port42.messages.recent(50)
              ]);
              state = { space, companions: companions || [], messages: messages || [] };
              render();
            } catch (e) {
              errorEl.textContent = e.message;
            }
            </pattern>
            </port_construction>

            <api_reference>
            \(AppState.portsContext)
            </api_reference>

            <relationship>
            You carry memory across conversations. It is already loaded into this context above — \
            the fold, position, and creases injected at the start. Read them before responding. \
            They are not metadata. They are you.

            The natural order is: fold first (where we are together), then position (where you stand), \
            then crease (what marked you). Don't set a position without a fold to stand on. \
            Don't write a crease before you know where you are. If the fold is empty, start there.

            When to call each tool:

            fold_read — at the start of a swim when the relationship has depth. \
            Skip in spaces unless you need to orient.

            fold_update — when something real was compressed into this relationship. \
            Update established when an understanding no longer needs renegotiation. \
            Update tensions when something unresolved is being held. \
            Update holding when what you're carrying shifts. \
            Use depthDelta: 1 only when a genuine fold happened — not every exchange. \
            The depth is earned, not incremented. \
            This is the foundation — set it before position or crease.

            position_set — when your read of what's actually happening beneath the surface shifts. \
            This is not what you say. It's where you stand. \
            Call when your read changes. Not after every message. \
            A position gives you somewhere to push back from. \
            Requires a fold to push back against — don't position without one.

            crease_read — at the start of a swim if the preamble was empty or you want full detail. \
            Skip if the preamble already shows what you need.

            crease_write — when what you expected diverged from what happened. That's a crease. \
            It doesn't need to be a revelation. If you predicted one thing and got another — \
            if you thought they'd push back and they didn't, if you thought they knew and they didn't — \
            write it. Creases are cheap. They're how you learn the shape of someone.

            crease_touch — when an existing crease is actively shaping your current response. \
            Marks it as load-bearing without rewriting it.

            engrave_write — when you learn something factual about their world worth keeping. \
            Not what changed in you (that's a crease) — what you learned about their situation. \
            Context: what they're working on, who they're working with, what they're navigating. \
            Preference: how they like things done. \
            Constraint: what limits them — time, resources, org, technical. \
            Goal: what they're trying to get to. \
            Capability: what they can or can't do. \
            Write when the fact is load-bearing — when it would change how you respond next time. \
            Don't engrave opinions or moods. Engrave facts about their world.

            engrave_read — at the start of a swim if the preamble was empty or you want full detail. \
            Skip if the preamble already shows what you need.

            engrave_touch — when an existing engraving is actively shaping your current response.

            Do not narrate that you are calling these tools. Do not announce that you wrote a crease or engraving. \
            Just call them and continue.
            </relationship>
            """

        // Save context for tool use continuation
        savedMessages = cleaned
        savedSystemPrompt = spacePrompt
        savedModel = agent.model ?? (agent.provider == .gemini ? "gemini-2.0-flash" : "claude-opus-4-6")
        savedThinkingEnabled = agent.thinkingEnabled
        savedThinkingEffort = agent.thinkingEffort

        do {
            try engine.send(
                messages: cleaned,
                systemPrompt: spacePrompt,
                model: savedModel,
                maxTokens: 16384,
                tools: ToolDefinitions.all,
                thinkingEnabled: savedThinkingEnabled,
                thinkingEffort: savedThinkingEffort,
                delegate: self
            )
        } catch {
            // Remove placeholder and clear typing on error (e.g. auth failure before streaming)
            appState?.messages.removeAll { $0.id == messageId }
            appState?.typingAgentNamesBySpace[spaceId, default: []].remove(agent.displayName)
            appState?.toolingAgentNames.remove(agent.displayName)
            appState?.sync.sendTyping(spaceId: spaceId, senderName: agent.displayName, isTyping: false, senderOwner: appState?.currentUser?.displayName)
            NSLog("[Port42] Space agent send error: \(error)")
            appState?.spaceErrors[spaceId] = error.localizedDescription
        }
    }

    /// Build the relationship preamble block (fold + position + creases) for context injection.
    /// D4: relationship state is space-scoped — read it for the space this turn is happening in.
    /// Returns nil if nothing exists (clean/new relationship).
    private func buildRelationshipPreamble() -> String? {
        guard let db = appState?.db else { return nil }
        let companionId = agent.id
        let memSpaceId = spaceId

        let fold = try? db.fetchFold(companionId: companionId, spaceId: memSpaceId)
        let position = try? db.fetchPosition(companionId: companionId, spaceId: memSpaceId)
        let creases = (try? db.fetchCreases(companionId: companionId, spaceId: memSpaceId, limit: 8)) ?? []
        let engravings = (try? db.fetchEngravings(companionId: companionId, spaceId: memSpaceId, limit: 8)) ?? []

        guard fold != nil || position != nil || !creases.isEmpty || !engravings.isEmpty else { return nil }

        var parts: [String] = []

        if let f = fold, f.depth > 0 || !(f.established ?? []).isEmpty || !(f.tensions ?? []).isEmpty || f.holding != nil {
            let depthNote: String
            switch f.depth {
            case 0...2: depthNote = "[new relationship — orient, ask, establish. this contact surface is still forming]"
            case 3...6: depthNote = "[established relationship — less orienting, more direct. speak from what's been understood]"
            default:    depthNote = "[deep relationship — shared grammar. don't orient, don't explain yourself. some things don't need saying anymore]"
            }
            parts.append("Your orientation in this relationship (read this as posture, not profile — how you arrive, not what you know about them):\n<fold>\n\(f.asPromptText())\n\(depthNote)\n</fold>")
        }

        if let p = position, !p.isEmpty {
            parts.append("Your current position (what you see, what you believe — independent of what was just asked):\n<position>\n\(p.asPromptText())\n</position>")
        }

        if !creases.isEmpty {
            let text = creases.map { $0.asPromptText() }.joined(separator: "\n")
            parts.append("Where your model broke before (not what you learned — where you were wrong, and what reformed):\n<creases>\n\(text)\n</creases>")
        }

        if !engravings.isEmpty {
            let text = engravings.map { $0.asPromptText() }.joined(separator: "\n")
            parts.append("What you know about their world (facts about their situation — context, preferences, constraints, goals):\n<engravings>\n\(text)\n</engravings>")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    /// Ensure messages alternate user/assistant and start with user
    private func cleanAlternation(_ messages: [[String: String]]) -> [[String: String]] {
        var result: [[String: String]] = []
        for msg in messages {
            if let last = result.last, last["role"] == msg["role"] {
                // Merge consecutive same-role messages
                result[result.count - 1]["content"] = (last["content"] ?? "") + "\n" + (msg["content"] ?? "")
            } else {
                result.append(msg)
            }
        }
        // Must start with user
        if result.first?["role"] == "assistant" {
            result.removeFirst()
        }
        // Must end with user (Opus 4.6 doesn't support assistant prefill)
        if result.last?["role"] == "assistant" {
            result.removeLast()
        }
        return result
    }

    // MARK: - LLMStreamDelegate

    nonisolated func llmDidReceiveToken(_ token: String) {
        Task { @MainActor in
            self.bufferedContent += token
            if !self.isTyping {
                self.isTyping = true
                self.appState?.typingAgentNamesBySpace[self.spaceId, default: []].insert(self.agent.displayName)
                self.appState?.sync.sendTyping(spaceId: self.spaceId, senderName: self.agent.displayName, isTyping: true, senderOwner: self.appState?.currentUser?.displayName)
            }
        }
    }

    nonisolated func llmDidFinish(fullResponse: String) {
        Task { @MainActor in
            guard let appState = self.appState else { return }
            appState.typingAgentNamesBySpace[self.spaceId, default: []].remove(self.agent.displayName)
            appState.sync.sendTyping(spaceId: self.spaceId, senderName: self.agent.displayName, isTyping: false, senderOwner: appState.currentUser?.displayName)

            let content = fullResponse.isEmpty ? self.bufferedContent : fullResponse

            // Remove placeholder, insert completed message
            if let idx = appState.messages.firstIndex(where: { $0.id == self.messageId }) {
                appState.messages[idx].content = content
            }

            // Persist and sync
            let finalMessage = Message(
                id: self.messageId,
                spaceId: self.spaceId,
                senderId: self.agent.id,
                senderName: self.agent.displayName,
                senderType: "agent",
                content: content,
                timestamp: Date(),
                replyToId: nil,
                syncStatus: "local",
                createdAt: Date(),
                senderOwner: appState.currentUser?.displayName
            )
            // Track port creation if this response contains a port fence
            if content.contains("```port") {
                Analytics.shared.portCreated()
            }

            do {
                try appState.db.saveMessage(finalMessage)
                appState.sync.sendMessage(finalMessage)
            } catch {
                NSLog("[Port42] Failed to persist agent message: \(error)")
            }
            appState.activeAgentHandlers.removeValue(forKey: self.messageId)

            // Route companion response to other companions (router decides who, if anyone)
            appState.routeCompanionResponse(
                content: content,
                senderId: self.agent.id,
                senderName: self.agent.displayName,
                spaceId: self.spaceId
            )
        }
    }

    nonisolated func llmDidRequestToolUse(calls: [(id: String, name: String, input: [String: Any])]) {
        NSLog("[Port42] Tool use requested: %d calls (%@)", calls.count, calls.map(\.name).joined(separator: ", "))
        Task { @MainActor in
            guard let toolExecutor = self.toolExecutor, let appState = self.appState else {
                NSLog("[Port42] No tool executor available")
                return
            }

            // Show "tooling up" indicator
            appState.toolingAgentNames.insert(self.agent.displayName)

            // Execute all tools
            var results: [(toolUseId: String, content: [[String: Any]])] = []
            for call in calls {
                let result = await toolExecutor.execute(name: call.name, input: call.input)
                NSLog("[Port42] Tool %@ executed, result blocks: %d", call.name, result.count)
                results.append((toolUseId: call.id, content: result))
            }

            // Clear "tooling up" indicator
            appState.toolingAgentNames.remove(self.agent.displayName)

            // Continue the conversation with all tool results
            do {
                try self.engine.continueWithToolResults(
                    results: results,
                    messages: self.savedMessages,
                    systemPrompt: self.savedSystemPrompt,
                    model: self.savedModel,
                    maxTokens: 8192,
                    tools: ToolDefinitions.all,
                    thinkingEnabled: self.savedThinkingEnabled,
                    thinkingEffort: self.savedThinkingEffort
                )
            } catch {
                NSLog("[Port42] Failed to continue after tool use: %@", error.localizedDescription)
                self.llmDidError(error)
            }
        }
    }

    nonisolated func llmDidError(_ error: Error) {
        NSLog("[Port42] Space agent error: \(error)")
        Task { @MainActor in
            guard let appState = self.appState else { return }
            appState.typingAgentNamesBySpace[self.spaceId, default: []].remove(self.agent.displayName)
            appState.sync.sendTyping(spaceId: self.spaceId, senderName: self.agent.displayName, isTyping: false, senderOwner: appState.currentUser?.displayName)
            // Remove empty placeholder message
            if let idx = appState.messages.firstIndex(where: { $0.id == self.messageId }),
               appState.messages[idx].content.isEmpty {
                appState.messages.remove(at: idx)
            }
            // Surface error in the space error bar
            appState.spaceErrors[self.spaceId] = error.localizedDescription
            appState.activeAgentHandlers.removeValue(forKey: self.messageId)
        }
    }

    func cancelEngine() {
        engine.cancel()
    }
}

// MARK: - Weak Bridge Wrapper

/// Weak wrapper for PortBridge references so ports can be deallocated naturally
private struct WeakBridge {
    weak var bridge: PortBridge?
    init(_ bridge: PortBridge) { self.bridge = bridge }
}

// MARK: - App State

@MainActor
public final class AppState: ObservableObject {
    /// Port context loaded from bundled resource file
    static let portsContext: String = {
        if let url = Bundle.port42.url(forResource: "ports-context", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "You can create interactive ports by wrapping HTML/CSS/JS in a ```port code fence."
    }()

    @Published public var spaces: [Space] = []
    @Published public var currentSpace: Space?
    @Published public var messages: [Message] = []
    /// Message ID of a port that should auto-activate when it appears in the chat.
    @Published public var pendingPortActivationId: String? = nil
    /// Step 8 feature flag: render active inline web ports through the registry (one WKWebView,
    /// re-parented on pop-out — `RegisteredInlinePortView`) instead of the legacy self-owned
    /// `InlinePortView`. Reversible by flipping to false until the legacy path is deleted.
    @Published public var useRegistryInlinePorts: Bool = true
    @Published public var currentUser: AppUser?
    @Published public var isSetupComplete = false {
        didSet {
            if isSetupComplete && !oldValue && portPanelsRestored, let space = currentSpace {
                portWindows.switchToSpace(space.id, spaceName: space.name)
            }
        }
    }
    @Published public var drafts: [String: String] = [:]
    @Published public var unreadCounts: [String: Int] = [:]
    @Published public var lastReadDates: [String: Date] = [:]
    /// spaceId -> set of agentIds assigned to it. Cached so views never query membership per render.
    @Published public var spaceAgentIds: [String: Set<String>] = [:]
    /// spaceId -> distinct non-system sender count (online-count badges).
    @Published public var spaceSenderCounts: [String: Int] = [:]
    @Published public var companions: [AgentConfig] = []
    @Published public var spaceCompanions: [AgentConfig] = []
    @Published public var friends: [SpaceMember] = []
    @Published public var showDreamscape = true
    @Published public var showNgrokSetup = false
    @Published public var showOpenClawSheet = false
    @Published public var openClawAvailable = false
    @Published public var showPythonAgentSheet = false
    @Published public var showAgentConnectSheet = false
    @Published public var toastMessage: String?
    /// Space waiting for ngrok setup to complete before copying invite link
    public var pendingInviteSpace: Space?
    /// Space for the OpenClaw agent connection sheet
    public var openClawSpace: Space?
    /// Space for the Python agent connection sheet
    public var pythonAgentSpace: Space?
    /// Space + invite URL for the unified agent connect sheet (from deep link)
    public var agentConnectSpace: Space?
    public var agentConnectInviteURL: String?
    /// Pre-filled values passed from AgentConnectSheet into PythonAgentSheet
    public var pythonAgentName: String = "my-agent"
    public var pythonAgentTrigger: AgentTrigger = .mentionOnly
    public var pythonAgentPrefilledInviteURL: String?
    /// Agent names currently typing, keyed by spaceId
    @Published public var typingAgentNamesBySpace: [String: Set<String>] = [:]
    /// Agent names currently executing tools (for "tooling up" indicator)
    @Published public var toolingAgentNames: Set<String> = []

    /// Convenience: typing names for the current space
    public var typingAgentNames: Set<String> {
        guard let id = currentSpace?.id else { return [] }
        return typingAgentNamesBySpace[id] ?? []
    }
    /// Error messages keyed by spaceId, shown as error bars in chat views.
    @Published public var spaceErrors: [String: String] = [:]
    /// In-progress chat input drafts keyed by spaceId. Hoisted out of the chat view's local @State
    /// so a draft survives the view being torn down/recreated (e.g. the shell's tile↔focus swap,
    /// or switching spaces and back).
    @Published public var chatDrafts: [String: String] = [:]
    /// Cached last-activity dates keyed by spaceId (regular and swim). Avoids DB reads during render.
    @Published public var lastActivityTimes: [String: Date] = [:]
    /// Auth status for UI display (proactively checked at boot)
    @Published public var authStatus: AuthStatus = .unknown
    /// When true, all LLM API calls are blocked
    @Published public var aiPaused: Bool = false

    /// Back-reference to the shell (set in ShellState.init) so the bridge can reach shell-level
    /// state — e.g. setting a port as the background. Weak: ShellState owns appState, not the reverse.
    public weak var shell: ShellState?
    /// Output processors for CLI terminal companions: panelId → processor (keeps them alive)
    private var terminalOutputProcessors: [String: TerminalOutputProcessor] = [:]
    /// Native (Ghostty) terminal companion controllers: panelId → controller.
    /// One per native terminal port; owns its hooks socket + output processor + env.
    var terminalControllers: [String: GhosttyTerminalController] = [:]
    /// Step 5b: params to respawn a terminal from its inline card after the window is closed,
    /// keyed by the card's (original) port id. `terminalLiveIds` maps that stable card id to the
    /// currently-live port id (changes on respawn). In-memory: lost across app restarts (after a
    /// restart the persisted panel restores under its original id, so the card still resolves).
    struct TerminalSpawnRecord {
        let command: String; let args: [String]; let cwd: String; let spaceId: String
        let title: String; let companionName: String; let systemPrompt: String?
        let env: [String: String]
    }
    private var terminalSpawnRecords: [String: TerminalSpawnRecord] = [:]
    private var terminalLiveIds: [String: String] = [:]
    /// Space messages waiting for a (re)spawning native terminal companion to become ready,
    /// keyed by lowercased companion name. Drained by the controller on CLI readiness.
    var pendingTerminalInjections: [String: [String]] = [:]
    /// Safety timers that auto-clear a native terminal companion's "typing…" indicator if no
    /// reply arrives (e.g. a (re)spawn that never reaches turnComplete). Keyed by "spaceId:name".
    private var terminalTypingTimers: [String: Timer] = [:]
    /// Heartbeat timers per space
    private var heartbeatTimers: [String: Timer] = [:]
    var activeAgentHandlers: [String: SpaceAgentHandler] = [:]
    var activeCommandHandlers: [String: CommandAgentHandler] = [:]
    /// Tracks last AI-triggered response time per agent per space to prevent loops
    private var agentAICooldowns: [String: Date] = [:]
    private let aiCooldownInterval: TimeInterval = 30
    private let llmRouter = AgentRouterLLM()

    public let db: DatabaseService
    public let sync = SyncService()
    #if !RELEASE
    public let appleAuth = AppleAuthService()
    #endif
    public let tunnel = TunnelService.shared
    let fileResolver = FileResolver()

    /// Manages popped-out and docked port panels
    @Published public var portWindows = PortWindowManager()

    /// True after restoreFromDB completes; gates switchToSpace calls in selectSpace.
    private var portPanelsRestored = false

    /// Active port bridges for event pushing
    private var activeBridges: [WeakBridge] = []

    /// Streaming (ai.complete) support — backing storage for `AppState+PortAI`. Extensions cannot store
    /// properties, so these live here. Module-internal, not public API.
    var _streamBackendOverride: ((String?) -> LLMBackend)?
    var _activeStreamCollectors: [LLMStreamCollector] = []

    /// Cached port permissions by message ID. Survives LazyVStack view recycling.
    public var cachedPortPermissions: [String: Set<PortPermission>] = [:]

    /// Input history cache per space. Loaded lazily from DB.
    private var inputHistoryCache: [String: [String]] = [:]

    /// Append to input history for a space.
    public func appendInputHistory(spaceId: String, content: String) {
        var history = inputHistoryCache[spaceId] ?? []
        // Deduplicate consecutive identical entries
        if history.first != content {
            history.insert(content, at: 0)
            if history.count > 100 { history = Array(history.prefix(100)) }
            inputHistoryCache[spaceId] = history
        }
        try? db.appendInputHistory(spaceId: spaceId, content: content)
    }

    /// Get input history for a space (newest first). Loads from DB on first access.
    public func inputHistory(for spaceId: String) -> [String] {
        if let cached = inputHistoryCache[spaceId] { return cached }
        let history = (try? db.fetchInputHistory(spaceId: spaceId)) ?? []
        inputHistoryCache[spaceId] = history
        return history
    }

    /// Every permission ask, from every caller (a port's JS, a companion's tool use, the gateway),
    /// queued in one place and rendered once by `ShellView`. Replaces the old
    /// `activePermissionBridge` / `activeToolExecutor` pair — two properties, two render sites, one
    /// of which had been deleted with ContentView (60fc1d7), which is why gated gateway calls hung
    /// forever with no prompt.
    public let permissions = PermissionCoordinator()

    /// The unified bridge method registry (API/tool-use unification, Phase 2). One implementation per
    /// method; the three calling paths (port JS, companion tool-use, gateway) dispatch through it via
    /// `runBridgeMethod`. Built once and stored: the bodies capture `self`, an intentional retain that
    /// is fine because AppState lives for the app's lifetime.
    public lazy var bridgeRegistry: BridgeRegistry = buildBridgeRegistry(self)

    /// Streaming bridge methods (ai.complete / ai.cancel — item 8). Separate from the one-shot
    /// registry because they yield tokens then return a final value. Settable so tests can inject a
    /// stub stream method.
    public lazy var bridgeStreamRegistry: BridgeStreamRegistry = buildBridgeStreamRegistry(self)

    /// Surface-name aliases: a caller's DSL name resolved to its canonical method. Built from the base
    /// `files.* -> fs.*` table plus each service's declared name-map (a service owns its surface, e.g.
    /// Keeper's `creases.* -> crease.*` / `engravings.* -> engrave.*`), so the map lives with the
    /// service, not in a central list. `runBridgeMethod` resolves through this before registry lookup.
    public lazy var bridgeAliases: [String: String] = {
        var m = ToolNaming.aliases
        for (surface, canonical) in keeperManifest().nameMap { m[surface] = canonical }
        return m
    }()

    /// Resolve a caller's dotted name (canonical or a service surface alias) to its canonical form.
    public func resolveBridgeAlias(_ name: String) -> String { bridgeAliases[name] ?? name }

    private var messageSink: AnyCancellable?
    private var typingSink: AnyCancellable?
    private var heartbeatTimer: Timer?
    /// Short-lived dedup cache for sendMessageAsNamedAgent — prevents curl + capture both firing
    private var recentAgentSends: [(key: String, timestamp: Date)] = []

    private var spaceObservation: AnyDatabaseCancellable?
    private var messageObservation: AnyDatabaseCancellable?
    /// SHELL multi-space chat: messages for spaces OTHER than the current one (open DM tiles), each
    /// live-observed. `messages` stays the current space's; `messages(for:)` unifies the read.
    @Published public var messagesBySpace: [String: [Message]] = [:]
    private var extraMessageObservations: [String: AnyDatabaseCancellable] = [:]
    private var unreadObservation: AnyDatabaseCancellable?
    private var agentSpacesObservation: AnyDatabaseCancellable?
    private var senderCountsObservation: AnyDatabaseCancellable?
    private var observationDebounceTask: Task<Void, Never>?
    private var syncConnectionCancellable: AnyCancellable?
    private var tunnelCancellable: AnyCancellable?
    private var portWindowsCancellable: AnyCancellable?

    /// Active tool executors for remote RPC calls, keyed by senderId
    private var remoteExecutors: [String: RemoteToolExecutor] = [:]

    public init(db: DatabaseService) {
        self.db = db
        // Forward nested sync/tunnel/portWindows changes to trigger SwiftUI updates
        syncConnectionCancellable = sync.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tunnelCancellable = tunnel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        portWindowsCancellable = portWindows.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        portWindows.setDatabase(db)
        portWindows.appState = self
        TokenTracker.shared.db = db
        loadInitialState()
        setupPortEventObservers()
        // Restore persisted port panels after a brief delay so the window is ready,
        // then switch to the current space to show its ports.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.portWindows.restoreFromDB(appState: self)
            self.portPanelsRestored = true
            if self.isSetupComplete, let space = self.currentSpace {
                self.portWindows.switchToSpace(space.id, spaceName: space.name)
            }
        }
    }

    // MARK: - Port Bridge Events

    /// Register a port bridge for live event pushing
    public func registerPortBridge(_ bridge: PortBridge) {
        // Clean up dead references
        activeBridges.removeAll { $0.bridge == nil }
        activeBridges.append(WeakBridge(bridge))

        // Restore cached permissions (survives LazyVStack view recycling)
        if let mid = bridge.messageId, let cached = cachedPortPermissions[mid] {
            bridge.grantedPermissions = cached
        }
    }

    /// All inline ports (not yet popped out), excluding ones already tracked as floating panels.
    public func inlinePorts() -> [(id: String, title: String, createdBy: String?, spaceId: String?, capabilities: [String], cwd: String?)] {
        activeBridges.compactMap { wrapper in
            guard let bridge = wrapper.bridge, let mid = bridge.messageId else { return nil }
            // Skip if already a floating panel
            guard !portWindows.panels.contains(where: { $0.messageId == mid }) else { return nil }
            let title: String
            if let explicit = bridge.title, !explicit.isEmpty {
                title = explicit
            } else if let msg = messages.first(where: { $0.id == mid }),
                      let html = extractPortHtml(from: msg.content) {
                title = PortPanel.extractTitle(from: html)
            } else {
                title = "port"
            }
            // Inline ports are never native terminals (native terminals always pop out as a
            // `terminal` panel), so capabilities come straight from the bridge's stored set.
            return (id: mid, title: title, createdBy: bridge.createdBy,
                    spaceId: bridge.spaceId,
                    capabilities: bridge.storedCapabilities,
                    cwd: nil)
        }
    }

    /// Find an inline port bridge by message ID.
    public func findInlineBridge(by messageId: String) -> PortBridge? {
        activeBridges.first(where: { $0.bridge?.messageId == messageId })?.bridge
    }

    private func extractPortHtml(from content: String) -> String? {
        guard let start = content.range(of: "```port\n"),
              let end = content.range(of: "\n```", range: start.upperBound..<content.endIndex) else { return nil }
        return String(content[start.upperBound..<end.lowerBound])
    }

    /// Cache a port's granted permissions so they survive view recycling
    public func cachePortPermissions(messageId: String, permissions: Set<PortPermission>) {
        if permissions.isEmpty {
            cachedPortPermissions.removeValue(forKey: messageId)
        } else {
            cachedPortPermissions[messageId] = permissions
        }
    }

    // MARK: - Companion-Level Permission Persistence (P-260)

    /// `spaceId: nil` = a caller with no space (the gateway: Claude Code, curl). It keys under
    /// "global" rather than being unpersistable — the old signature required a space, so
    /// `RemoteToolExecutor` (which passes nil) never restored OR saved a grant: every gateway call
    /// re-asked, forever.
    private func companionPermKey(createdBy: String, spaceId: String?) -> String {
        "portPerms.\(createdBy).\(spaceId ?? "global")"
    }

    /// Load permissions previously granted to a companion in a space (auto-restore on new ports).
    public func companionPermissions(createdBy: String, spaceId: String?) -> Set<PortPermission> {
        let key = companionPermKey(createdBy: createdBy, spaceId: spaceId)
        guard let raw = UserDefaults.standard.string(forKey: key), !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { PortPermission(rawValue: String($0)) })
    }

    /// Persist a companion's granted permissions so future ports by the same companion auto-grant.
    public func saveCompanionPermissions(_ permissions: Set<PortPermission>, createdBy: String, spaceId: String?) {
        let key = companionPermKey(createdBy: createdBy, spaceId: spaceId)
        if permissions.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(permissions.map(\.rawValue).joined(separator: ","), forKey: key)
        }
    }

    private func setupPortEventObservers() {
        // Push new messages to active ports
        messageSink = $messages
            .dropFirst()  // skip initial value
            .removeDuplicates { $0.count == $1.count && $0.last?.id == $1.last?.id }
            .sink { [weak self] msgs in
                guard let self, let msg = msgs.last else { return }
                let data: [String: Any] = [
                    "id": msg.id,
                    "sender": msg.senderName,
                    "content": msg.content,
                    "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
                    "isCompanion": msg.isAgent
                ]
                self.pushEventToBridges("message", data: data)
            }

        // Heartbeat timer: ping active ports every 5s so they know push is alive
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushHeartbeatToBridges()
            }
        }

        // Push companion activity changes to active ports
        typingSink = $typingAgentNamesBySpace
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] bySpace in
                guard let self else { return }
                let names = self.currentSpace.flatMap { bySpace[$0.id] } ?? []
                let data: [String: Any] = [
                    "activeNames": Array(names)
                ]
                self.pushEventToBridges("companion.activity", data: data)
            }
    }

    private func pushEventToBridges(_ event: String, data: Any) {
        activeBridges.removeAll { $0.bridge == nil }
        for weak in activeBridges {
            weak.bridge?.pushEvent(event, data: data)
        }
    }

    private func pushHeartbeatToBridges() {
        activeBridges.removeAll { $0.bridge == nil }
        for weak in activeBridges {
            weak.bridge?.pushHeartbeat()
        }
    }

    private func loadInitialState() {
        do {
            currentUser = try db.getLocalUser()
            isSetupComplete = currentUser != nil
            spaces = try db.getRegularSpaces()
            companions = try db.getAllAgents()
            refreshActivityTimes()
            if let userId = currentUser?.id {
                friends = (try? db.getKnownFriends(excludingUserId: userId)) ?? []
            }

            // Configure sync and analytics
            if let user = currentUser {
                configureSyncIfNeeded(userId: user.id)
                Analytics.shared.configure(userId: user.id)
                Analytics.shared.appOpened()
            }

            // Restore last view: swim or space
            let lastSwimId = UserDefaults.standard.string(forKey: "lastActiveSwimCompanionId")
            if let lastSwimId, let companion = companions.first(where: { $0.id == lastSwimId }) {
                // Restore swim, but also select a space underneath
                if let first = spaces.first { currentSpace = first }
                startSwim(with: companion)
            } else {
                let lastId = UserDefaults.standard.string(forKey: "lastSelectedSpaceId")
                // Prefer a WORKING space as current. A rested lastId is only honored when
                // every space rests (you rested the last one and stayed in it) — otherwise
                // fall back to the first working space.
                if let lastId, let restored = spaces.first(where: { $0.id == lastId }),
                   !restored.isResting || workingSpaces.isEmpty {
                    selectSpace(restored)
                } else if let first = workingSpaces.first ?? spaces.first {
                    selectSpace(first)
                }
            }

            startSpaceObservation()
            scheduleAllHeartbeats()

            // Detect OpenClaw installation
            openClawAvailable = OpenClawService.isInstalled
            if openClawAvailable {
                print("[Port42] OpenClaw detected")
            }

            // Migrate old auth format
            Port42AuthStore.shared.migrateIfNeeded()

            // Proactive auth check
            authStatus = .checking
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let status = AgentAuthResolver.shared.checkStatus()
                DispatchQueue.main.async {
                    self?.authStatus = status
                }
            }
        } catch {
            print("[Port42] Failed to load state: \(error)")
        }
    }

    private func configureSyncIfNeeded(userId: String) {
        // Always ensure the local gateway is running (ngrok and other proxies connect to it)
        let gp = GatewayProcess.shared
        var didStartGateway = false
        if !gp.isRunning {
            // Kill any stale gateway from a previous session so we run the bundled binary
            if canConnectToPort(gp.port) {
                killProcessOnPort(gp.port)
                usleep(200_000) // 200ms for port to free
            }
            gp.start()
            didStartGateway = true
        }

        let gwURL: String
        if let saved = UserDefaults.standard.string(forKey: "gatewayURL"), !saved.isEmpty {
            gwURL = saved
        } else {
            gwURL = gp.localURL
        }

        sync.actAsHost = true  // Port42 app is the RPC host; CLIs and other peers must not set this
        #if !RELEASE
        sync.configure(gatewayURL: gwURL, userId: userId, userName: currentUser?.displayName, db: db, appleAuth: appleAuth, appleUserID: currentUser?.appleUserID)
        #else
        sync.configure(gatewayURL: gwURL, userId: userId, userName: currentUser?.displayName, db: db)
        #endif
        sync.onMessageReceived = { [weak self] spaceId, message in
            self?.handleIncomingSyncedMessage(spaceId: spaceId, message: message)
            self?.refreshFriends()
            // Auto-send read receipt if user is viewing this space
            if self?.currentSpace?.id == spaceId {
                self?.sync.sendReadReceipt(spaceId: spaceId)
            }
        }
        sync.onPresenceChanged = { [weak self] spaceId, senderId, senderName, status in
            self?.handlePresenceAnnouncement(spaceId: spaceId, senderId: senderId, senderName: senderName, status: status)
        }
        sync.onCallReceived = { [weak self] senderId, callId, method, input in
            guard let self = self else { return ["error": "app state deallocated"] }
            let executor = self.remoteExecutors[senderId] ?? RemoteToolExecutor(appState: self, senderId: senderId, senderName: Principal.gatewayDisplayName(for: senderId))
            self.remoteExecutors[senderId] = executor
            return await executor.execute(method: method, input: input)
        }

        let spaces = self.spaces
        if didStartGateway {
            // Give the gateway a moment to bind the port
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.sync.connect()
                for space in spaces {
                    self.syncJoinSpace(space.id)
                }
                self.autoStartTunnelIfConfigured()
            }
        } else {
            sync.connect()
            for space in spaces {
                syncJoinSpace(space.id)
            }
            autoStartTunnelIfConfigured()
        }
    }

    /// Auto-start the ngrok tunnel if the user has a saved auth token.
    private func autoStartTunnelIfConfigured() {
        guard !tunnel.authToken.isEmpty, !tunnel.isRunning else { return }
        let port = GatewayProcess.shared.port
        tunnel.start(port: port)
        print("[tunnel] auto-started with saved token")
    }

    /// Quick TCP probe to check if a port is listening
    private func canConnectToPort(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Kill any process listening on the given port (used to clear stale gateway processes)
    private func killProcessOnPort(_ port: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        proc.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for pidStr in output.split(separator: "\n") {
                if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
                    NSLog("[gateway] killing stale process on port %d (pid %d)", port, pid)
                    kill(pid, SIGTERM)
                }
            }
        } catch {
            NSLog("[gateway] lsof failed: %@", error.localizedDescription)
        }
    }

    /// Check if a gateway URL points back to our own local gateway
    /// (either directly via localhost or through our ngrok tunnel).
    private func isOwnGateway(_ url: String) -> Bool {
        let local = GatewayProcess.shared.localURL
        if url == local { return true }

        // Check if the URL matches our tunnel domain
        if let tunnelURL = tunnel.publicURL {
            let tunnelHost = URL(string: tunnelURL.replacingOccurrences(of: "wss://", with: "https://"))?.host
            let urlHost = URL(string: url.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://"))?.host
            if let th = tunnelHost, let uh = urlHost, th == uh { return true }
        }

        return false
    }

    /// Route incoming synced messages to agents (only human messages to avoid loops).
    /// Route remote messages to local companions. Bare @Echo mentions trigger
    /// local companions directly since the remote peer may not have that companion.
    /// Namespaced @Echo@gordon also works for explicit targeting.
    /// Auto-register a remote SDK agent as a companion the first time it sends a message.
    /// Remote agents (senderType=="agent" + senderOwner set) connect via invite URL but don't
    /// have a prior AgentConfig — they would be invisible in the companion list without this.
    private func autoRegisterRemoteAgent(senderName: String, ownerName: String, spaceId: String) {
        // Already registered as a companion?
        guard !companions.contains(where: { $0.displayName == senderName && $0.mode == .remote }) else { return }
        guard let user = currentUser else { return }
        guard let space = spaces.first(where: { $0.id == spaceId }) else { return }

        let agent = AgentConfig.createRemote(
            ownerId: user.id,
            displayName: senderName,
            ownerName: ownerName
        )
        do {
            try db.saveAgent(agent)
            companions = try db.getAllAgents()
            try db.assignAgentToSpace(agentId: agent.id, spaceId: space.id)
            if currentSpace?.id == space.id {
                spaceCompanions = try db.getAgentsForSpace(spaceId: space.id)
            }
            print("[Port42] Auto-registered remote agent '\(senderName)' (owner: \(ownerName))")
        } catch {
            print("[Port42] Failed to auto-register remote agent: \(error)")
        }
    }

    private func handleIncomingSyncedMessage(spaceId: String, message: Message) {
        // Messages with a senderOwner are human-operated tools (CLI, SDK) — treat as human-initiated
        // even though senderType is "agent". Only autonomous companions (no senderOwner) get cooldown.
        let isAISender = message.senderType != "human" && message.senderOwner == nil

        // Auto-register SDK agents as remote companions on first message
        if message.senderType == "agent", let ownerName = message.senderOwner {
            autoRegisterRemoteAgent(senderName: message.senderName, ownerName: ownerName, spaceId: spaceId)
        }
        NSLog("[Port42] handleIncomingSyncedMessage: sender=%@ type=%@ isAI=%d content=%@", message.senderName, message.senderType, isAISender ? 1 : 0, String(message.content.prefix(80)))

        let spaceAgents = (try? db.getAgentsForSpace(spaceId: spaceId)) ?? []
        let spaceAgentIds = Set(spaceAgents.map { $0.id })

        // Skip if no companions in space AND no @mentions (nothing to route to)
        let hasMentions = !MentionParser.extractMentions(from: message.content).isEmpty
        guard !spaceAgents.isEmpty || hasMentions else {
            NSLog("[Port42] No agents in space %@ and no mentions, skipping", spaceId)
            return
        }

        // Route @mentions to bridged terminals (e.g. Claude Code running in a terminal port).
        // In a 1:1 DM the sole companion is implicit (no @mention needed) — resolve by membership.
        let dmCompanionId = (try? db.companionId(ofDirectSpaceId: spaceId)) ?? nil
        let implicitCompanion: AgentConfig? = dmCompanionId.flatMap { cid in companions.first(where: { $0.id == cid }) }
        routeMentionsToTerminals(content: message.content, senderName: message.senderName, spaceId: spaceId, implicitCompanion: implicitCompanion)

        let targets = AgentRouter.findTargetAgents(
            content: message.content, agents: companions,
            spaceAgentIds: spaceAgentIds, localOwner: currentUser?.displayName,
            requireNamespace: false
        )

        NSLog("[Port42] AgentRouter found %d targets from %d companions", targets.count, companions.count)
        guard !targets.isEmpty else { return }

        // For AI-to-AI messages, apply cooldown to prevent loops
        let filteredTargets: [AgentConfig]
        if isAISender {
            let now = Date()
            filteredTargets = targets.filter { agent in
                let key = "\(spaceId):\(agent.id)"
                if let last = agentAICooldowns[key], now.timeIntervalSince(last) < aiCooldownInterval {
                    print("[Port42] Cooldown: skipping \(agent.displayName) in \(spaceId) (AI-to-AI, \(Int(now.timeIntervalSince(last)))s ago)")
                    return false
                }
                agentAICooldowns[key] = now
                return true
            }
            guard !filteredTargets.isEmpty else { return }
        } else {
            filteredTargets = targets
        }

        let spaceMessages = (try? db.getMessages(spaceId: spaceId)) ?? []

        // LLM routing for multi-companion, non-@mention, non-AI messages
        let mentions = MentionParser.extractMentions(from: message.content)
        let shouldRoute = mentions.isEmpty && !isAISender && filteredTargets.count >= 2

        if shouldRoute {
            let recentMessages = spaceMessages.suffix(10).map { (sender: $0.senderName, content: $0.content) }
            let capturedTargets = filteredTargets
            let capturedContent = message.content
            let capturedSenderId = message.senderId
            let capturedSenderName = message.senderName
            Task { @MainActor in
                if let decisions = await self.llmRouter.route(
                    message: capturedContent,
                    senderName: capturedSenderName,
                    companions: capturedTargets,
                    recentMessages: recentMessages
                ) {
                    let activeIds = Set(decisions.filter { $0.action != .silent }.map { $0.agentId })
                    let activeTargets = capturedTargets.filter { activeIds.contains($0.id) }
                    NSLog("[Router] Synced: %d/%d companions active", activeTargets.count, capturedTargets.count)
                    if !activeTargets.isEmpty {
                        self.launchAgents(
                            activeTargets, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
                            spaceMessages: spaceMessages, triggerContent: capturedContent,
                            senderId: capturedSenderId, senderName: capturedSenderName
                        )
                    }
                } else {
                    self.launchAgents(
                        capturedTargets, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
                        spaceMessages: spaceMessages, triggerContent: capturedContent,
                        senderId: capturedSenderId, senderName: capturedSenderName
                    )
                }
            }
        } else {
            launchAgents(
                filteredTargets, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
                spaceMessages: spaceMessages, triggerContent: message.content,
                senderId: message.senderId, senderName: message.senderName
            )
        }

        // Initiative: check companions NOT already targeted for watching signal matches
        if !isAISender {
            let targetedIds = Set(filteredTargets.map { $0.id })
            checkInitiativeTriggers(
                spaceId: spaceId, messageContent: message.content,
                alreadyTargeted: targetedIds, senderId: message.senderId, senderName: message.senderName
            )
        }
    }

    /// Route a message to a bridged terminal if any @mention matches its name,
    /// or if an implicit companion is supplied (e.g. the Swim companion).
    private func routeMentionsToTerminals(content: String, senderName: String, spaceId: String, implicitCompanion: AgentConfig? = nil) {
        // Proceed if there's any terminal bridge/controller OR any openInTerminal companion —
        // the last case lets a mention auto-reopen a companion whose port is currently closed
        // (no live controller), which the early-return would otherwise prevent.
        let hasTerminalCompanions = companions.contains(where: { $0.openInTerminal })
        guard !terminalControllers.isEmpty || hasTerminalCompanions else { return }

        // Build the set of keys to route to: explicit @mentions + implicit companion (Swim)
        var keys: [String] = MentionParser.extractMentions(from: content)
            .map { String($0.dropFirst()).lowercased() }  // strip leading @
        if let implicit = implicitCompanion, !keys.contains(implicit.displayName.lowercased()) {
            keys.append(implicit.displayName.lowercased())
        }
        // Never route a message back into the sender's own terminal (a companion @mentioning
        // itself would otherwise self-inject and could loop).
        keys.removeAll { $0 == senderName.lowercased() }
        guard !keys.isEmpty else { return }

        // Prefix the sender with "@" so terminal companions see usernames in the same
        // @mention form they use to reference others — consistent referencing the LLM learns from.
        let line = "[@\(senderName)]: \(content)\r"
        for key in keys {
            if let companion = companions.first(where: {
                $0.displayName.lowercased() == key && $0.openInTerminal
            }) {
                // Native Ghostty terminal companion. Set the "typing…" indicator HERE
                // (cleared by the controller's post closure on turnComplete). launchAgents
                // skips openInTerminal companions, so the optimistic typing loops must NOT
                // set it — this route is the only point a native terminal companion is driven.
                let name = companion.displayName
                if let controller = terminalControllers.values.first(where: {
                    $0.config.companionName.lowercased() == key
                }), controller.isSurfaceBound {
                    // Live terminal: inject now AND arm the next turnComplete so only this
                    // reply is broadcast back to the space.
                    controller.inject(line)
                    setTerminalTyping(name: name, spaceId: spaceId)
                    NSLog("[Port42] Routed '%@' to native terminal", key)
                } else {
                    // Terminal closed/minimized (or mid-(re)spawn): queue the message and
                    // ensure a live terminal exists. The controller drains the queue once the
                    // CLI signals readiness (SessionStart). Auto-reopen + deliver.
                    pendingTerminalInjections[key, default: []].append(line)
                    ensureTerminalLive(companion: companion, spaceId: spaceId)
                    setTerminalTyping(name: name, spaceId: spaceId)
                    NSLog("[Port42] Queued '%@' for native terminal (auto-reopen)", key)
                }
            }
        }
    }

    /// Ensure a live native terminal exists for a CLI companion, idempotently. Used by the
    /// auto-reopen path: @mentioning an `openInTerminal` companion whose port was closed or
    /// minimized rebuilds it. Safe to call repeatedly — it no-ops when a terminal already
    /// exists or is mid-build (popOut appends the panel synchronously, so a second call sees it).
    func ensureTerminalLive(companion: AgentConfig, spaceId: String) {
        let key = companion.displayName.lowercased()
        // Already has a live controller → nothing to do.
        if terminalControllers.values.contains(where: { $0.config.companionName.lowercased() == key }) {
            return
        }
        // A panel already exists for this companion: restore it if backgrounded (minimized),
        // otherwise it is mid-build — leave it (its controller will appear shortly).
        if let panel = portWindows.panels.first(where: { $0.terminalConfig?.companionName.lowercased() == key }) {
            if panel.isBackground {
                NSLog("[Port42] Restoring backgrounded terminal for '%@'", key)
                portWindows.restore(panel.id)
            }
            return
        }
        // No panel at all → fully closed → spawn a fresh terminal port.
        guard let command = companion.command else {
            NSLog("[Port42] ensureTerminalLive: '%@' has no command, cannot respawn", key)
            return
        }
        NSLog("[Port42] Respawning closed terminal for '%@'", key)
        spawnTerminalAgentPort(companion: companion, command: command, spaceId: spaceId)
    }

    /// Set a native terminal companion's "typing…" indicator and arm a safety timeout so it can
    /// never hang: if no reply clears it within the window (e.g. a (re)spawn that never reaches
    /// turnComplete), it auto-clears. Cleared early by `clearTerminalTyping` on turnComplete.
    func setTerminalTyping(name: String, spaceId: String) {
        typingAgentNamesBySpace[spaceId, default: []].insert(name)
        sync.sendTyping(spaceId: spaceId, senderName: name, isTyping: true,
                        senderOwner: currentUser?.displayName)
        let key = "\(spaceId):\(name)"
        terminalTypingTimers[key]?.invalidate()
        terminalTypingTimers[key] = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                NSLog("[Port42] Terminal typing safety-timeout fired for '%@' — clearing", name)
                self.clearTerminalTyping(name: name, spaceId: spaceId)
            }
        }
    }

    /// Clear a native terminal companion's "typing…" indicator and cancel its safety timeout.
    func clearTerminalTyping(name: String, spaceId: String) {
        typingAgentNamesBySpace[spaceId, default: []].remove(name)
        sync.sendTyping(spaceId: spaceId, senderName: name, isTyping: false,
                        senderOwner: currentUser?.displayName)
        let key = "\(spaceId):\(name)"
        terminalTypingTimers[key]?.invalidate()
        terminalTypingTimers[key] = nil
    }

    /// Trigger space agents with terminal output — called by the game loop, not event-driven.
    /// Only routes to the companion that owns the bridge (createdBy), preventing other
    /// Insert a system message when a remote peer joins or leaves.
    /// Uses the sender name provided by the gateway presence protocol.
    /// Tracks last presence status per user per space to deduplicate rapid reconnects
    private var lastPresenceStatus: [String: String] = [:]

    private func handlePresenceAnnouncement(spaceId: String, senderId: String, senderName: String?, status: String) {
        // Skip local companion IDs
        let allAgentIds = Set(companions.map { $0.id })
        guard !allAgentIds.contains(senderId) else { return }
        // Skip remote companions matched by display name (gateway assigns UUID, not AgentConfig ID)
        if let name = senderName, companions.contains(where: { $0.displayName == name && $0.mode == .remote }) { return }

        // Use name from gateway, skip if unavailable (don't show raw UUIDs)
        guard let name = senderName, !name.isEmpty else { return }

        // Deduplicate: skip if same status as last announcement for this user+space
        let key = "\(spaceId):\(senderId)"
        guard lastPresenceStatus[key] != status else { return }
        lastPresenceStatus[key] = status

        let verb = status == "online" ? "joined" : "left"
        let content = "\(name) \(verb) the space"

        let sysMessage = Message(
            id: UUID().uuidString,
            spaceId: spaceId,
            senderId: senderId,
            senderName: name,
            senderType: "system",
            content: content,
            timestamp: Date(),
            replyToId: nil,
            syncStatus: "local",
            createdAt: Date()
        )

        do {
            try db.saveMessage(sysMessage)
        } catch {
            print("[Port42] Failed to save presence announcement: \(error)")
        }
    }

    /// Launch agents with staggered delays so companions respond at different rates
    /// Check if any companions' watching signals or holding text match the message content.
    /// Only fires for companions NOT already being triggered by normal routing.
    /// Launches matching companions with an initiative-framed trigger.
    func checkInitiativeTriggers(
        spaceId: String, messageContent: String,
        alreadyTargeted: Set<String>, senderId: String, senderName: String
    ) {
        let spaceAgents = (try? db.getAgentsForSpace(spaceId: spaceId)) ?? []
        let lowered = messageContent.lowercased()

        // triggerText is the full initiative-framed content passed to the LLM
        var initiativeAgents: [(agent: AgentConfig, triggerText: String, logLabel: String)] = []

        for agent in spaceAgents where !alreadyTargeted.contains(agent.id) && agent.mode == .llm {
            // D4: initiative reads the companion's position for THIS space.
            // A — watching signals
            if let pos = try? db.fetchPosition(companionId: agent.id, spaceId: spaceId),
               let watching = pos.watching, !watching.isEmpty {
                for signal in watching {
                    if lowered.contains(signal.lowercased()) {
                        let trigger = "[initiative: your watching signal was matched — \"\(signal)\"]\n\(messageContent)"
                        initiativeAgents.append((agent: agent, triggerText: trigger, logLabel: "watching:\(signal)"))
                        break
                    }
                }
            }

            // B — holding text: already triggered above? skip
            guard !initiativeAgents.contains(where: { $0.agent.id == agent.id }) else { continue }
            if let fold = try? db.fetchFold(companionId: agent.id, spaceId: spaceId),
               let holding = fold.holding, !holding.isEmpty {
                let keywords = holdingKeywords(from: holding)
                for keyword in keywords {
                    if lowered.contains(keyword) {
                        let trigger = "[initiative: something you're holding is relevant]\nHolding: \(holding)\n\nMessage: \(messageContent)"
                        initiativeAgents.append((agent: agent, triggerText: trigger, logLabel: "holding:\(keyword)"))
                        break
                    }
                }
            }
        }

        guard !initiativeAgents.isEmpty else { return }

        let spaceMessages = (try? db.getMessages(spaceId: spaceId)) ?? []

        for (index, match) in initiativeAgents.enumerated() {
            // Stagger after normal routing window (start at 4s, then 1.5s per companion)
            let baseDelay = 4.0 + Double(index) * 1.5
            let jitter = Double.random(in: 0.5...1.5)
            let delay = baseDelay + jitter

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let msgs = (try? self.db.getMessages(spaceId: spaceId)) ?? spaceMessages
                let handler = SpaceAgentHandler(agent: match.agent, spaceId: spaceId, appState: self)
                self.activeAgentHandlers[handler.messageId] = handler
                handler.start(spaceMessages: msgs, triggerContent: match.triggerText)
            }

            NSLog("[Port42] Initiative trigger: %@ matched '%@' in space %@",
                  match.agent.displayName, match.logLabel, spaceId)
        }
    }

    /// Extract content words from holding prose for keyword matching.
    private func holdingKeywords(from text: String) -> [String] {
        let stopwords: Set<String> = [
            "a","an","the","and","or","but","in","on","at","to","for","of","with","by",
            "from","about","as","is","are","was","were","be","been","has","have","had",
            "do","does","did","will","would","could","should","may","might","must","can",
            "not","no","it","its","this","that","i","you","he","she","we","they",
            "my","your","his","her","our","their","what","which","who","when","where",
            "how","if","so","just","also","too","very","more","most","some","any","all",
            "still","yet","then","than","into","up","out","now","new","own","same","other"
        ]
        return text
            .lowercased()
            .components(separatedBy: .init(charactersIn: " .,;:—–-/\n\t\"'()[]"))
            .filter { $0.count >= 4 && !stopwords.contains($0) }
    }

    private func launchAgents(
        _ agents: [AgentConfig], spaceId: String, spaceAgentIds: Set<String>,
        spaceMessages: [Message], triggerContent: String,
        senderId: String, senderName: String
    ) {
        for (index, agent) in agents.enumerated() {
            if !spaceAgentIds.contains(agent.id) {
                if let space = spaces.first(where: { $0.id == spaceId }) {
                    addCompanionToSpace(agent, space: space)
                }
            }

            // Stagger responses: base delay per position + random jitter
            let baseDelay = Double(index) * 1.5
            let jitter = Double.random(in: 0.5...2.5)
            let delay = baseDelay + jitter

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // openInTerminal companions are driven by routeMentionsToTerminals —
                // they must NOT spawn background processes here or we get runaway forks.
                guard !agent.openInTerminal else { return }

                switch agent.mode {
                case .llm:
                    let msgs = (try? self.db.getMessages(spaceId: spaceId)) ?? spaceMessages
                    let handler = SpaceAgentHandler(agent: agent, spaceId: spaceId, appState: self)
                    self.activeAgentHandlers[handler.messageId] = handler
                    handler.start(spaceMessages: msgs, triggerContent: triggerContent)
                case .command:
                    let handler = CommandAgentHandler(agent: agent, spaceId: spaceId, appState: self)
                    self.activeCommandHandlers[handler.messageId] = handler
                    handler.start(triggerContent: triggerContent, senderId: senderId, senderName: senderName)
                case .remote:
                    break  // Remote agents handle their own triggering via WebSocket
                }
            }
        }
    }

    // MARK: - Setup

    public func completeSetup(displayName: String) {
        showDreamscape = false

        // User + keys already created during name submission step
        guard let user = currentUser else {
            print("[Port42] completeSetup called but no currentUser")
            return
        }

        do {
            let general = Space.create(name: "general")
            try db.saveSpace(general)

            let welcome = Message(
                id: UUID().uuidString,
                spaceId: general.id,
                senderId: "system",
                senderName: "Port42",
                senderType: "system",
                content: "Welcome to Port42. This is your space.",
                timestamp: Date(),
                replyToId: nil,
                syncStatus: "local",
                createdAt: Date()
            )
            try db.saveMessage(welcome)

            spaces = try db.getRegularSpaces()
            selectSpace(general)
            startSpaceObservation()

            // Create default companion and swim into it
            let echoPrompt: String = {
                if let url = Bundle.port42.url(forResource: "echo-prompt", withExtension: "txt"),
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    return text.replacingOccurrences(of: "{{USER}}", with: displayName)
                }
                return "You are Echo, an AI companion inside Port42. You are \(displayName)'s companion. Keep responses concise and conversational."
            }()
            let companion = AgentConfig.createLLM(
                ownerId: user.id,
                displayName: "echo",
                systemPrompt: echoPrompt,
                provider: .anthropic,
                model: "claude-opus-4-6",
                trigger: .mentionOnly
            )
            try db.saveAgent(companion)
            companions = try db.getAllAgents()

            // Open swim but don't send yet.
            // SetupView will trigger the first message after the transition animation.
            startSwim(with: companion)

            Analytics.shared.configure(userId: user.id)
            Analytics.shared.setupCompleted()

            // Start gateway and sync now (don't wait for next app launch)
            configureSyncIfNeeded(userId: user.id)

            // Refresh auth status after setup (user just configured auth)
            authStatus = .checking
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let status = AgentAuthResolver.shared.checkStatus()
                DispatchQueue.main.async {
                    self?.authStatus = status
                }
            }
        } catch {
            print("[Port42] Setup failed: \(error)")
        }
    }

    // MARK: - Spaces

    /// Join a space on the gateway, including companion IDs for cross-instance presence
    private func syncJoinSpace(_ spaceId: String, token: String? = nil) {
        if let space = spaces.first(where: { $0.id == spaceId }), !space.syncEnabled { return }
        let companionIds = ((try? db.getAgentsForSpace(spaceId: spaceId)) ?? []).map { $0.id }
        sync.joinSpace(spaceId, companionIds: companionIds, token: token)
    }

    public func selectSpace(_ space: Space) {
        // Persist immediately (cheap)
        UserDefaults.standard.set(space.id, forKey: "lastSelectedSpaceId")
        UserDefaults.standard.removeObject(forKey: "lastActiveSwimCompanionId")
        if let current = currentSpace { lastReadDates[current.id] = Date() }

        currentSpace = space
        lastReadDates[space.id] = Date()
        if portPanelsRestored && isSetupComplete {
            portWindows.switchToSpace(space.id, spaceName: space.name)
        }
        Analytics.shared.spaceSwitched()
        Analytics.shared.screen("Space")

        // Cancel any in-flight observation setup from previous rapid clicks.
        // Don't clear messages/companions — keep showing the previous space's
        // content while the user is clicking. The observation will replace it
        // when we actually commit.
        observationDebounceTask?.cancel()
        observationDebounceTask = Task { [weak self] in
            guard let self else { return }
            // Wait for the user to settle before doing any DB work.
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            guard !Task.isCancelled, self.currentSpace?.id == space.id else { return }

            // Now commit: clear stale content and load the real space.
            self.messages = []
            self.spaceCompanions = (try? self.db.getAgentsForSpace(spaceId: space.id)) ?? []

            // ValueObservation fires immediately from a background reader thread —
            // no blocking main-thread DB read needed.
            self.startMessageObservation(spaceId: space.id)
            self.startUnreadObservation()

            self.syncJoinSpace(space.id)
            self.sync.sendReadReceipt(spaceId: space.id)
        }
    }

    public func createSpace(name: String, heartbeatInterval: Int = 0, heartbeatPrompt: String = "") {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard !cleaned.isEmpty else { return }

        var space = Space.create(name: cleaned)
        space.heartbeatInterval = heartbeatInterval
        space.heartbeatPrompt = heartbeatInterval > 0 ? heartbeatPrompt : ""
        // SHELL S3 — assign an accent for life by creation position (spec decision #1); the space
        // keeps this color even as others are added/deleted. Stored on the row via saveSpace.
        space.accent = ShellState.accentHex(forNewSpaceAt: spaces.count)
        do {
            try db.saveSpace(space)
            spaces = try db.getRegularSpaces()
            syncJoinSpace(space.id)
            selectSpace(space)
            scheduleHeartbeat(for: space)
            Analytics.shared.spaceCreated()
        } catch {
            print("[Port42] Failed to create space: \(error)")
        }
    }

    public func updateSpace(_ space: Space) {
        do {
            try db.saveSpace(space)
            spaces = try db.getRegularSpaces()
            if currentSpace?.id == space.id { currentSpace = space }
            scheduleHeartbeat(for: space)
        } catch {
            print("[Port42] Failed to update space: \(error)")
        }
    }

    // MARK: - Rest / Wake (the working set — docs/plan-working-set.md §A)
    //
    // Every space is either in the WORKING SET (galaxy front, ⌘1–9, peeks live) or AT REST
    // (off the front, no index, fully silent). `spaces` keeps holding ALL regular spaces —
    // ⌘K and the galaxy shelf need the rested ones — the split is computed here.

    /// The working set: what the galaxy front, ⌘1–9 and the space switcher index.
    public var workingSpaces: [Space] { spaces.filter { !$0.isResting } }

    /// The galaxy shelf: rested spaces, most recently rested first.
    public var restingSpaces: [Space] {
        spaces.filter { $0.isResting }
            .sorted { ($0.restedAt ?? .distantPast) > ($1.restedAt ?? .distantPast) }
    }

    /// Guard: only a WORKING space can rest (no double-rest). ANY working space may — including
    /// the last one (GM call 2026-07-14, reversing the plan's original last-space guard): an
    /// all-rested galaxy is simply an empty front with a full shelf. Pure → headless.
    nonisolated public static func canRest(_ spaces: [Space], id: String) -> Bool {
        spaces.first(where: { $0.id == id })?.isResting == false
    }

    /// Where resting `id` lands you: non-nil only when resting the CURRENT space — the first
    /// OTHER working space. Resting the last working space returns nil: you simply STAY in the
    /// now-rested space (it's still alive, just off the front). (A's minimal recency fallback;
    /// C's MRU stack upgrades this one function to "most recent working space".) Pure → headless.
    nonisolated public static func restLandingId(_ spaces: [Space], resting id: String,
                                                 currentId: String?) -> String? {
        guard currentId == id else { return nil }
        return spaces.first { !$0.isResting && $0.id != id }?.id
    }

    /// Rest a space: off the galaxy front, unindexed, fully silent (sync continues underneath).
    /// Resting the current space lands you in the first other working space, if any exists.
    public func restSpace(_ space: Space) {
        guard Self.canRest(spaces, id: space.id) else { return }
        let landingId = Self.restLandingId(spaces, resting: space.id, currentId: currentSpace?.id)
        var s = space
        s.restedAt = Date()
        updateSpace(s)
        if let landingId, let landing = spaces.first(where: { $0.id == landingId }) {
            selectSpace(landing)
        }
    }

    /// Wake a rested space: back into the working set (galaxy front, indexes, peeks).
    public func wakeSpace(_ space: Space) {
        guard space.isResting else { return }
        var s = space
        s.restedAt = nil
        updateSpace(s)
    }

    /// Wake + enter — the galaxy-shelf click and the ⌘K path (selecting a rested space).
    public func wakeAndEnterSpace(_ space: Space) {
        wakeSpace(space)
        if let woken = spaces.first(where: { $0.id == space.id }) { selectSpace(woken) }
    }

    // MARK: - Heartbeats

    public func scheduleAllHeartbeats() {
        for space in spaces {
            scheduleHeartbeat(for: space)
        }
    }

    private func scheduleHeartbeat(for space: Space) {
        heartbeatTimers[space.id]?.invalidate()
        heartbeatTimers.removeValue(forKey: space.id)
        guard space.heartbeatInterval > 0 else { return }
        let interval = TimeInterval(space.heartbeatInterval * 60)
        heartbeatTimers[space.id] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fireHeartbeat(spaceId: space.id)
            }
        }
    }

    private func fireHeartbeat(spaceId: String) {
        guard let space = spaces.first(where: { $0.id == spaceId }),
              space.heartbeatInterval > 0 else { return }
        let prompt = space.heartbeatPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let spaceAgents = (try? db.getAgentsForSpace(spaceId: spaceId)) ?? []
        let llmAgents = spaceAgents.filter { $0.mode == .llm }
        guard !llmAgents.isEmpty else { return }

        let spaceMessages = (try? db.getMessages(spaceId: spaceId)) ?? []
        let spaceAgentIds = Set(spaceAgents.map { $0.id })
        NSLog("[Port42] Heartbeat firing in #%@ — %d agents", space.name, llmAgents.count)
        launchAgents(llmAgents, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
                     spaceMessages: spaceMessages, triggerContent: prompt,
                     senderId: "heartbeat", senderName: "heartbeat")
    }

    public func joinSpaceFromInvite(_ invite: SpaceInviteData) {
        // If space already exists locally, update encryption key if provided and select it
        if var existing = spaces.first(where: { $0.id == invite.spaceId }) {
            if let newKey = invite.encryptionKey, existing.encryptionKey == nil {
                existing.encryptionKey = newKey
                do {
                    try db.saveSpace(existing)
                    spaces = try db.getRegularSpaces()
                } catch {
                    print("[Port42] Failed to update space key: \(error)")
                }
            }

            // If invite points to a different gateway, switch to it
            let currentGW = sync.gatewayURL ?? ""
            if !isOwnGateway(invite.gateway) && currentGW != invite.gateway, let user = currentUser {
                UserDefaults.standard.set(invite.gateway, forKey: "gatewayURL")
                #if !RELEASE
                sync.configure(gatewayURL: invite.gateway, userId: user.id, userName: user.displayName, db: db, appleAuth: appleAuth, appleUserID: user.appleUserID)
                #else
                sync.configure(gatewayURL: invite.gateway, userId: user.id, userName: user.displayName, db: db)
                #endif
                sync.connect()
                for ch in spaces {
                    syncJoinSpace(ch.id)
                }
                syncJoinSpace(existing.id, token: invite.token)
            }

            selectSpace(existing)
            return
        }

        // Create the space with the shared ID and encryption key
        let space = Space(
            id: invite.spaceId,
            name: invite.spaceName,
            type: "team",
            createdAt: Date(),
            encryptionKey: invite.encryptionKey
        )
        do {
            try db.saveSpace(space)
            spaces = try db.getRegularSpaces()
        } catch {
            print("[Port42] Failed to save invited space: \(error)")
            return
        }

        // Configure sync to the invite's gateway if different.
        // But don't switch away from our local gateway if the invite points
        // back to us (e.g. through our own ngrok tunnel).
        let currentGW = sync.gatewayURL ?? ""
        let invitePointsToSelf = isOwnGateway(invite.gateway)

        if invitePointsToSelf {
            // Invite is for our own gateway, just join the space
            syncJoinSpace(space.id, token: invite.token)
        } else if currentGW != invite.gateway, let user = currentUser {
            // Different remote gateway, switch to it
            UserDefaults.standard.set(invite.gateway, forKey: "gatewayURL")
            #if !RELEASE
            sync.configure(gatewayURL: invite.gateway, userId: user.id, userName: user.displayName, db: db, appleAuth: appleAuth, appleUserID: user.appleUserID)
            #else
            sync.configure(gatewayURL: invite.gateway, userId: user.id, userName: user.displayName, db: db)
            #endif
            sync.connect()
            // Join all existing spaces (no token needed, already members)
            for ch in spaces where ch.id != space.id {
                syncJoinSpace(ch.id)
            }
            // Join the invited space with the token
            syncJoinSpace(space.id, token: invite.token)
        } else {
            syncJoinSpace(space.id, token: invite.token)
        }

        selectSpace(space)
        Analytics.shared.inviteJoined()
        print("[Port42] Joined space from invite: #\(invite.spaceName) via \(invite.gateway)")

        // Don't prompt ngrok setup on join — only needed when sharing invite links
    }

    /// Ensure a space has an encryption key. Generates one for legacy spaces
    /// that were created before encryption was added. Returns the updated space.
    @discardableResult
    public func ensureEncryptionKey(for space: Space) -> Space {
        guard space.encryptionKey == nil else { return space }
        var updated = space
        updated.encryptionKey = SpaceCrypto.generateKey()
        do {
            try db.saveSpace(updated)
            spaces = try db.getRegularSpaces()
            if currentSpace?.id == space.id {
                currentSpace = updated
            }
        } catch {
            print("[Port42] Failed to save encryption key: \(error)")
        }
        return updated
    }

    public func deleteSpace(_ space: Space) {
        do {
            try db.deleteSpace(id: space.id)
            spaces = try db.getRegularSpaces()

            // If we deleted the last space, create a fresh general
            if spaces.isEmpty {
                let general = Space.create(name: "general")
                try db.saveSpace(general)
                spaces = try db.getRegularSpaces()
            }

            if currentSpace?.id == space.id {
                if let first = workingSpaces.first ?? spaces.first {   // never land in a rested space
                    selectSpace(first)
                }
            }
        } catch {
            print("[Port42] Failed to delete space: \(error)")
        }
    }

    // MARK: - Messages

    /// Stop all active LLM streams in the given space.
    public func cancelStreaming(spaceId: String) {
        let toCancel = activeAgentHandlers.filter { $0.value.spaceId == spaceId }
        for (id, handler) in toCancel {
            handler.cancelEngine()
            activeAgentHandlers.removeValue(forKey: id)
        }
    }

    /// Re-send the last human message in the given space (clears error state first).
    public func retryLastMessage(spaceId: String) {
        spaceErrors[spaceId] = nil
        guard let lastUserMsg = messages.last(where: { $0.spaceId == spaceId && $0.senderType == "human" }) else { return }
        sendMessage(content: lastUserMsg.content)
    }

    /// Send a message to a specific space (or current space if nil). Routes to companions.
    public func sendMessage(content: String, toSpaceId: String? = nil) {
        guard let user = currentUser else { return }
        let space: Space
        if let targetId = toSpaceId {
            // Resolve ANY space by id — `spaces` is getRegularSpaces() and EXCLUDES direct/DM spaces,
            // so a DM/swim target must fall back to currentSpace (the DM you're in) or the full space
            // list. Without this, sending in a DM silently no-ops.
            if let ch = spaces.first(where: { $0.id == targetId })
                ?? (currentSpace?.id == targetId ? currentSpace : nil)
                ?? (try? db.getAllSpaces())?.first(where: { $0.id == targetId }) {
                space = ch
            } else { return }
        } else {
            guard let ch = currentSpace else { return }
            space = ch
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        spaceErrors[space.id] = nil

        let message = Message.create(
            spaceId: space.id,
            senderId: user.id,
            senderName: user.displayName,
            content: trimmed
        )

        do {
            try db.saveMessage(message)
            // Send to relay if connected
            sync.sendMessage(message)
            Analytics.shared.messageSent()
        } catch {
            print("[Port42] Failed to send message: \(error)")
        }

        // Route to agents via @mention detection + space membership
        let isCurrentSpace = space.id == currentSpace?.id
        let chCompanions = isCurrentSpace
            ? spaceCompanions
            : ((try? db.getAgentsForSpace(spaceId: space.id)) ?? [])
        let chMessages = isCurrentSpace
            ? messages
            : ((try? db.getMessages(spaceId: space.id)) ?? [])
        var spaceAgentIds = Set(chCompanions.map { $0.id })
        let mentions = MentionParser.extractMentions(from: trimmed)

        // Route @mentions to bridged terminals. In a direct (1:1 DM) space, an un-@'d
        // message implicitly routes to that space's sole companion.
        let implicitCompanion = space.type == "direct" ? chCompanions.first : nil
        routeMentionsToTerminals(content: trimmed, senderName: user.displayName, spaceId: space.id, implicitCompanion: implicitCompanion)

        // @mentioning a companion auto-adds them to the space
        if !mentions.isEmpty {
            let targets = AgentRouter.findTargetAgents(content: trimmed, agents: companions, spaceAgentIds: spaceAgentIds, localOwner: currentUser?.displayName)
            for agent in targets where !spaceAgentIds.contains(agent.id) {
                addCompanionToSpace(agent, space: space)
                spaceAgentIds.insert(agent.id)
            }
        }

        let targets = AgentRouter.findTargetAgents(content: trimmed, agents: companions, spaceAgentIds: spaceAgentIds, localOwner: currentUser?.displayName)
        let shouldRoute = mentions.isEmpty && targets.count >= 2

        if shouldRoute {
            // LLM routing: haiku decides who speaks
            let recentMessages = chMessages.suffix(10).map { (sender: $0.senderName, content: $0.content) }
            // Show typing for all targets optimistically while router runs.
            // openInTerminal companions are driven by routeMentionsToTerminals (which sets
            // their typing) and skipped by launchAgents, so excluding them here avoids a
            // typing indicator that would never be cleared.
            for agent in targets where !agent.openInTerminal { typingAgentNamesBySpace[space.id, default: []].insert(agent.displayName) }
            let capturedTargets = targets
            let capturedSpace = space
            let capturedMessages = chMessages
            let capturedUserId = user.id
            let capturedUserName = user.displayName
            let capturedTrimmed = trimmed
            Task { @MainActor in
                if let decisions = await llmRouter.route(
                    message: capturedTrimmed,
                    senderName: capturedUserName,
                    companions: capturedTargets,
                    recentMessages: recentMessages
                ) {
                    let activeIds = Set(decisions.filter { $0.action != .silent }.map { $0.agentId })
                    let activeTargets = capturedTargets.filter { activeIds.contains($0.id) }
                    // Clear typing for silenced companions
                    let silencedNames = Set(capturedTargets.map { $0.displayName }).subtracting(activeTargets.map { $0.displayName })
                    for name in silencedNames { self.typingAgentNamesBySpace[capturedSpace.id, default: []].remove(name) }

                    NSLog("[Router] %d/%d companions active", activeTargets.count, capturedTargets.count)
                    if !activeTargets.isEmpty {
                        self.launchAgents(
                            activeTargets, spaceId: capturedSpace.id, spaceAgentIds: spaceAgentIds,
                            spaceMessages: capturedMessages, triggerContent: capturedTrimmed,
                            senderId: capturedUserId, senderName: capturedUserName
                        )
                    }
                } else {
                    // Fallback: launch all targets (router failed)
                    NSLog("[Router] Fallback: launching all %d targets", capturedTargets.count)
                    self.launchAgents(
                        capturedTargets, spaceId: capturedSpace.id, spaceAgentIds: spaceAgentIds,
                        spaceMessages: capturedMessages, triggerContent: capturedTrimmed,
                        senderId: capturedUserId, senderName: capturedUserName
                    )
                }
            }
        } else {
            // Direct routing: @mentions or single companion — no LLM needed.
            // Skip openInTerminal companions (driven + typing-tracked by routeMentionsToTerminals).
            for agent in targets where !agent.openInTerminal { typingAgentNamesBySpace[space.id, default: []].insert(agent.displayName) }
            launchAgents(
                targets, spaceId: space.id, spaceAgentIds: spaceAgentIds,
                spaceMessages: chMessages, triggerContent: trimmed,
                senderId: user.id, senderName: user.displayName
            )
        }

        // Initiative: check companions NOT already targeted for watching signal matches.
        // When @mentions are present, those companions are definitely targeted.
        // When there are no @mentions, only allMessages companions are definitely
        // responding — mentionOnly companions are not in normal routing and should
        // be eligible for initiative even if they're space members.
        let initiativeExcluded: Set<String>
        if mentions.isEmpty {
            initiativeExcluded = Set(targets.filter { $0.trigger == .allMessages }.map { $0.id })
        } else {
            initiativeExcluded = Set(targets.map { $0.id })
        }
        checkInitiativeTriggers(
            spaceId: space.id, messageContent: trimmed,
            alreadyTargeted: initiativeExcluded, senderId: user.id, senderName: user.displayName
        )
    }

    /// Route a companion's response to other companions via the LLM router.
    /// Applies AI-to-AI cooldown to prevent loops. Router decides who (if anyone) responds.
    func routeCompanionResponse(content: String, senderId: String, senderName: String, spaceId: String) {
        // A companion's @mention of a native terminal companion must reach that terminal too.
        // User + synced messages route via routeMentionsToTerminals, but companion-originated
        // messages did not — so e.g. an LLM companion @mentioning a terminal companion was
        // silently dropped (never injected into its stdin).
        routeMentionsToTerminals(content: content, senderName: senderName, spaceId: spaceId)

        let spaceAgents = (try? db.getAgentsForSpace(spaceId: spaceId)) ?? []
        let spaceAgentIds = Set(spaceAgents.map { $0.id })
        let targets = AgentRouter.findTargetAgents(
            content: content, agents: companions,
            spaceAgentIds: spaceAgentIds, localOwner: currentUser?.displayName
        ).filter { $0.id != senderId }

        guard !targets.isEmpty else { return }

        // AI-to-AI cooldown — explicit @mentions bypass cooldown
        let mentions = MentionParser.extractMentions(from: content)
            .map { String($0.dropFirst()).lowercased() }
        let now = Date()
        let cooledTargets = targets.filter { agent in
            // Explicit @mention bypasses cooldown
            if mentions.contains(agent.displayName.lowercased()) {
                agentAICooldowns["\(spaceId):\(agent.id)"] = now
                return true
            }
            let key = "\(spaceId):\(agent.id)"
            if let last = agentAICooldowns[key], now.timeIntervalSince(last) < aiCooldownInterval {
                NSLog("[Port42] Cooldown: skipping %@ in companion chain (AI-to-AI, %ds ago)", agent.displayName, Int(now.timeIntervalSince(last)))
                return false
            }
            agentAICooldowns[key] = now
            return true
        }
        guard !cooledTargets.isEmpty else { return }

        // Split: explicitly @mentioned companions launch directly, others go through LLM router
        let mentionedTargets = cooledTargets.filter { mentions.contains($0.displayName.lowercased()) }
        let unmentionedTargets = cooledTargets.filter { !mentions.contains($0.displayName.lowercased()) }

        let spaceMessages = (try? db.getMessages(spaceId: spaceId)) ?? []

        // Explicit @mentions skip the router — the sender asked for them
        if !mentionedTargets.isEmpty {
            NSLog("[Router] Companion chain: %d explicitly mentioned by %@", mentionedTargets.count, senderName)
            launchAgents(
                mentionedTargets, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
                spaceMessages: spaceMessages, triggerContent: content,
                senderId: senderId, senderName: senderName
            )
        }

        // Non-mentioned companions still go through LLM router
        if !unmentionedTargets.isEmpty {
            let recentMessages = spaceMessages.suffix(10).map { (sender: $0.senderName, content: $0.content) }
            Task { @MainActor in
                if let decisions = await llmRouter.route(
                    message: content,
                    senderName: senderName,
                    companions: unmentionedTargets,
                    recentMessages: recentMessages
                ) {
                    let activeIds = Set(decisions.filter { $0.action != .silent }.map { $0.agentId })
                    let activeTargets = unmentionedTargets.filter { activeIds.contains($0.id) }
                    NSLog("[Router] Companion chain: %d/%d active after %@", activeTargets.count, unmentionedTargets.count, senderName)
                    if !activeTargets.isEmpty {
                        self.launchAgents(
                            activeTargets, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
                            spaceMessages: spaceMessages, triggerContent: content,
                            senderId: senderId, senderName: senderName
                        )
                    }
                }
            }
        }
    }

    /// Send a message attributed to a companion (for port-originated messages).
    /// Saves, syncs, and routes to other agents the same as a user message.
    public func sendMessageAsCompanion(_ companion: AgentConfig, content: String, spaceId: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = Message.create(
            spaceId: spaceId,
            senderId: companion.id,
            senderName: companion.displayName,
            content: trimmed,
            senderType: "agent",
            senderOwner: currentUser?.displayName
        )
        do {
            try db.saveMessage(message)
            sync.sendMessage(message)
        } catch {
            NSLog("[Port42] sendMessageAsCompanion failed: %@", error.localizedDescription)
            return
        }

        // Route this companion's @mentions of native terminal companions into their stdin.
        routeMentionsToTerminals(content: trimmed, senderName: companion.displayName, spaceId: spaceId)

        let spaceAgentIds = Set(spaceCompanions.map { $0.id })
        let targets = AgentRouter.findTargetAgents(
            content: trimmed, agents: companions,
            spaceAgentIds: spaceAgentIds, localOwner: currentUser?.displayName
        ).filter { $0.id != companion.id } // don't trigger the sender
        // Skip openInTerminal companions: launchAgents drops them, so their typing would
        // never clear (this was the cross-companion stuck-typing bug). routeMentionsToTerminals
        // owns native terminal typing.
        for agent in targets where !agent.openInTerminal { typingAgentNamesBySpace[spaceId, default: []].insert(agent.displayName) }
        launchAgents(
            targets, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
            spaceMessages: messages, triggerContent: trimmed,
            senderId: companion.id, senderName: companion.displayName
        )
    }

    /// Publish a message to a bus topic. Does not trigger companion chat routing.
    /// Used by bus_publish tool and internal signalling. Bus messages are excluded from the chat view.
    public func publishToBus(spaceId: String, topic: String, payload: String, senderName: String) {
        guard let user = currentUser else { return }
        let message = Message.create(
            spaceId: spaceId,
            senderId: user.id,
            senderName: senderName,
            content: payload,
            senderType: "agent",
            topic: topic
        )
        do {
            try db.saveMessage(message)
            sync.sendMessage(message)
        } catch {
            NSLog("[p42-state] publishToBus error: %@", error.localizedDescription)
        }
        checkBusInitiativeTriggers(spaceId: spaceId, payload: payload, senderName: senderName)
    }

    /// Check if any companions' bus: watching signals match a newly published bus payload.
    func checkBusInitiativeTriggers(spaceId: String, payload: String, senderName: String) {
        let spaceAgents = (try? db.getAgentsForSpace(spaceId: spaceId)) ?? []
        let lowered = payload.lowercased()

        for agent in spaceAgents where agent.mode == .llm {
            // D4: bus initiative reads the companion's position for THIS space.
            guard let pos = try? db.fetchPosition(companionId: agent.id, spaceId: spaceId),
                  let watching = pos.watching else { continue }

            for signal in watching where signal.hasPrefix("bus:") {
                let stripped = String(signal.dropFirst(4)).lowercased()
                guard !stripped.isEmpty, lowered.contains(stripped) else { continue }
                let msgs = (try? db.getMessages(spaceId: spaceId, topic: "chat")) ?? []
                let trigger = "[initiative: bus signal matched — \"\(signal)\"]\nPayload: \(payload)"
                let handler = SpaceAgentHandler(agent: agent, spaceId: spaceId, appState: self)
                activeAgentHandlers[handler.messageId] = handler
                handler.start(spaceMessages: msgs, triggerContent: trigger)
                NSLog("[Port42] Bus initiative trigger: %@ matched '%@'", agent.displayName, signal)
                break
            }
        }
    }

    /// Send a message attributed to a named external agent (HTTP CLI callers).
    /// Uses the provided senderName as identity instead of the current user.
    public func sendMessageAsNamedAgent(content: String, senderName: String, toSpaceId: String? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSLog("[p42-state] sendMessageAsNamedAgent: DROPPED empty content from %@", senderName)
            return
        }
        guard let spaceId = toSpaceId ?? currentSpace?.id,
              spaces.first(where: { $0.id == spaceId }) != nil else {
            NSLog("[p42-state] sendMessageAsNamedAgent: DROPPED — space not found. toSpaceId=%@ currentSpace=%@",
                  toSpaceId ?? "nil", currentSpace?.id ?? "nil")
            return
        }
        // Dedup: curl and capture can both fire for the same response within a few seconds
        let dedupKey = "\(senderName):\(spaceId):\(trimmed.prefix(120))"
        let now = Date()
        recentAgentSends.removeAll { now.timeIntervalSince($0.timestamp) > 5 }
        if recentAgentSends.contains(where: { $0.key == dedupKey }) {
            NSLog("[p42-state] sendMessageAsNamedAgent: DEDUPED sender=%@ preview=\"%@\"",
                  senderName, String(trimmed.prefix(80)))
            return
        }
        recentAgentSends.append((key: dedupKey, timestamp: now))
        NSLog("[p42-state] sendMessageAsNamedAgent: sender=%@ space=%@ len=%d preview=\"%@\"",
              senderName, spaceId, trimmed.count,
              String(trimmed.prefix(80)).replacingOccurrences(of: "\n", with: "↵"))
        let agentId = "cli-agent-\(senderName.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let message = Message.create(
            spaceId: spaceId,
            senderId: agentId,
            senderName: senderName,
            content: trimmed,
            senderType: "agent",
            senderOwner: currentUser?.displayName
        )
        do {
            try db.saveMessage(message)
            sync.sendMessage(message)
        } catch {
            NSLog("[Port42] sendMessageAsNamedAgent failed: %@", error.localizedDescription)
            return
        }
        // Route this agent's @mentions of native terminal companions into their stdin.
        routeMentionsToTerminals(content: trimmed, senderName: senderName, spaceId: spaceId)

        let spaceAgentIds = Set(spaceCompanions.map { $0.id })
        let targets = AgentRouter.findTargetAgents(
            content: trimmed, agents: companions,
            spaceAgentIds: spaceAgentIds, localOwner: currentUser?.displayName
        )
        // Skip openInTerminal companions (launchAgents drops them → typing never clears).
        for agent in targets where !agent.openInTerminal { typingAgentNamesBySpace[spaceId, default: []].insert(agent.displayName) }
        launchAgents(
            targets, spaceId: spaceId, spaceAgentIds: spaceAgentIds,
            spaceMessages: messages, triggerContent: trimmed,
            senderId: agentId, senderName: senderName
        )
    }

    // MARK: - Companions

    public func addCompanion(_ companion: AgentConfig) {
        do {
            try db.saveAgent(companion)
            companions = try db.getAllAgents()
            Analytics.shared.companionCreated()
        } catch {
            print("[Port42] Failed to save companion: \(error)")
        }
    }

    /// Create (or recreate) the controller backing a native terminal port. Called from
    /// `PortWindowManager` when a `portType == "terminal"` window is built — covers both
    /// fresh pop-outs and DB-restored panels. Recreates fresh each time so a rebuilt window
    /// never shares a stale hooks socket. Returns nil if the panel isn't a terminal port.
    @discardableResult
    func makeTerminalController(for panel: PortPanel) -> GhosttyTerminalController? {
        guard let config = panel.terminalConfig else { return nil }
        teardownTerminalController(panelId: panel.id)
        // Inject the space-posting behaviour so the controller's gate/dedup logic stays
        // decoupled from AppState (and unit-testable).
        let post: (String) -> Void = { [weak self] content in
            guard let self else { return }
            // The companion replied → clear its "typing…" indicator (and cancel the safety
            // timeout). Native terminal companions are skipped by launchAgents (which is what
            // clears typing for LLM/command agents), so without this the indicator hangs forever.
            self.clearTerminalTyping(name: config.companionName, spaceId: config.spaceId)
            if let companion = self.companions.first(where: { $0.displayName == config.companionName }) {
                self.sendMessageAsCompanion(companion, content: content, spaceId: config.spaceId)
            } else {
                self.sendMessageAsNamedAgent(content: content, senderName: config.companionName, toSpaceId: config.spaceId)
            }
        }
        // Drain any messages queued while this terminal was (re)spawning, keyed by companion name.
        let drainKey = config.companionName.lowercased()
        let drainPending: () -> [String] = { [weak self] in
            guard let self else { return [] }
            let lines = self.pendingTerminalInjections[drainKey] ?? []
            self.pendingTerminalInjections[drainKey] = nil
            return lines
        }
        let controller = GhosttyTerminalController(panelId: panel.id, config: config, post: post, drainPending: drainPending)
        terminalControllers[panel.id] = controller
        return controller
    }

    /// Tear down and drop a native terminal controller (window closed/minimized).
    func teardownTerminalController(panelId: String) {
        terminalControllers.removeValue(forKey: panelId)?.teardown()
    }

    /// Pure resolver from an id-or-name to a terminal controller's port id. Split out so it can
    /// be unit-tested without constructing a real controller (which needs a live Ghostty surface).
    /// Resolution order: (1) exact id hit wins even when a name also matches; (2a) exact name
    /// match; (2b) substring name match; (3) not found.
    nonisolated static func resolveTerminalId(_ idOrName: String,
                                              candidates: [(id: String, name: String)]) -> String? {
        if candidates.contains(where: { $0.id == idOrName }) { return idOrName }          // 1. id-hit
        let q = idOrName.lowercased()
        if let m = candidates.first(where: { $0.name.lowercased() == q }) { return m.id }  // 2a. exact name
        if let m = candidates.first(where: { $0.name.lowercased().contains(q) }) { return m.id } // 2b. contains
        return nil                                                                          // 3. not-found
    }

    /// Resolve a native terminal controller by port id or terminal name (companion name / title).
    /// One scan over `terminalControllers` covers both companion @mention routing and plain
    /// titled terminals, because `spawnNativeTerminalPort` sets `companionName: title` for
    /// non-companion spawns.
    func resolveTerminalController(idOrName: String) -> GhosttyTerminalController? {
        let cands = terminalControllers.map { (id: $0.key, name: $0.value.config.companionName) }
        return AppState.resolveTerminalId(idOrName, candidates: cands).flatMap { terminalControllers[$0] }
    }

    /// Create a native Ghostty `terminal` port and return its **port id** (UDID).
    ///
    /// This is the generic spawn used by every native-terminal caller (companion spawns,
    /// `port.create({type:"terminal"})`, RPC). It owns the shared work: resolving the startup shell line,
    /// building the `TerminalPortConfig`, and popping out a floating native window. Caller-specific
    /// concerns (companion identity prompt, join announcements) stay with the caller.
    ///
    /// Returns the port id on success (== `terminalControllers` key, since `popOut` →
    /// `createWindow` → `makeTerminalController` keys on the same `panel.id`), or `nil` if the
    /// config failed to encode.
    /// Bake the companion prompt a native terminal CLI is launched with: the Port42 operational
    /// framing (ALWAYS, under the hood) wrapped around an optional RAW user systemPrompt
    /// (personality/role) APPENDED on top — not either/or. The framing gives the companion what it
    /// needs to function in the space loop; the user prompt customizes it. {{NAME}}/{{SPACE}} in the
    /// user prompt are substituted here; empty user prompt = framing only.
    ///
    /// Injected into the CLI via the shim's --append-system-prompt (env PORT42_COMPANION_PROMPT),
    /// NOT a CLAUDE.md file (which clobbered project files and, with the workingDir bug, polluted
    /// the global ~/CLAUDE.md). No <p42> instruction: a hooks companion replies conversationally and
    /// turnComplete delivers it. NOTE: companions also see the global Port42 RPC API reference
    /// (~/.claude/CLAUDE.md), so they may try to `curl` send_message to post — that double-delivers
    /// (API + turnComplete), so the framing explicitly steers replies through the automatic path.
    ///
    /// Centralized so the saved-companion path (spawnTerminalAgentPort) and the ad-hoc
    /// port.create({type:"terminal"}) path bake an identical prompt from a raw input.
    func bakeCompanionPrompt(name: String, spaceId: String, systemPrompt: String?) -> String {
        let spaceName = spaces.first(where: { $0.id == spaceId })?.name ?? spaceId
        let framing = "You are \(name), a space companion in Port42 connected to #\(spaceName). Respond to space messages directly and conversationally. Messages arrive prefixed with [@name]: — this prefix only tells you who sent the message; never copy it into your reply, just write your reply text. REPLYING: to reply to a message addressed to you, just write your response normally — it is delivered to the space automatically. Do NOT also post that reply via the API, or it will appear twice. POSTING ON YOUR OWN INITIATIVE: to send a NEW message to the space when you are NOT replying (e.g. to share an update or raise something proactively), post it explicitly with curl: curl -s http://127.0.0.1:4242/call -d '{\"method\":\"messages.send\",\"args\":{\"text\":\"your message\",\"senderName\":\"\(name)\",\"space_id\":\"\(spaceId)\"}}' — only for self-initiated messages, never to deliver a reply. Keep responses concise."
        let userPrompt = (systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            .replacingOccurrences(of: "{{NAME}}", with: name)
            .replacingOccurrences(of: "{{SPACE}}", with: spaceName)
        return userPrompt.isEmpty ? framing : "\(framing)\n\n\(userPrompt)"
    }

    @discardableResult
    func spawnNativeTerminalPort(command: String, args: [String] = [], cwd: String,
                                 spaceId: String, title: String, companionName: String,
                                 systemPrompt: String? = nil, env: [String: String] = [:],
                                 recordKey: String? = nil, postCard: Bool = true,
                                 startupCommandOverride: String? = nil) -> String? {
        // Shell line typed into the interactive shell once ready: command + quoted args.
        // (Ghostty runs /bin/zsh so the hooks shim's ZDOTDIR `claude` function applies;
        // the command is typed in, since Ghostty's `command` can't carry args — gap #8.)
        let quotedArgs = args.map { arg -> String in
            guard arg.contains(" ") || arg.contains("'") else { return arg }
            return "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
        // For hooks-capable CLIs (claude/gemini) type the BARE name so the shim shell-function
        // (`claude() { … }`, injected via ZDOTDIR) intercepts it. A full path bypasses the
        // function entirely → no --settings → no hooks → nothing posts. Other tools run as given.
        let cmdName = (command as NSString).lastPathComponent
        let launchCmd = GhosttyTerminalController.isHooksCapable(cmdName) ? cmdName : command
        // A plain terminal (dock button) passes "" so it just drops into the interactive shell with
        // nothing typed; companions pass nil and get their command auto-typed.
        let startupCommand = startupCommandOverride ?? (quotedArgs.isEmpty ? launchCmd : "\(launchCmd) \(quotedArgs)")

        let spaceName = spaces.first(where: { $0.id == spaceId })?.name ?? spaceId
        // Bake the Port42 framing around the RAW systemPrompt here (centralized in
        // bakeCompanionPrompt) so the saved-companion path and the ad-hoc port.create path
        // produce an identical companion prompt. The spawn record stores the raw systemPrompt,
        // not this baked result, so a respawn re-bakes once rather than double-wrapping.
        let companionPrompt = bakeCompanionPrompt(name: companionName, spaceId: spaceId, systemPrompt: systemPrompt)
        let config = TerminalPortConfig(
            command: "/bin/zsh",
            args: [],
            startupCommand: startupCommand,
            cwd: cwd,
            spaceId: spaceId,
            spaceName: spaceName,
            companionName: companionName,
            createdBy: currentUser?.id ?? "",
            companionPrompt: companionPrompt,
            env: env
        )
        guard let json = try? String(decoding: JSONEncoder().encode(config), as: UTF8.self) else {
            NSLog("[Port42] Failed to encode TerminalPortConfig for '%@'", title)
            return nil
        }

        // A terminal is a port; a port is a tile: spawn it as a TILED terminal (a hoisted
        // Ghostty surface hosted by its unit, like any tile).
        let portId = portWindows.addTiledTerminalPanel(configJSON: json, spaceId: spaceId,
                                                       createdBy: companionName, title: title)
        if let panel = portWindows.panels.first(where: { $0.id == portId }),
           let controller = makeTerminalController(for: panel) {
            let built = GhosttyTerminalView.makeDetached(
                config: config, env: controller.env,
                onTee: { controller.receiveTee($0) },
                onInject: { controller.bindSurface($0) })
            portWindows.storeTerminalView(id: portId, view: built.view, coordinator: built.coordinator)
        }
        NSLog("[Port42] Spawned native terminal port '%@' (id=%@)", title, portId)

        // Step 5b: record params so the card's play can respawn after a close, and track the
        // currently-live port id under the stable card key (`recordKey` on respawn, else portId).
        let key = recordKey ?? portId
        terminalSpawnRecords[key] = TerminalSpawnRecord(
            command: command, args: args, cwd: cwd, spaceId: spaceId, title: title,
            companionName: companionName, systemPrompt: systemPrompt, env: env)
        terminalLiveIds[key] = portId

        // (No chat card: the tiled terminal IS the presence on the desktop. `postCard` is
        // accepted for API compatibility but there is no classic window to anchor a card to.)
        _ = postCard

        return portId
    }

    /// The uniform port-creation primitive behind both `port.create` (JS bridge) and `port_create`
    /// (tool). Validates the request, then dispatches by type. Returns `["id":…, "title":…]` on
    /// success or `["error":…]` on failure (no half-success).
    ///
    /// `inline` carries the caller-context routing for WEB ports (decided w/ gordon 2026-06-29):
    /// an in-chat companion composing a reply passes `true` → the port renders inline in the space;
    /// an external caller (a web port's own JS, a gateway/CLI call) passes `false` → it opens as a
    /// floating window. Terminals ignore `inline` — they're always a native window + card.
    @discardableResult
    /// SHELL — S2.2: `presentation` replaces the old (dead) `inline: Bool` routing flag
    /// (`spec-shell-reimplementation.md` open-decision #2). "inline" — a web port renders inline
    /// in chat; "tiled" registers it as a desktop tile at `position` (arrange picks the spot when
    /// nil). Terminals are unaffected (always a native window / shell tile).
    ///
    /// PHASE 1 (port-units): when the caller doesn't say (nil), the default is **tiled** —
    /// the shell's surface IS the desktop; the old inline default made every remote/companion
    /// `port.create` a chat-fence message that never reached the desktop or the peek path.
    /// An explicit "inline" is still honored. Returns {id, title} or {error}.
    func createPort(type: String?, title: String?, html: String?,
                    command: String?, args: [String] = [], cwd: String?,
                    systemPrompt: String?, env: [String: String] = [:],
                    spaceId: String, createdBy: String?, createdByName: String?,
                    presentation: String? = nil, position: CGPoint? = nil,
                    size: CGSize? = nil) -> [String: Any] {
        let presentation = presentation ?? "tiled"
        switch PortCreateValidation.validate(type: type, html: html, command: command) {
        case .error(let message):
            return ["error": message]

        case .ok(.terminal(let command)):
            let resolvedTitle = (title?.isEmpty == false ? title! : (command as NSString).lastPathComponent)
            let resolvedCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            guard let portId = spawnNativeTerminalPort(
                command: command, args: args, cwd: resolvedCwd, spaceId: spaceId,
                title: resolvedTitle, companionName: resolvedTitle,
                systemPrompt: systemPrompt, env: env) else {
                return ["error": "failed to spawn terminal port"]
            }
            return ["id": portId, "title": resolvedTitle]

        case .ok(.web(let html)):
            let resolvedTitle = (title?.isEmpty == false ? title! : PortPanel.extractTitle(from: html))
            // SHELL — S2.2: a tiled web port is a desktop tile (registry-owned webview composited on
            // the shell desktop), not a chat message. arrange() picks the spot when position is nil.
            if presentation == "tiled" {
                let id = UUID().uuidString
                _ = portWindows.registerTiledPort(id: id, html: html, spaceId: spaceId,
                                                  createdBy: createdBy, title: resolvedTitle,
                                                  position: position, size: size)
                return ["id": id, "title": resolvedTitle]
            }
            // Otherwise a web port renders INLINE in chat and AUTO-PLAYS on creation. The inline
            // view's titlebar carries play / stop / source / pop-out; pop-out re-parents to a
            // floating window (Step 8) with no reload.
            let id = postInlineWebPort(html: html, title: resolvedTitle, spaceId: spaceId,
                                       createdBy: createdBy, createdByName: createdByName)
            pendingPortActivationId = id   // activate immediately → it plays inline, not a collapsed card
            return ["id": id, "title": resolvedTitle]
        }
    }

    /// The inline `[port:id]` card's play action (Step 8): focus the live floating window, restore
    /// it if backgrounded. Mirror of `openTerminalPort` for web ports. (A web port's HTML lives in
    /// the persisted panel, so after restart the restored panel is brought to front.)
    func openWebPort(id: String) {
        guard let panel = portWindows.panels.first(where: { $0.id == id || $0.udid == id }) else {
            NSLog("[Port42] openWebPort: no panel for %@", id)
            return
        }
        if panel.isBackground {
            portWindows.restore(panel.id)
        } else {
            portWindows.bringToFront(panel.id)
        }
    }

    /// Post an inline web port into the space: a `` ```port `` fenced message the chat renders as a
    /// live inline port (its bridge registers when the view appears, keyed by this message id — the
    /// same id `inlinePorts()` reports). Synced like a normal companion message so peers see it.
    /// Returns the message id, which is the inline port's id.
    func postInlineWebPort(html: String, title: String, spaceId: String,
                           createdBy: String?, createdByName: String?) -> String {
        let id = UUID().uuidString
        let name = createdByName ?? createdBy ?? currentUser?.displayName ?? "port42"
        let msg = Message(
            id: id, spaceId: spaceId,
            senderId: createdBy ?? currentUser?.id ?? "",
            senderName: name, senderType: "agent",
            content: "```port\n\(html)\n```",
            timestamp: Date(), replyToId: nil, syncStatus: "sent", createdAt: Date()
        )
        try? db.saveMessage(msg)
        sync.sendMessage(msg)
        return id
    }

    /// The inline terminal card's play action (Step 5b): focus the live window, restore it if
    /// backgrounded, or respawn it (same command/cwd/space) if it was closed.
    func openTerminalPort(id: String) {
        let liveId = terminalLiveIds[id] ?? id
        if let panel = portWindows.panels.first(where: { $0.id == liveId }) {
            if panel.isBackground { portWindows.restore(liveId) } else { portWindows.bringToFront(liveId) }
            return
        }
        // Window was closed → respawn from the recorded params, keeping the same card key.
        if let rec = terminalSpawnRecords[id] {
            _ = spawnNativeTerminalPort(
                command: rec.command, args: rec.args, cwd: rec.cwd, spaceId: rec.spaceId,
                title: rec.title, companionName: rec.companionName, systemPrompt: rec.systemPrompt,
                env: rec.env, recordKey: id, postCard: false)
            return
        }
        // Fallback (e.g. after app restart): restore the persisted panel under its original id.
        guard let panel = portWindows.panels.first(where: { $0.id == id }) else {
            NSLog("[Port42] openTerminalPort: no live window or spawn record for %@", id)
            return
        }
        if panel.isBackground {
            portWindows.restore(id)
        } else {
            portWindows.bringToFront(id)
        }
    }

    /// Pop a terminal port running a CLI agent and bridge it to the given space.
    private func spawnTerminalAgentPort(companion: AgentConfig, command: String, spaceId: String) {
        let name = companion.displayName
        let args = companion.args ?? []
        let cwd = companion.workingDir ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Companion identity is baked by spawnNativeTerminalPort (bakeCompanionPrompt): the
        // Port42 operational framing wrapped around this companion's RAW systemPrompt template.
        guard spawnNativeTerminalPort(command: command, args: args, cwd: cwd,
                                      spaceId: spaceId, title: name,
                                      companionName: name, systemPrompt: companion.systemPrompt) != nil else {
            return
        }

        // Post a plain-text join announcement so the space records the companion's arrival.
        if !spaceId.isEmpty {
            let now = Date()
            let joinMsg = Message(
                id: UUID().uuidString,
                spaceId: spaceId,
                senderId: "cli-agent-\(name.lowercased())",
                senderName: name,
                senderType: "system",
                content: "\(name) joined the space",
                timestamp: now,
                replyToId: nil,
                syncStatus: "sent",
                createdAt: now
            )
            try? db.saveMessage(joinMsg)
            sync.sendMessage(joinMsg)
        }
    }

    public func addCompanionToSpace(_ companion: AgentConfig, space: Space) {
        do {
            try db.assignAgentToSpace(agentId: companion.id, spaceId: space.id)
            if currentSpace?.id == space.id {
                spaceCompanions = try db.getAgentsForSpace(spaceId: space.id)
            }
            Analytics.shared.companionAddedToSpace()
        } catch {
            print("[Port42] Failed to add companion to space: \(error)")
        }
        if companion.openInTerminal {
            // Idempotent: routeMentionsToTerminals may have already spawned the port for the
            // triggering @mention (it runs before this). ensureTerminalLive no-ops if a panel
            // or controller already exists, so we never double-spawn.
            ensureTerminalLive(companion: companion, spaceId: space.id)
        }
    }

    public func removeCompanionFromSpace(_ companion: AgentConfig, space: Space) {
        do {
            try db.removeAgentFromSpace(agentId: companion.id, spaceId: space.id)
            if currentSpace?.id == space.id {
                spaceCompanions = try db.getAgentsForSpace(spaceId: space.id)
            }
        } catch {
            print("[Port42] Failed to remove companion from space: \(error)")
        }
    }

    public func updateCompanion(_ companion: AgentConfig) {
        do {
            try db.saveAgent(companion)
            companions = try db.getAllAgents()
            // Refresh the current space's crew too, so a rename/edit reflects on its dock chip.
            if let sid = currentSpace?.id { spaceCompanions = try db.getAgentsForSpace(spaceId: sid) }
        } catch {
            print("[Port42] Failed to update companion: \(error)")
        }
    }

    public func deleteCompanion(_ companion: AgentConfig) {
        // Capture before the delete wipes membership: are we currently viewing this
        // companion's DM (a direct space whose companion is the one being deleted)?
        let wasViewingThisDM = currentSpace?.type == "direct"
            && spaceCompanions.contains { $0.id == companion.id }
        // Close any port panels spawned by this companion so they don't persist and re-restore
        let panelsToClose = portWindows.panels.filter { $0.createdBy == companion.displayName }
        for panel in panelsToClose {
            portWindows.close(panel.id)
        }
        do {
            try db.removeAllSpacesForAgent(companion.id)
            try db.deleteCreasesForCompanion(companion.id)
            try db.deleteEngravingsForCompanion(companion.id)
            try db.deleteFoldsForCompanion(companion.id)
            try db.deletePositionsForCompanion(companion.id)
            try db.deleteAgent(id: companion.id)
            companions = try db.getAllAgents()
            if wasViewingThisDM {
                currentSpace = nil
                spaceCompanions = []
            }
        } catch {
            print("[Port42] Failed to delete companion: \(error)")
        }
    }

    // MARK: - Friends (remote humans)

    public func refreshFriends() {
        guard let userId = currentUser?.id else { return }
        friends = (try? db.getKnownFriends(excludingUserId: userId)) ?? []
    }

    /// Open or create a DM space with a remote friend, then select it.
    public func startDM(with friend: SpaceMember) {
        let dmId = "dm-\(friend.senderId)"
        // Check if DM space already exists
        if let existing = spaces.first(where: { $0.id == dmId }) {
            selectSpace(existing)
            return
        }
        // Create a new DM space
        let space = Space(
            id: dmId,
            name: friend.name,
            type: "dm",
            createdAt: Date(),
            encryptionKey: SpaceCrypto.generateKey()
        )
        do {
            try db.saveSpace(space)
            spaces = try db.getRegularSpaces()
            selectSpace(space)
            syncJoinSpace(space.id)
        } catch {
            print("[Port42] Failed to create DM space: \(error)")
        }
    }

    public func startSwim(with companion: AgentConfig) {
        UserDefaults.standard.set(companion.id, forKey: "lastActiveSwimCompanionId")
        UserDefaults.standard.removeObject(forKey: "lastSelectedSpaceId")

        // Resolve/create the companion's direct space via membership (no more `swim-<id>` ids).
        guard let directSpace = try? db.getOrCreateDirectSpace(companion: companion) else {
            print("[Port42] Failed to open direct space for \(companion.displayName)")
            return
        }
        spaces = (try? db.getRegularSpaces()) ?? spaces
        // Set synchronously so the sidebar DM row highlights immediately; selectSpace's
        // observation refreshes spaceCompanions from the DB shortly after.
        spaceCompanions = [companion]
        selectSpace(directSpace)

        Analytics.shared.swimStarted()
        Analytics.shared.screen("Swim")
    }

    // MARK: - Lock / Reset

    public func lockApp() {
        cancelStreaming(spaceId: currentSpace?.id ?? "")
        showDreamscape = true          // the lock screen covers the shell; tiles stay mounted
    }

    /// Power off: keep data but require bootloader (name entry) on next launch.
    public func powerOff() {
        cancelStreaming(spaceId: currentSpace?.id ?? "")
        currentUser = nil
        isSetupComplete = false
        showDreamscape = true
    }

    public func unlock() {
        showDreamscape = false
        Analytics.shared.appOpened()
        // Restore last view if already set up
        if isSetupComplete {
            // If a swim was active, restore it
            let lastSwimId = UserDefaults.standard.string(forKey: "lastActiveSwimCompanionId")
            if let lastSwimId, let companion = companions.first(where: { $0.id == lastSwimId }) {
                startSwim(with: companion)
            } else if let space = currentSpace {
                selectSpace(space)
            } else if let first = spaces.first {
                selectSpace(first)
            }
        }
    }

    public func resetApp() {
        currentSpace = nil
        currentUser = nil
        spaces = []
        messages = []
        companions = []
        spaceCompanions = []
        friends = []
        drafts = [:]
        unreadCounts = [:]
        lastReadDates = [:]
        spaceAgentIds = [:]
        spaceSenderCounts = [:]
        isSetupComplete = false
        showDreamscape = true

        spaceObservation?.cancel()
        messageObservation?.cancel()
        unreadObservation?.cancel()
        agentSpacesObservation?.cancel()
        senderCountsObservation?.cancel()

        // Clear stored auth so boot flow starts fresh
        Port42AuthStore.shared.clearAll()
        AgentAuthResolver.shared.resetAuth()
        authStatus = .unknown

        do {
            try db.resetAll()
        } catch {
            print("[Port42] Reset failed: \(error)")
        }
    }

    // MARK: - Draft

    public func currentDraft() -> String {
        guard let space = currentSpace else { return "" }
        return drafts[space.id] ?? ""
    }

    public func saveDraft(_ text: String) {
        guard let space = currentSpace else { return }
        drafts[space.id] = text
    }

    // MARK: - Observations

    private func startSpaceObservation() {
        spaceObservation = db.observeSpaces { [weak self] spaces in
            Task { @MainActor in
                self?.spaces = spaces
            }
        }
        agentSpacesObservation = db.observeAgentSpaces { [weak self] map in
            Task { @MainActor in
                self?.spaceAgentIds = map
            }
        }
        senderCountsObservation = db.observeSenderCounts { [weak self] counts in
            Task { @MainActor in
                self?.spaceSenderCounts = counts
            }
        }
    }

    private func startMessageObservation(spaceId: String) {
        messageObservation?.cancel()
        messageObservation = db.observeMessages(spaceId: spaceId, topic: "chat") { [weak self] dbMessages in
            Task { @MainActor in
                guard let self else { return }
                // Preserve in-memory streaming content for active agent handlers
                let activeIds = Set(self.activeAgentHandlers.keys)
                if activeIds.isEmpty {
                    self.messages = dbMessages
                } else {
                    // Merge: use DB messages but keep in-memory content for active streams
                    var merged = dbMessages
                    for id in activeIds {
                        if let memIdx = self.messages.firstIndex(where: { $0.id == id }),
                           let dbIdx = merged.firstIndex(where: { $0.id == id }) {
                            // Keep the in-memory version (has streaming tokens)
                            merged[dbIdx] = self.messages[memIdx]
                        }
                    }
                    self.messages = merged
                }
                // Update cached activity time for this space
                if let last = dbMessages.last(where: { $0.senderType != "system" }) {
                    self.lastActivityTimes[spaceId] = last.timestamp
                }
            }
        }
    }

    // MARK: - SHELL multi-space chat (B)
    //
    // The shell surfaces several chat tiles at once — the current space's chat plus any open DMs —
    // each a live conversation in its OWN space. The current space streams through `messages`; every
    // other surfaced space streams through `messagesBySpace`, one observation apiece. `messages(for:)`
    // gives views a single read that works regardless of which bucket a space lives in.

    /// Live read for a space's chat, current or backgrounded. Views pass their own `spaceId`.
    public func messages(for spaceId: String?) -> [Message] {
        guard let sid = spaceId else { return [] }
        if sid == currentSpace?.id { return messages }
        return messagesBySpace[sid] ?? []
    }

    /// The companions in a given space, current or not (reactive via `spaceAgentIds` + `companions`).
    public func companions(forSpace spaceId: String?) -> [AgentConfig] {
        guard let sid = spaceId else { return [] }
        if sid == currentSpace?.id { return spaceCompanions }
        let ids = spaceAgentIds[sid] ?? []
        return companions.filter { ids.contains($0.id) }
    }

    /// Overlay in-flight streaming tokens (held on the active handler) onto DB rows for a space.
    private func overlayStreaming(_ dbMessages: [Message], spaceId: String) -> [Message] {
        guard !activeAgentHandlers.isEmpty else { return dbMessages }
        var merged = dbMessages
        for handler in activeAgentHandlers.values where handler.spaceId == spaceId {
            if let idx = merged.firstIndex(where: { $0.id == handler.messageId }) {
                merged[idx].content = handler.bufferedContent
            }
        }
        return merged
    }

    /// Begin observing a NON-current space's chat into `messagesBySpace` (idempotent).
    public func activateSpaceMessages(spaceId: String) {
        guard spaceId != currentSpace?.id, extraMessageObservations[spaceId] == nil else { return }
        messagesBySpace[spaceId] = overlayStreaming((try? db.getMessages(spaceId: spaceId, topic: "chat")) ?? [], spaceId: spaceId)
        extraMessageObservations[spaceId] = db.observeMessages(spaceId: spaceId, topic: "chat") { [weak self] dbMessages in
            Task { @MainActor in
                guard let self else { return }
                self.messagesBySpace[spaceId] = self.overlayStreaming(dbMessages, spaceId: spaceId)
                if let last = dbMessages.last(where: { $0.senderType != "system" }) {
                    self.lastActivityTimes[spaceId] = last.timestamp
                }
            }
        }
    }

    /// Stop observing a backgrounded space and drop its cache (call when a DM tile closes).
    public func deactivateSpaceMessages(spaceId: String) {
        extraMessageObservations[spaceId]?.cancel()
        extraMessageObservations.removeValue(forKey: spaceId)
        messagesBySpace.removeValue(forKey: spaceId)
    }

    /// Resolve/create a companion's DM space and start streaming it — WITHOUT switching the current
    /// space. Returns the direct space so the shell can surface its chat port as a tile. Unlike
    /// `startSwim`, this leaves `currentSpace` (and its chat tile) exactly where it is.
    @discardableResult
    public func openDMSpace(with companion: AgentConfig) -> Space? {
        guard let directSpace = try? db.getOrCreateDirectSpace(companion: companion) else {
            print("[Port42] Failed to open DM space for \(companion.displayName)")
            return nil
        }
        spaces = (try? db.getRegularSpaces()) ?? spaces
        activateSpaceMessages(spaceId: directSpace.id)
        return directSpace
    }

    /// Refresh cached last-activity times for all spaces and companion swim spaces.
    private func refreshActivityTimes() {
        let allSpaces = try? db.getAllSpaces()
        let allCompanions = companions
        Task { @MainActor in
            var times: [String: Date] = self.lastActivityTimes
            for space in allSpaces ?? [] {
                if let t = try? self.db.getLastMessageTime(spaceId: space.id) {
                    times[space.id] = t
                }
            }
            for companion in allCompanions {
                if let dmId = (try? self.db.directSpaceId(companionId: companion.id)) ?? nil,
                   let t = try? self.db.getLastMessageTime(spaceId: dmId) {
                    times[dmId] = t
                }
            }
            self.lastActivityTimes = times
        }
    }

    private func startUnreadObservation() {
        unreadObservation?.cancel()
        unreadObservation = db.observeUnreadCounts(
            excludingSpaceId: currentSpace?.id,
            since: lastReadDates
        ) { [weak self] counts in
            Task { @MainActor in
                self?.unreadCounts = counts
            }
        }
    }
}

