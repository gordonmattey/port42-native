import SwiftUI

// MARK: - A port's chat, in its chrome (docs/design-chat-port.md, build step 2)
//
// The COMPANION BAR sits in the port's title bar: who is in the chat, as avatars, with the unread
// count. Clicking it slides the chat down from the bar. The panel PUSHES the port body down rather
// than covering it, because SwiftUI views laid over a hosted web or terminal view do not reliably
// win the click (see `PeekClickCatcher`), and a chat you cannot type into is worse than a port that
// gives up some height while the chat is open.

/// The bar: avatars of who has posted, the unread count, or a bubble when the chat is empty.
struct PortChatBar: View {
    @ObservedObject var chats: PortChatStore
    let key: String
    let me: String?
    let accent: Color
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let people = chats.participants(key).prefix(4)
        let unread = chats.unread(key, me: me)
        Button(action: toggle) {
            HStack(spacing: -4) {
                if people.isEmpty {
                    Image(systemName: open ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: 10)).foregroundStyle(open ? accent : Port42Theme.textSecondary)
                } else {
                    ForEach(Array(people), id: \.id) { p in
                        Circle().fill(ShellDock.avatarColor(p.id).gradient)
                            .frame(width: 14, height: 14)
                            .overlay(Text(String(p.name.prefix(1)).uppercased())
                                .font(Port42Theme.monoBold(8)).foregroundStyle(.black.opacity(0.75)))
                            .overlay(Circle().stroke(Port42Theme.shellCard, lineWidth: 1.5))
                    }
                }
                if unread > 0 {
                    Text("\(unread)")
                        .font(Port42Theme.monoBold(8)).foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(accent, in: Capsule())
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22).contentShape(Rectangle())
            .background(open ? Port42Theme.bgHover : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(open ? "Close chat" : "Chat")
    }
}

/// The chat itself: the transcript, and a line to post to it.
struct PortChatPanel: View {
    @ObservedObject var chats: PortChatStore
    @ObservedObject var appState: AppState
    let key: String
    let accent: Color

    @State private var draft = ""
    /// The time of the top message in view, shown while the transcript scrolls.
    @State private var scrollTime: Date?
    @State private var scrollTimeHide: DispatchWorkItem?
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        let list = chats.entries[key] ?? []
        VStack(spacing: 0) {
            // The transcript: yours on the right, others on the left, one selectable text
            // (ChatTranscript). While it scrolls, a pill shows the time of the top message in view.
            ZStack(alignment: .top) {
                if list.isEmpty {
                    Text("No messages yet. What you say here belongs to this port.")
                        .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                        .padding(.top, 14).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ChatTranscriptView(entries: list, me: appState.currentUser?.id, accent: accent) { date in
                        showScrollTime(date)
                    }
                }
                if let scrollTime {
                    Text(ChatTranscript.label(scrollTime))
                        .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Port42Theme.bgInput.opacity(0.92), in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.3), lineWidth: 1))
                        .padding(.top, 6)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: list.last?.seq) { _, _ in chats.markRead(key) }
            ChatPresenceStrip(presence: appState.presence, key: key, accent: accent)
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { name in
                        Button { draft = ChatRouting.complete(draft, with: name) } label: {
                            Text("@" + name)
                                .font(Port42Theme.mono(10)).foregroundStyle(accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Port42Theme.bgHover, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("tab").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                }
                .padding(.horizontal, 10).padding(.top, 4)
            }
            if let error {
                Text(error).font(Port42Theme.mono(9)).foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !unmatched.isEmpty {
                Text("no one here is called " + unmatched.map { "@" + $0 }.joined(separator: ", "))
                    .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 6) {
                // Wraps onto more lines as the message grows (GM, 2026-09-27); Return still sends.
                TextField("say something", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                    .focused($inputFocused)
                    .onSubmit(send)
                    // Tab completes the @name being typed to the first suggestion.
                    .onKeyPress(.tab) {
                        guard let first = suggestions.first else { return .ignored }
                        draft = ChatRouting.complete(draft, with: first)
                        return .handled
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 14))
                        .foregroundStyle(draft.isEmpty ? Port42Theme.textSecondary : accent)
                }
                .buttonStyle(.plain).disabled(draft.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Port42Theme.bgInput)
        }
        .background(Port42Theme.shellCard)
        .overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.35)).frame(height: 1).offset(y: 0.5) }
        .onAppear {
            chats.load(key, from: appState.db)
            chats.markRead(key)
            inputFocused = true
        }
    }

    /// Companions matching the @name being typed, up to five.
    /// Everyone who can be mentioned here: this instance's companions, then everyone who has posted in
    /// this chat (the other person in a shared port, and their companions).
    private var mentionable: [String] {
        ChatRouting.mentionable(companions: appState.companions.map(\.displayName),
                                entries: chats.entries[key] ?? [], me: appState.currentUser?.id)
    }

    /// Names matching the @name being typed, up to five.
    private var suggestions: [String] {
        guard let q = ChatRouting.mentionQuery(in: draft) else { return [] }
        return Array(ChatRouting.mentionSuggestions(query: q, names: mentionable).prefix(5))
    }

    /// Finished mentions in the draft that match no one here (the one being typed is not judged yet).
    private var unmatched: [String] {
        var text = draft
        if ChatRouting.mentionQuery(in: text) != nil, let at = text.lastIndex(of: "@") { text = String(text[..<at]) }
        return ChatRouting.unmatchedMentions(text, known: mentionable)
    }

    /// Show the scroll pill at `date`, and hide it a moment after scrolling stops.
    private func showScrollTime(_ date: Date) {
        if scrollTime != date { withAnimation(.easeOut(duration: 0.15)) { scrollTime = date } }
        scrollTimeHide?.cancel()
        let hide = DispatchWorkItem { withAnimation(.easeOut(duration: 0.4)) { scrollTime = nil } }
        scrollTimeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hide)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        error = nil
        Task {
            do { try await appState.submitChatInput(key: key, text: text) }
            catch let e as BridgeError { error = e.message; draft = text }
            catch { self.error = error.localizedDescription; draft = text }
        }
    }
}

