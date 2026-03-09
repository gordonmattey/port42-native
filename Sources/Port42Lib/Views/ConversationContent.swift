import SwiftUI

// MARK: - Unified chat renderer for both channels and swims

/// A single message entry that both channel Messages and SwimMessages can map to.
public struct ChatEntry: Identifiable, Equatable {
    public let id: String
    public let senderName: String
    public let senderOwner: String?
    public let content: String
    public let timestamp: Date?
    public let isSystem: Bool
    public let isAgent: Bool
    public let isPlaceholder: Bool
    public let syncStatus: String?
    public let isOwnMessage: Bool

    public init(
        id: String, senderName: String, content: String, timestamp: Date? = nil,
        isSystem: Bool = false, isAgent: Bool = false, isPlaceholder: Bool = false,
        senderOwner: String? = nil, syncStatus: String? = nil, isOwnMessage: Bool = false
    ) {
        self.id = id
        self.senderName = senderName
        self.senderOwner = senderOwner
        self.content = content
        self.timestamp = timestamp
        self.isSystem = isSystem
        self.isAgent = isAgent
        self.isPlaceholder = isPlaceholder
        self.syncStatus = syncStatus
        self.isOwnMessage = isOwnMessage
    }

    /// Full namespaced identity
    public var qualifiedName: String {
        if let owner = senderOwner {
            return "\(senderName)@\(owner)"
        }
        return senderName
    }

    /// Display name for UI. Strips namespace for local entities.
    public func displayName(localOwner: String? = nil) -> String {
        if let owner = senderOwner, owner.lowercased() != localOwner?.lowercased(),
           owner.lowercased() != senderName.lowercased() {
            return "\(senderName)@\(owner)"
        }
        return senderName
    }

    public var formattedTime: String? {
        guard let timestamp else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Autocomplete suggestion

public struct MentionSuggestion: Identifiable {
    public let id: String
    public let name: String
    public let isAgent: Bool

    public init(id: String, name: String, isAgent: Bool = true) {
        self.id = id
        self.name = name
        self.isAgent = isAgent
    }
}

// MARK: - Conversation Content View

public struct ConversationContent: View {
    let entries: [ChatEntry]
    let placeholder: String
    let isStreaming: Bool
    let error: String?
    let typingNames: [String]
    let mentionCandidates: [MentionSuggestion]
    let localOwner: String?
    let onSend: (String) -> Void
    let onStop: (() -> Void)?
    let onRetry: (() -> Void)?
    let onDismissError: (() -> Void)?
    let onTypingChanged: ((Bool) -> Void)?

    @State private var draft = ""
    @State private var selectedSuggestionIndex = 0
    @FocusState private var isInputFocused: Bool

    public init(
        entries: [ChatEntry],
        placeholder: String,
        isStreaming: Bool = false,
        error: String? = nil,
        typingNames: [String] = [],
        mentionCandidates: [MentionSuggestion] = [],
        localOwner: String? = nil,
        onSend: @escaping (String) -> Void,
        onStop: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onDismissError: (() -> Void)? = nil,
        onTypingChanged: ((Bool) -> Void)? = nil
    ) {
        self.entries = entries
        self.placeholder = placeholder
        self.isStreaming = isStreaming
        self.error = error
        self.typingNames = typingNames
        self.mentionCandidates = mentionCandidates
        self.localOwner = localOwner
        self.onSend = onSend
        self.onStop = onStop
        self.onRetry = onRetry
        self.onDismissError = onDismissError
        self.onTypingChanged = onTypingChanged
    }

    /// Compute active suggestions from internal draft and candidates
    private var suggestions: [MentionSuggestion] {
        guard let atRange = draft.range(of: "@", options: .backwards) else { return [] }
        let afterAt = String(draft[atRange.lowerBound...])
        if afterAt.contains(" ") { return [] }
        let query = String(afterAt.dropFirst()).lowercased()
        return mentionCandidates.filter { candidate in
            query.isEmpty || candidate.name.lowercased().hasPrefix(query)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            MessageRow(entry: entry, localOwner: localOwner)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)

                    if !typingNames.isEmpty {
                        TypingIndicator(names: typingNames)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: entries.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: entries.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: typingNames) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .background(Color.black.opacity(0.5))

            if let error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .font(Port42Theme.monoFontSmall)
                        .lineLimit(2)
                    Spacer()
                    if let onRetry {
                        Button("Retry") { onRetry() }
                            .font(Port42Theme.monoFontSmall)
                            .foregroundStyle(Port42Theme.accent)
                            .buttonStyle(.plain)
                    }
                    if let onDismissError {
                        Button("Dismiss") { onDismissError() }
                            .font(Port42Theme.monoFontSmall)
                            .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }

            // Autocomplete suggestions
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.id) { index, suggestion in
                        Button(action: { insertMention(suggestion) }) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(suggestion.isAgent ? Port42Theme.textAgent : Port42Theme.accent)
                                    .frame(width: 6, height: 6)
                                Text("@\(suggestion.name)")
                                    .font(Port42Theme.mono(13))
                                    .foregroundStyle(
                                        index == selectedSuggestionIndex
                                            ? Port42Theme.textPrimary
                                            : Port42Theme.textSecondary
                                    )
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                index == selectedSuggestionIndex
                                    ? Port42Theme.bgHover
                                    : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Port42Theme.bgSecondary)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(Port42Theme.border),
                    alignment: .top
                )
            }

