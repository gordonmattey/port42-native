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
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        let list = chats.entries[key] ?? []
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if list.isEmpty {
                            Text("No messages yet. What you say here belongs to this port.")
                                .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                                .padding(.top, 8)
                        }
                        // ONE selectable text for the whole transcript, so a drag copies any number of
                        // messages (GM, 2026-09-25: one Text per message allowed copying one at a time).
                        Text(Self.transcript(list))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(list.last?.seq ?? 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo(list.last?.seq, anchor: .bottom) }
                .onChange(of: list.last?.seq) { _, last in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                    chats.markRead(key)
                }
            }
            ChatPresenceStrip(presence: appState.presence, key: key, accent: accent)
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.id) { c in
                        Button { draft = ChatRouting.complete(draft, with: c.displayName) } label: {
                            Text("@" + c.displayName)
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
            HStack(spacing: 6) {
                TextField("say something", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                    .focused($inputFocused)
                    .onSubmit(send)
                    // Tab completes the @name being typed to the first suggestion.
                    .onKeyPress(.tab) {
                        guard let first = suggestions.first else { return .ignored }
                        draft = ChatRouting.complete(draft, with: first.displayName)
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
    private var suggestions: [AgentConfig] {
        guard let q = ChatRouting.mentionQuery(in: draft) else { return [] }
        return Array(MentionParser.autocomplete(query: "@" + q, agents: appState.companions).prefix(5))
    }

    /// The whole transcript as one attributed text: each message is its sender (in the sender's
    /// color, bold) then the text, one blank line between messages. Copying a selection gives
    /// "name  text" lines a person can paste anywhere.
    static func transcript(_ entries: [PortChatEntry]) -> AttributedString {
        var out = AttributedString()
        for (i, e) in entries.enumerated() {
            var name = AttributedString((e.fromName.isEmpty ? e.fromId : e.fromName) + "  ")
            name.font = Port42Theme.monoBold(10)
            name.foregroundColor = ShellDock.avatarColor(e.fromId)
            var body = AttributedString(ChatRouting.displayText(e.text) + (i == entries.count - 1 ? "" : "\n\n"))
            body.font = Port42Theme.mono(11)
            body.foregroundColor = Port42Theme.textPrimary.opacity(0.9)
            out += name
            out += body
        }
        return out
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

/// The bottom edge of a chat, dragged to size it (GM, 2026-09-26, release hit list). The bar sets the
/// height; with `corner`, its right end is a grip that sets the width too. Double-click goes back to
/// the default (or, for a port's chat, toggles covering the whole port).
struct ChatResizeBar: View {
    static let height: CGFloat = 10
    let accent: Color
    let size: CGSize
    let corner: Bool
    let onResize: (CGSize) -> Void
    let onDoubleClick: () -> Void
    @State private var start: CGSize?

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            Capsule().fill(accent.opacity(0.45)).frame(width: 36, height: 3)
            Spacer()
        }
        .frame(width: size.width, height: Self.height)
        .background(Port42Theme.shellCard)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(drag(width: false))
        .onTapGesture(count: 2, perform: onDoubleClick)
        .overlay(alignment: .trailing) {
            if corner {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8)).foregroundStyle(accent.opacity(0.6))
                    .frame(width: 18, height: Self.height)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                    .gesture(drag(width: true))
                    .help("Drag to size the chat")
            }
        }
        .help("Drag to size the chat; double-click to reset")
    }

    /// Global coordinates: the bar moves with the edge it drags, so its own space would shift under it.
    private func drag(width: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                let s = start ?? size
                start = s
                onResize(CGSize(width: width ? s.width + v.translation.width : s.width,
                                height: s.height + v.translation.height))
            }
            .onEnded { _ in start = nil }
    }
}