/// SwiftUI content in its own AppKit view. A panel laid over a hosted web or terminal view must be a
/// real NSView above it to win the click and the scroll; plain SwiftUI drawn on top does not.
struct AppKitLayer<Content: View>: NSViewRepresentable {
    let content: Content
    func makeNSView(context: Context) -> NSHostingView<Content> { NSHostingView(rootView: content) }
    func updateNSView(_ view: NSHostingView<Content>, context: Context) { view.rootView = content }
}

/// A port's console in its chrome: what the page logged, newest at the bottom. It re-reads the
/// buffer twice a second while open, rather than redrawing on every line a port prints.
struct PortConsolePanel: View {
    let key: String
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let lines = PortConsole.shared.recent(portId: key, tail: 300)
            VStack(spacing: 0) {
                HStack {
                    Text("console").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    Button("clear") { PortConsole.shared.clear(portId: key) }
                        .buttonStyle(.plain).font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if lines.isEmpty {
                                Text("Nothing logged.").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                Text((l.level == "log" ? "" : l.level + ": ") + l.text)
                                    .font(Port42Theme.mono(10))
                                    .foregroundStyle(Self.color(l.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 6)
                    }
                    .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                    .onChange(of: lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .background(Port42Theme.bgPrimary)
            .overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.35)).frame(height: 1) }
        }
    }

    static func color(_ level: String) -> Color {
        switch level {
        case "error": return .red.opacity(0.9)
        case "warn": return .orange
        default: return Port42Theme.textSecondary
        }
    }
}

/// Under a chat's transcript: each agent on a message from this chat, and for how long (ChatPresence).
struct ChatPresenceStrip: View {
    @ObservedObject var presence: ChatPresenceStore
    let key: String
    let accent: Color

    var body: some View {
        let list = presence.entries(key)
        if !list.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list, id: \.name) { p in
                        HStack(spacing: 6) {
                            Circle().fill(Self.waiting(p) ? Color.orange : accent)
                                .frame(width: 5, height: 5)
                                .opacity(Self.waiting(p) ? 1 : 0.5 + 0.5 * abs(sin(ctx.date.timeIntervalSinceReferenceDate * 2)))
                            Text("@\(p.name) \(ChatPresenceStore.line(p, now: ctx.date))")
                                .font(Port42Theme.mono(10))
                                .foregroundStyle(Self.waiting(p) ? Color.orange : Port42Theme.textSecondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func waiting(_ p: ChatPresence) -> Bool {
        if case .waiting = p.state { return true }
        return false
    }
}

/// Where a chat is dragged to size it (GM, 2026-09-26, release hit list): invisible, like a port's
/// own resize zones. A port's chat drags by its bottom edge (height); the space chat by its
/// bottom-right corner (width and height), as a port does.
struct ChatResizeZone: View {
    enum Edge { case bottom, corner }
    let size: CGSize
    let edge: Edge
    let onResize: (CGSize) -> Void
    @State private var start: CGSize?

    var body: some View {
        Color.clear
            .frame(width: edge == .corner ? 16 : size.width, height: edge == .corner ? 16 : 6)
            .contentShape(Rectangle())
            .resizeCursor(ResizeCursor.cursor(for: edge == .corner ? .se : .s))
            // Global coordinates: the zone moves with the edge it drags.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let s = start ?? size
                    start = s
                    onResize(CGSize(width: edge == .corner ? s.width + v.translation.width : s.width,
                                    height: s.height + v.translation.height))
                }
                .onEnded { _ in start = nil })
    }
}