            // Input bar
            HStack(spacing: 12) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !suggestions.isEmpty, selectedSuggestionIndex < suggestions.count {
                            insertMention(suggestions[selectedSuggestionIndex])
                        } else {
                            send()
                            isInputFocused = true
                        }
                    }
                    .disabled(isStreaming)
                    .onChange(of: draft) { _, _ in
                        selectedSuggestionIndex = 0
                    }
                    .onChange(of: isStreaming) { _, streaming in
                        if !streaming {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isInputFocused = true
                            }
                        }
                    }
                    .onKeyPress(.upArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        selectedSuggestionIndex = max(0, selectedSuggestionIndex - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        selectedSuggestionIndex = min(suggestions.count - 1, selectedSuggestionIndex + 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if !suggestions.isEmpty {
                            // Clear the @query to dismiss suggestions
                            if let atRange = draft.range(of: "@", options: .backwards) {
                                draft = String(draft[draft.startIndex..<atRange.lowerBound])
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.tab) {
                        guard !suggestions.isEmpty, selectedSuggestionIndex < suggestions.count else { return .ignored }
                        insertMention(suggestions[selectedSuggestionIndex])
                        return .handled
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "?")) { _ in
                        if draft.isEmpty {
                            NotificationCenter.default.post(name: .helpRequested, object: nil)
                            return .handled
                        }
                        return .ignored
                    }

                if isStreaming {
                    if let onStop {
                        Button(action: onStop) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Port42Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isInputFocused ? Port42Theme.accent.opacity(0.6) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .shadow(
                color: isInputFocused ? Port42Theme.accent.opacity(0.3) : .clear,
                radius: 8
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.3), value: isInputFocused)
            .onChange(of: draft) { old, new in
                let wasTyping = !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isTyping = !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if wasTyping != isTyping {
                    onTypingChanged?(isTyping)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isInputFocused = true
                }
            }
        }
    }

    private func send() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        onTypingChanged?(false)
        onSend(content)
        draft = ""
        isInputFocused = true
    }

    private func insertMention(_ suggestion: MentionSuggestion) {
        // Replace the @partial with @Name
        if let atRange = draft.range(of: "@", options: .backwards) {
            draft = String(draft[draft.startIndex..<atRange.lowerBound]) + "@\(suggestion.name) "
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

// MARK: - Message Row (Equatable for diff-only re-render)

struct MessageRow: View, Equatable {
    let entry: ChatEntry
    var localOwner: String? = nil

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.entry.id == rhs.entry.id &&
        lhs.entry.content == rhs.entry.content &&
        lhs.entry.isPlaceholder == rhs.entry.isPlaceholder &&
        lhs.entry.syncStatus == rhs.entry.syncStatus
    }

    var body: some View {
        messageContent
            .padding(.top, 8)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func receiptView(_ status: String) -> some View {
        let font = Port42Theme.mono(11)
        switch status {
        case "local":
            Text("·")
                .font(font)
                .foregroundColor(Port42Theme.textSecondary)
        case "synced":
            Text("✓✓")
                .font(font)
                .foregroundColor(Port42Theme.textSecondary)
        case "delivered":
            HStack(spacing: 0) {
                Text("✓")
                    .font(font)
                    .foregroundColor(Port42Theme.accent)
                Text("✓")
                    .font(font)
                    .foregroundColor(Port42Theme.textSecondary)
            }
        case "read":
            Text("✓✓")
                .font(font)
                .foregroundColor(Port42Theme.accent)
        default:
            EmptyView()
        }
    }

    private var messageContent: some View {
        Group {
            if entry.isSystem {
                Text(entry.content)
                    .font(Port42Theme.mono(12))
                    .foregroundColor(Port42Theme.textSecondary)
            } else {
                let agentColor = Port42Theme.agentColor(for: entry.senderName, owner: entry.senderOwner)
                let nameColor: Color = entry.isAgent ? agentColor : Port42Theme.textPrimary
                let contentColor: Color = entry.isAgent ? agentColor : Port42Theme.textPrimary

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(entry.displayName(localOwner: localOwner))
                            .font(Port42Theme.monoBold(13))
                            .foregroundColor(nameColor)
                        if let time = entry.formattedTime {
                            Text("  ")
                            Text(time)
                                .font(Port42Theme.mono(11))
                                .foregroundColor(Port42Theme.textSecondary)
                        }
                        if entry.isOwnMessage, let status = entry.syncStatus {
                            Text("  ")
                            receiptView(status)
                        }
                    }

                    if entry.isPlaceholder {
                        Text("...")
                            .font(Port42Theme.mono(13))
                            .foregroundColor(agentColor.opacity(0.5))
                    } else {
                        Text(entry.content)
                            .font(Port42Theme.mono(13))
                            .foregroundColor(contentColor)
                    }
                }
            }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    let names: [String]
    @State private var dotPhase = 0

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -3) {
                ForEach(names.prefix(3), id: \.self) { name in
                    Circle()
                        .fill(Port42Theme.agentColor(for: name))
                        .frame(width: 6, height: 6)
                }
            }

            Text(typingText)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)

            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Port42Theme.textSecondary.opacity(i <= dotPhase ? 1.0 : 0.3))
                        .frame(width: 4, height: 4)
                }
            }

            Spacer()
        }
        .onAppear { animateDots() }
    }

    private var typingText: String {
        let sorted = names.sorted()
        switch sorted.count {
        case 1: return "\(sorted[0]) is typing"
        case 2: return "\(sorted[0]) and \(sorted[1]) are typing"
        default: return "\(sorted[0]) and \(sorted.count - 1) others are typing"
        }
    }

    private func animateDots() {
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            dotPhase = (dotPhase + 1) % 3
        }
    }
}
