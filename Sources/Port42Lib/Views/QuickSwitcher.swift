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
        case friend(SpaceMember)
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
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>, shell: ShellState? = nil) {
        self._isPresented = isPresented
        self.shell = shell
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

    private var friendItems: [QuickSwitcherItem] {
        appState.friends.map { friend in
            QuickSwitcherItem(id: "fr-\(friend.senderId)", icon: "@", name: friend.displayName(localOwner: appState.currentUser?.displayName), kind: .friend(friend))
        }
    }

    private var filteredItems: [QuickSwitcherItem] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty query: show spaces only (companions and friends are in sidebar)
        guard !raw.isEmpty else { return spaceItems }

        // @ prefix: search companions and friends
        if raw.hasPrefix("@") {
            let q = String(raw.dropFirst())
            let people = companionItems + friendItems
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
        let all = spaceItems + companionItems + friendItems
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
        case .friend(let friend):
            appState.startDM(with: friend)
        }
        isPresented = false
    }

    // MARK: - Helpers

    private func iconColor(_ item: QuickSwitcherItem) -> Color {
        switch item.kind {
        case .space: return Port42Theme.accent
        case .companion: return Port42Theme.agentColor(for: item.name)
        case .friend: return Port42Theme.accent.opacity(0.6)
        }
    }

    private func kindLabel(_ item: QuickSwitcherItem) -> String {
        switch item.kind {
        case .space(let space): return space.isResting ? "resting" : "space"
        case .companion: return "🏊"
        case .friend: return "friend"
        }
    }
}
