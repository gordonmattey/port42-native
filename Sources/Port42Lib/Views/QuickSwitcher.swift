import SwiftUI

// MARK: - Quick Switcher (F-203)
// Cmd+K overlay with fuzzy search across spaces, companions, and swims.

struct QuickSwitcherItem: Identifiable {
    let id: String
    let icon: String
    let name: String
    let kind: Kind

    enum Kind {
        case space(Space)
        case companion(AgentConfig)
        /// A closed (archived) port: selecting it reopens it (nautilus Phase 2 step 2).
        case closedPort(id: String, spaceId: String?)
        /// A hidden port, running with no tile: selecting it shows it (nautilus Phase 3.2).
        case hiddenPort(id: String)
        /// Bring the Claude Code and Codex sessions running on this Mac in (docs/plan-session-import.md).
        case bringInSessions
    }
}

public struct QuickSwitcher: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    /// The shell hosting this switcher (⌘K migrated from the classic app): companion
    /// selection opens a DM TILE on the current desktop via the shell, not a space switch.
    var shell: ShellState?

    @State private var query = ""
    @State private var selectedIndex = 0
    /// Closed ports, read once when the switcher opens (most recently closed first).
    @State private var closed: [QuickSwitcherItem] = []
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>, shell: ShellState? = nil) {
        self._isPresented = isPresented
        self.shell = shell
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 12) {
                Text("›")
                    .font(Port42Theme.monoBold(22))
                    .foregroundStyle(Port42Theme.accent)
                    .shadow(color: Port42Theme.accent.opacity(0.9), radius: 8)

                TextField("", text: $query, prompt: Text("jump to a space, companion or port…")
                            .foregroundColor(Port42Theme.textSecondary.opacity(0.55)))
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(19))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .tint(Port42Theme.accent)
                    .focused($isFocused)
                    .onSubmit { selectCurrent() }
                    .onChange(of: query) { _, q in
                        selectedIndex = 0
                        // An invite link pasted here opens the accept box (4.6b).
                        if let link = InviteCoupon.inviteLink(in: q), let shell {
                            isPresented = false
                            shell.pendingInvite = link
                        }
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
                    // ⌘⌫ on a closed port deletes it for good.
                    .onKeyPress(.delete, phases: .down) { press in
                        guard press.modifiers.contains(.command), selectedIndex < filteredItems.count,
                              case .closedPort(let id, _) = filteredItems[selectedIndex].kind else { return .ignored }
                        deleteForever(id)
                        return .handled
                    }

                KeyCap(label: "esc") { isPresented = false }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Rectangle().fill(Port42Theme.accent.opacity(0.15)).frame(height: 1)



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
                                            .font(Port42Theme.mono(15))
                                            .foregroundStyle(iconColor(item))
                                            .frame(width: 22)

                                        Text(item.name)
                                            .font(Port42Theme.mono(14))
                                            .foregroundStyle(index == selectedIndex ? Port42Theme.textPrimary : Port42Theme.textPrimary.opacity(0.85))

                                        Spacer()

                                        Text(kindLabel(item))
                                            .font(Port42Theme.mono(10))
                                            .foregroundStyle(Port42Theme.textSecondary)
                                        if case .closedPort(let id, _) = item.kind {
                                            Button { deleteForever(id) } label: {
                                                Image(systemName: "trash").font(.system(size: 10))
                                                    .foregroundStyle(Port42Theme.textSecondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Delete forever (⌘⌫)")
                                        }
                                    }
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 10)
                                    .background(
                                        index == selectedIndex
                                            ? Port42Theme.accent.opacity(0.14)
                                            : Color.clear
                                    )
                                    .overlay(alignment: .leading) {
                                        if index == selectedIndex {
                                            Rectangle().fill(Port42Theme.accent).frame(width: 3)
                                                .shadow(color: Port42Theme.accent.opacity(0.9), radius: 6)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
                .onChange(of: selectedIndex) { _, newIndex in
                    if newIndex < filteredItems.count {
                        proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                    }
                }
            }
        }
        .commandCard(width: 640)
        .onAppear {
            loadClosed()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    // MARK: - Data

    private var spaceItems: [QuickSwitcherItem] {
        // Most-recently-visited first (backlog 0.6): the empty-query list opens on where you were,
        // not the oldest space. Unvisited spaces keep their createdAt order behind the visited ones.
        let ordered = AppState.spacesByRecency(
            appState.spaces.filter { $0.type != "dm" }, lastRead: appState.lastReadDates)
        return ordered.map { ch in
            QuickSwitcherItem(id: "ch-\(ch.id)", icon: "#", name: ch.name, kind: .space(ch))
        }
    }

    private var companionItems: [QuickSwitcherItem] {
        appState.companions.map { comp in
            QuickSwitcherItem(id: "sw-\(comp.id)", icon: "@", name: comp.displayName, kind: .companion(comp))
        }
    }


    /// Every hidden port, in every space, so nothing runs where a person cannot find it.
    private var hiddenItems: [QuickSwitcherItem] {
        appState.portWindows.hiddenPanels.map { p in
            QuickSwitcherItem(id: "hidden-\(p.id)", icon: "◌", name: p.title, kind: .hiddenPort(id: p.id))
        }
    }

    private var actionItems: [QuickSwitcherItem] {
        [QuickSwitcherItem(id: "action-bring-in", icon: "⇥", name: "bring in running sessions", kind: .bringInSessions)]
    }

    private var filteredItems: [QuickSwitcherItem] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty query: spaces, then hidden ports, then recently closed ports.
        guard !raw.isEmpty else { return spaceItems + hiddenItems + Array(closed.prefix(10)) + actionItems }

        // @ prefix: search companions
        if raw.hasPrefix("@") {
            let q = String(raw.dropFirst())
            let people = companionItems
            if q.isEmpty { return people }
            return people.filter { match(q, $0.name.lowercased()) }
        }

        // # prefix: search spaces only
        if raw.hasPrefix("#") {
            let q = String(raw.dropFirst())
            if q.isEmpty { return spaceItems }
            return spaceItems.filter { match(q, $0.name.lowercased()) }
        }

        // No prefix: search all
        let all = spaceItems + companionItems + hiddenItems + closed + actionItems
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




    // MARK: - Actions

    private func selectCurrent() {

        guard selectedIndex < filteredItems.count else { return }
        select(filteredItems[selectedIndex])
    }

    private func select(_ item: QuickSwitcherItem) {
        switch item.kind {
        case .space(let space):
            // ⌘K always finds rested spaces; selecting one WAKES + enters (plan-working-set §A).
            if space.isResting { appState.wakeAndEnterSpace(space) }
            else { appState.selectSpace(space) }
        case .companion(let companion):
            if let shell { shell.activateCompanion(companion) }   // DM tile on this desktop
            else { appState.startSwim(with: companion) }
        case .closedPort(let id, let spaceId):
            // Reopen on its home desktop, and go there so the person sees it come back.
            if let sid = spaceId, sid != appState.currentSpace?.id,
               let space = appState.spaces.first(where: { $0.id == sid }) {
                appState.selectSpace(space)
            }
            appState.portWindows.reopen(id)
            shell?.bringToFront(id)
        case .hiddenPort(let id):
            if let shell { shell.showHidden(id) } else { appState.portWindows.restore(id) }
        case .bringInSessions:
            isPresented = false
            shell?.showImportSessions = true
            return
        }
        isPresented = false
    }

    private func loadClosed() {
        closed = appState.portWindows.closedPorts().map { row in
            QuickSwitcherItem(id: "closed-\(row.id)", icon: "↺", name: row.userTitle ?? row.title,
                              kind: .closedPort(id: row.id, spaceId: row.spaceId))
        }
    }

    private func deleteForever(_ id: String) {
        appState.portWindows.deleteForever(id)
        loadClosed()
        selectedIndex = min(selectedIndex, max(0, filteredItems.count - 1))
    }

    // MARK: - Helpers

    private func iconColor(_ item: QuickSwitcherItem) -> Color {
        switch item.kind {
        case .space: return Port42Theme.accent
        case .companion: return Port42Theme.agentColor(for: item.name)
        case .closedPort, .hiddenPort: return Port42Theme.textSecondary
        case .bringInSessions: return Port42Theme.accent
        }
    }

    private func kindLabel(_ item: QuickSwitcherItem) -> String {
        switch item.kind {
        case .space(let space): return space.isResting ? "resting" : "space"
        case .companion: return "🏊"
        case .closedPort: return "recently closed"
        case .hiddenPort: return "hidden"
        case .bringInSessions: return "claude code · codex"
        }
    }
}
