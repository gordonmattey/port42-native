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
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if list.isEmpty {
                            Text("No messages yet. What you say here belongs to this port.")
                                .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                                .padding(.top, 8)
                        }
                        ForEach(list, id: \.seq) { e in
                            row(e).id(e.seq)
                        }
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

    private func row(_ e: PortChatEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(ShellDock.avatarColor(e.fromId).gradient).frame(width: 6, height: 6)
            Text(e.fromName.isEmpty ? e.fromId : e.fromName)
                .font(Port42Theme.monoBold(10)).foregroundStyle(Port42Theme.textPrimary)
            Text(e.text)
                .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        error = nil
        Task {
            do { try await appState.postToChatAsPerson(key: key, text: text) }
            catch let e as BridgeError { error = e.message; draft = text }
            catch { self.error = error.localizedDescription; draft = text }
        }
    }
}
