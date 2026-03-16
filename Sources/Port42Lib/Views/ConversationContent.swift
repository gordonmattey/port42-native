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

    /// Display name for UI. Shows owner namespace for remote entities,
    /// strips it for local ones (own messages and own companions).
    public func displayName(localOwner: String? = nil) -> String {
        if let owner = senderOwner,
           owner.lowercased() != senderName.lowercased() {
            // Strip namespace for local messages (our own companions)
            if syncStatus == "local" || syncStatus == nil {
                return senderName
            }
            return "\(senderName)@\(owner)"
        }
        return senderName
    }

    // MARK: - Port Detection

    /// Whether this message contains a ```port code fence (complete or truncated)
    public var containsPort: Bool {
        content.contains("```port")
    }

    /// Whether the port appears truncated (opening fence but no closing script tag or closing fence)
    public var isPortTruncated: Bool {
        guard content.contains("```port") else { return false }
        // Has opening fence but content looks incomplete
        if let html = portContent {
            // Check for signs of truncation: unclosed script, unclosed style, ends mid-tag
            let hasOpenScript = html.contains("<script") && !html.contains("</script>")
            let hasOpenStyle = html.contains("<style") && !html.contains("</style>")
            let endsInTag = html.hasSuffix(">") == false && html.last?.isWhitespace == false
            return hasOpenScript || hasOpenStyle || endsInTag
        }
        return portContent == nil
    }

    /// Extract the HTML content between ```port fences
    public var portContent: String? {
        guard let startRange = content.range(of: "```port") else { return nil }
        // Skip past the ```port tag and any trailing whitespace/newline
        var contentStart = startRange.upperBound
        if contentStart < content.endIndex {
            let afterTag = content[contentStart...]
            if let newline = afterTag.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                contentStart = content.index(after: newline)
            } else {
                contentStart = startRange.upperBound
            }
        }
        // Find closing ``` — if missing, treat rest of content as port HTML
        let endIndex: String.Index
        if let endRange = content.range(of: "```", range: contentStart..<content.endIndex) {
            endIndex = endRange.lowerBound
        } else {
            endIndex = content.endIndex
        }
        let html = String(content[contentStart..<endIndex])
        return html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : html
    }

    /// Text before the port fence (if any)
    public var textBeforePort: String? {
        guard let startRange = content.range(of: "```port") else { return nil }
        let before = String(content[content.startIndex..<startRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return before.isEmpty ? nil : before
    }

    /// Text after the port fence (if any)
    public var textAfterPort: String? {
        guard let startRange = content.range(of: "```port") else { return nil }
        var contentStart = startRange.upperBound
        if contentStart < content.endIndex {
            let afterTag = content[contentStart...]
            if let newline = afterTag.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                contentStart = content.index(after: newline)
            }
        }
        guard let endRange = content.range(of: "```", range: contentStart..<content.endIndex) else { return nil }
        let after = String(content[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? nil : after
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
    let toolingNames: [String]
    let mentionCandidates: [MentionSuggestion]
    let localOwner: String?
    let channelId: String?
    let onSend: (String) -> Void
    let onStop: (() -> Void)?
    let onRetry: (() -> Void)?
    let onDismissError: (() -> Void)?
    let onOpenSettings: (() -> Void)?
    let onTypingChanged: ((Bool) -> Void)?

    @EnvironmentObject var appState: AppState
    @State private var draft = ""
    @State private var selectedSuggestionIndex = 0
    @State private var historyIndex = -1  // -1 = not browsing history
    @State private var savedDraft = ""    // draft before entering history
    @FocusState private var isInputFocused: Bool
    @State private var isNearBottom = true
    @State private var unreadCount = 0
    @State private var unreadStartIndex = 0
    @State private var visibleEntryIDs: Set<String> = []
    @State private var scrollContentBottom: CGFloat = 0
    @State private var scrollVisibleBottom: CGFloat = 0
    @State private var cachedActivePortIDs: Set<String> = []
    @State private var lastEntryCount = 0

    public init(
        entries: [ChatEntry],
        placeholder: String,
        isStreaming: Bool = false,
        error: String? = nil,
        typingNames: [String] = [],
        toolingNames: [String] = [],
        mentionCandidates: [MentionSuggestion] = [],
        localOwner: String? = nil,
        channelId: String? = nil,
        onSend: @escaping (String) -> Void,
        onStop: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onDismissError: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onTypingChanged: ((Bool) -> Void)? = nil
    ) {
        self.entries = entries
        self.placeholder = placeholder
        self.isStreaming = isStreaming
        self.error = error
        self.typingNames = typingNames
        self.toolingNames = toolingNames
        self.mentionCandidates = mentionCandidates
        self.localOwner = localOwner
        self.channelId = channelId
        self.onSend = onSend
        self.onStop = onStop
        self.onRetry = onRetry
        self.onDismissError = onDismissError
        self.onOpenSettings = onOpenSettings
        self.onTypingChanged = onTypingChanged
    }

    /// IDs of the last 3 port-containing entries (only these render live)
    /// Cached to avoid scanning all entries on every body evaluation (keystroke)
    private func recomputeActivePortIDs() {
        let portEntries = entries.filter { $0.containsPort }
        let recent = portEntries.suffix(1)
        cachedActivePortIDs = Set(recent.map { $0.id })
        lastEntryCount = entries.count
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
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                MessageRow(entry: entry, localOwner: localOwner, portIsActive: cachedActivePortIDs.contains(entry.id))
                                    .id(entry.id)
                                    .onAppear {
                                        if index >= unreadStartIndex && unreadCount > 0 {
                                            let newCount = max(0, entries.count - 1 - index)
                                            if newCount < unreadCount {
                                                unreadCount = newCount
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)

                        if !typingNames.isEmpty || !toolingNames.isEmpty {
                            TypingIndicator(names: typingNames, toolingNames: toolingNames)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 4)
                        }

                        // Content bottom tracker (moves with scroll content)
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: geo.frame(in: .named("chatScrollOuter")).maxY
                            )
                        }
                        .frame(height: 1)
                        .id("bottom")
                    }
                    .defaultScrollAnchor(.bottom)
                    .onPreferenceChange(ScrollOffsetKey.self) { contentBottom in
                        guard abs(scrollContentBottom - contentBottom) > 2 else { return }
                        scrollContentBottom = contentBottom
                        updateNearBottom()
                    }
                    .onChange(of: entries.count) { old, new in
                        recomputeActivePortIDs()
                        let userSent = new > old && entries.last?.isAgent == false
                        if userSent || isNearBottom {
                            scrollToBottom(proxy: proxy)
                        } else {
                            if unreadCount == 0 {
                                unreadStartIndex = old
                            }
                            unreadCount += (new - old)
                        }
                    }
                    .onChange(of: entries.last?.content) { _, _ in
                        if isNearBottom {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    .onChange(of: typingNames) { _, _ in
                        if isNearBottom {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    .onAppear {
                        recomputeActivePortIDs()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }

                    // New messages bubble
                    if unreadCount > 0 {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                            unreadCount = 0
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("\(unreadCount) new")
                                    .font(Port42Theme.monoBold(12))
                            }
                            .foregroundColor(Port42Theme.bgPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Port42Theme.accent)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .coordinateSpace(name: "chatScrollOuter")
            .frame(minHeight: 0, maxHeight: .infinity)
            .background(
                GeometryReader { outerGeo in
                    Color.black.opacity(0.5)
                        .preference(
                            key: VisibleBottomKey.self,
                            value: outerGeo.size.height
                        )
                }
            )
            .onPreferenceChange(VisibleBottomKey.self) { visibleHeight in
                guard abs(scrollVisibleBottom - visibleHeight) > 2 else { return }
                scrollVisibleBottom = visibleHeight
                updateNearBottom()
            }

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
                    if let onOpenSettings {
                        Button("Settings") { onOpenSettings() }
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
                        if !suggestions.isEmpty {
                            selectedSuggestionIndex = max(0, selectedSuggestionIndex - 1)
                            return .handled
                        }
                        // Browse input history when draft is empty or already in history
                        guard let cid = channelId else { return .ignored }
                        let history = appState.inputHistory(for: cid)
                        guard !history.isEmpty else { return .ignored }
                        if historyIndex == -1 {
                            savedDraft = draft
                            historyIndex = 0
                        } else if historyIndex < history.count - 1 {
                            historyIndex += 1
                        } else {
                            return .handled
                        }
                        draft = history[historyIndex]
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if !suggestions.isEmpty {
                            selectedSuggestionIndex = min(suggestions.count - 1, selectedSuggestionIndex + 1)
                            return .handled
                        }
                        guard historyIndex >= 0 else { return .ignored }
                        historyIndex -= 1
                        if historyIndex < 0 {
                            draft = savedDraft
                        } else {
                            let history = appState.inputHistory(for: channelId ?? "")
                            draft = history[historyIndex]
                        }
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
        if let cid = channelId {
            appState.appendInputHistory(channelId: cid, content: content)
        }
        onSend(content)
        draft = ""
        historyIndex = -1
        savedDraft = ""
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
        unreadCount = 0
    }

    private func updateNearBottom() {
        // scrollContentBottom = content's maxY in the outer coordinate space
        // scrollVisibleBottom = visible container height
        // When scrolled to bottom, content maxY ≈ container height
        let wasNear = isNearBottom
        isNearBottom = (scrollContentBottom - scrollVisibleBottom) < 100
        if !wasNear && isNearBottom {
            unreadCount = 0
        }
    }
}

// MARK: - Scroll Position Tracking

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct VisibleBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Message Row (Equatable for diff-only re-render)

struct MessageRow: View, Equatable {
    let entry: ChatEntry
    var localOwner: String? = nil
    var portIsActive: Bool = false
    @EnvironmentObject var appState: AppState
    @State private var portActivatedManually = false

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.entry.id == rhs.entry.id &&
        lhs.entry.content == rhs.entry.content &&
        lhs.entry.isPlaceholder == rhs.entry.isPlaceholder &&
        lhs.entry.syncStatus == rhs.entry.syncStatus &&
        lhs.portIsActive == rhs.portIsActive
    }

    var body: some View {
        messageContent
            .padding(.top, 8)
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
                    .textSelection(.enabled)
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
                    } else if entry.containsPort, let portHTML = entry.portContent {
                        if let before = entry.textBeforePort {
                            Text(before)
                                .font(Port42Theme.mono(13))
                                .foregroundColor(contentColor)
                                .textSelection(.enabled)
                        }
                        if entry.isPortTruncated {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 11))
                                Text("port truncated (response cut off)")
                                    .font(Port42Theme.mono(11))
                            }
                            .foregroundColor(.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if portIsActive || portActivatedManually {
                            InlinePortView(html: portHTML, appState: appState, messageId: entry.id, createdBy: entry.senderName)
                        } else {
                            // Compact port block (icon + title + creator)
                            PortCompactBlock(
                                html: portHTML,
                                createdBy: entry.senderName,
                                onRun: { portActivatedManually = true },
                                onPopOut: {
                                    guard let window = NSApp.keyWindow else { return }
                                    let bounds = window.contentView?.bounds.size ?? CGSize(width: 800, height: 600)
                                    let bridge = PortBridge(appState: appState, channelId: appState.currentChannel?.id, messageId: entry.id, createdBy: entry.senderName)
                                    appState.portWindows.popOut(
                                        html: portHTML,
                                        bridge: bridge,
                                        channelId: appState.currentChannel?.id,
                                        createdBy: entry.senderName,
                                        messageId: entry.id,
                                        in: bounds
                                    )
                                }
                            )
                        }
                        if let after = entry.textAfterPort {
                            Text(after)
                                .font(Port42Theme.mono(13))
                                .foregroundColor(contentColor)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(entry.content)
                            .font(Port42Theme.mono(13))
                            .foregroundColor(contentColor)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onChange(of: portIsActive) { _, isActive in
            if !isActive { portActivatedManually = false }
        }
    }
}

// MARK: - Inline Port View (manages height state for PortView)

struct InlinePortView: View {
    let html: String
    let appState: AppState
    let messageId: String?
    let createdBy: String?
    @State private var height: CGFloat = 100
    @State private var showCode = false
    @State private var restartToken = UUID()
    @StateObject var bridge: PortBridge

    init(html: String, appState: AppState, messageId: String? = nil, createdBy: String? = nil) {
        self.html = html
        self.appState = appState
        self.messageId = messageId
        self.createdBy = createdBy
        _bridge = StateObject(wrappedValue: PortBridge(appState: appState, channelId: appState.currentChannel?.id, messageId: messageId, createdBy: createdBy))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar (matches docked/floating style)
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(Port42Theme.accent)
                Text(PortPanel.extractTitle(from: html))
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .lineLimit(1)
                if let creator = createdBy {
                    Text("·")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Text(creator)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()

                if showCode {
                    Button(action: { showCode = false }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Port42Theme.accent)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Run port")
                } else {
                    Button(action: { showCode = true }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop")

                    Button(action: restart) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Restart")

                    Button(action: { showCode = true }) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("View source")
                }

                Button(action: popOut) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Pop out")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Port42Theme.bgSecondary)
            .zIndex(1)

            if showCode {
                ScrollView(.vertical) {
                    Text(html)
                        .font(Port42Theme.mono(12))
                        .foregroundColor(Port42Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: max(height, 100))
            } else {
                PortView(html: html, bridge: bridge, height: $height)
                    .frame(height: max(height, 100))
                    .id(restartToken)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
        .onAppear {
            appState.registerPortBridge(bridge)
        }
        .onReceive(bridge.$pendingPermission) { perm in
            // Only route to ChatView dialog if this port isn't in a floating/docked panel
            // (panels handle their own permission dialog)
            if perm != nil && !appState.portWindows.panels.contains(where: { $0.bridge === bridge }) {
                appState.activePermissionBridge = bridge
            }
        }
    }

    private func restart() {
        restartToken = UUID()
    }

    private func popOut() {
        guard let window = NSApp.keyWindow else { return }
        let bounds = window.contentView?.bounds.size ?? CGSize(width: 800, height: 600)
        appState.portWindows.popOut(
            html: html,
            bridge: bridge,
            channelId: appState.currentChannel?.id,
            createdBy: createdBy,
            messageId: messageId,
            in: bounds
        )
    }
}

// MARK: - Port Compact Block

/// Collapsed port shown as a small block with icon, title, and creator name.
/// Click to expand inline or pop out to a floating window.
struct PortCompactBlock: View {
    let html: String
    let createdBy: String?
    let onRun: () -> Void
    let onPopOut: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image("port42-logo", bundle: Bundle.port42)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            Text(PortPanel.extractTitle(from: html))
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textPrimary)
                .lineLimit(1)

            if let creator = createdBy {
                Text(creator)
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Button(action: onRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.accent)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Run port")

                Button(action: onPopOut) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pop out")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Port42Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    let names: [String]
    let toolingNames: [String]
    @State private var dotPhase = 0

    init(names: [String], toolingNames: [String] = []) {
        self.names = names
        self.toolingNames = toolingNames
    }

    private var allNames: [String] {
        Array(Set(names + toolingNames)).sorted()
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -3) {
                ForEach(allNames.prefix(3), id: \.self) { name in
                    Circle()
                        .fill(Port42Theme.agentColor(for: name))
                        .frame(width: 6, height: 6)
                }
            }

            Text(statusText)
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

    private var statusText: String {
        // Names that are only tooling (not also typing)
        let pureTooling = Set(toolingNames).subtracting(Set(names))
        // Names that are only typing (not also tooling)
        let pureTyping = Set(names).subtracting(Set(toolingNames))

        if !pureTooling.isEmpty && pureTyping.isEmpty {
            // Only tooling
            let sorted = pureTooling.sorted()
            switch sorted.count {
            case 1: return "\(sorted[0]) is tooling up"
            case 2: return "\(sorted[0]) and \(sorted[1]) are tooling up"
            default: return "\(sorted[0]) and \(sorted.count - 1) others are tooling up"
            }
        } else if pureTooling.isEmpty && !pureTyping.isEmpty {
            // Only typing
            let sorted = pureTyping.sorted()
            switch sorted.count {
            case 1: return "\(sorted[0]) is typing"
            case 2: return "\(sorted[0]) and \(sorted[1]) are typing"
            default: return "\(sorted[0]) and \(sorted.count - 1) others are typing"
            }
        } else {
            // Both or overlapping
            let all = allNames
            switch all.count {
            case 1: return "\(all[0]) is tooling up"
            default: return "\(all.count) companions active"
            }
        }
    }

    private func animateDots() {
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            dotPhase = (dotPhase + 1) % 3
        }
    }
}
