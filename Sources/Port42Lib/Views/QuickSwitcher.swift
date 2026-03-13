import SwiftUI

// MARK: - Quick Switcher (F-203)
// Cmd+K overlay with fuzzy search across channels, companions, and swims.

struct QuickSwitcherItem: Identifiable {
    let id: String
    let icon: String
    let name: String
    let kind: Kind

    enum Kind {
        case channel(Channel)
        case companion(AgentConfig)
        case friend(ChannelMember)
    }
}

public struct QuickSwitcher: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Port42Theme.textSecondary)

                TextField("Jump to...", text: $query)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(14))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .focused($isFocused)
                    .onSubmit { selectCurrent() }
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                    }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(0, selectedIndex - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        isPresented = false
                        return .handled
                    }

                Text("esc")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Port42Theme.bgHover)
                    .cornerRadius(3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Port42Theme.border)

            // Invite link hint
            if let inviteInfo = parsedInvite {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .foregroundStyle(Port42Theme.accent)
                    Text("press enter to join #\(inviteInfo.channelName)")
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.accent)
                    if let host = inviteInfo.hostName {
                        Text("hosted by \(host)")
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Port42Theme.accent.opacity(0.1))
            }

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if filteredItems.isEmpty {
                            Text("No results")
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textSecondary)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                Button(action: { select(item) }) {
                                    HStack(spacing: 10) {
                                        Text(item.icon)
                                            .font(Port42Theme.mono(14))
                                            .foregroundStyle(iconColor(item))
                                            .frame(width: 20)

                                        Text(item.name)
                                            .font(Port42Theme.mono(13))
                                            .foregroundStyle(Port42Theme.textPrimary)

                                        Spacer()

                                        Text(kindLabel(item))
                                            .font(Port42Theme.mono(10))
                                            .foregroundStyle(Port42Theme.textSecondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        index == selectedIndex
                                            ? Port42Theme.accent.opacity(0.15)
                                            : Color.clear
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: selectedIndex) { _, newIndex in
                    if newIndex < filteredItems.count {
                        proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                    }
                }
            }
        }
        .background(Port42Theme.bgSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 20)
        .frame(width: 420)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    // MARK: - Data

    private var channelItems: [QuickSwitcherItem] {
        appState.channels.filter { $0.type != "dm" }.map { ch in
            QuickSwitcherItem(id: "ch-\(ch.id)", icon: "#", name: ch.name, kind: .channel(ch))
        }
    }

    private var companionItems: [QuickSwitcherItem] {
        appState.companions.map { comp in
            QuickSwitcherItem(id: "sw-\(comp.id)", icon: "@", name: comp.displayName, kind: .companion(comp))
        }
    }

    private var friendItems: [QuickSwitcherItem] {
        appState.friends.map { friend in
            QuickSwitcherItem(id: "fr-\(friend.senderId)", icon: "@", name: friend.displayName(localOwner: appState.currentUser?.displayName), kind: .friend(friend))
        }
    }

    private var filteredItems: [QuickSwitcherItem] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty query: show channels only (companions and friends are in sidebar)
        guard !raw.isEmpty else { return channelItems }

        // @ prefix: search companions and friends
        if raw.hasPrefix("@") {
            let q = String(raw.dropFirst())
            let people = companionItems + friendItems
            if q.isEmpty { return people }
            return people.filter { match(q, $0.name.lowercased()) }
        }

        // # prefix: search channels only
        if raw.hasPrefix("#") {
            let q = String(raw.dropFirst())
            if q.isEmpty { return channelItems }
            return channelItems.filter { match(q, $0.name.lowercased()) }
        }

        // No prefix: search all
        let all = channelItems + companionItems + friendItems
        return all.filter { match(raw, $0.name.lowercased()) }
    }

    private func match(_ query: String, _ name: String) -> Bool {
        name.contains(query) || fuzzyMatch(query, name)
    }

    // MARK: - Fuzzy Match

    private func fuzzyMatch(_ query: String, _ target: String) -> Bool {
        var targetIndex = target.startIndex
        for char in query {
            guard let found = target[targetIndex...].firstIndex(of: char) else {
                return false
            }
            targetIndex = target.index(after: found)
        }
        return true
    }

    // MARK: - Invite Link

    /// Extract the first URL from text that may contain surrounding prose
    private func extractURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        if let match = detector?.firstMatch(in: text, range: range),
           let urlRange = Range(match.range, in: text) {
            return String(text[urlRange])
        }
        return nil
    }

    private var parsedInvite: ChannelInviteData? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try parsing the input directly, or extract a URL from surrounding text
        let candidates = [trimmed, extractURL(from: trimmed)].compactMap { $0 }

        for candidate in candidates {
            // Direct port42:// deep link
            if candidate.hasPrefix("port42://channel"),
               let url = URL(string: candidate) {
                return ChannelInvite.parse(url: url)
            }

            // HTTPS invite page link (e.g. https://port42.ai/invite.html?gateway=wss://...&id=...&name=...)
            // Also supports legacy format where the invite page IS the gateway host
            if let url = URL(string: candidate),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               (components.scheme == "https" || components.scheme == "http"),
               (components.path == "/invite" || components.path == "/invite.html") {
                let items = components.queryItems ?? []
                let dict = Dictionary(items.compactMap { item in
                    item.value.map { (item.name, $0) }
                }, uniquingKeysWith: { _, last in last })

                guard let channelId = dict["id"],
                      let name = dict["name"] else { continue }

                // Prefer explicit gateway param (new format via port42.ai)
                // Fall back to deriving from the invite page host (legacy self-hosted format)
                let gateway: String
                if let gw = dict["gateway"], !gw.isEmpty {
                    gateway = gw
                } else {
                    guard let host = components.host else { continue }
                    let scheme = components.scheme == "https" ? "wss" : "ws"
                    let port = components.port.map { ":\($0)" } ?? ""
                    gateway = "\(scheme)://\(host)\(port)"
                }

                return ChannelInviteData(
                    gateway: gateway,
                    channelId: channelId,
                    channelName: name,
                    encryptionKey: dict["key"],
                    token: dict["token"],
                    hostName: dict["host"]
                )
            }
        }

        return nil
    }

    // MARK: - Actions

    private func selectCurrent() {
        if let invite = parsedInvite {
            appState.joinChannelFromInvite(invite)
            isPresented = false
            return
        }

        guard selectedIndex < filteredItems.count else { return }
        select(filteredItems[selectedIndex])
    }

    private func select(_ item: QuickSwitcherItem) {
        switch item.kind {
        case .channel(let channel):
            appState.selectChannel(channel)
        case .companion(let companion):
            appState.startSwim(with: companion)
        case .friend(let friend):
            appState.startDM(with: friend)
        }
        isPresented = false
    }

    // MARK: - Helpers

    private func iconColor(_ item: QuickSwitcherItem) -> Color {
        switch item.kind {
        case .channel: return Port42Theme.accent
        case .companion: return Port42Theme.agentColor(for: item.name)
        case .friend: return Port42Theme.accent.opacity(0.6)
        }
    }

    private func kindLabel(_ item: QuickSwitcherItem) -> String {
        switch item.kind {
        case .channel: return "channel"
        case .companion: return "🏊"
        case .friend: return "friend"
        }
    }
}
