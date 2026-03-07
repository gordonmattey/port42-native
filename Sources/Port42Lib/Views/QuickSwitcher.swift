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

    private var allItems: [QuickSwitcherItem] {
        let channels = appState.channels.map { ch in
            QuickSwitcherItem(id: "ch-\(ch.id)", icon: "#", name: ch.name, kind: .channel(ch))
        }
        let companions = appState.companions.map { comp in
            QuickSwitcherItem(id: "sw-\(comp.id)", icon: "@", name: comp.displayName, kind: .companion(comp))
        }
        return channels + companions
    }

    private var filteredItems: [QuickSwitcherItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.filter { fuzzyMatch(q, $0.name.lowercased()) }
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
        case .channel(let channel):
            appState.selectChannel(channel)
        case .companion(let companion):
            appState.startSwim(with: companion)
        }
        isPresented = false
    }

    // MARK: - Helpers

    private func iconColor(_ item: QuickSwitcherItem) -> Color {
        switch item.kind {
        case .channel: return Port42Theme.accent
        case .companion: return Port42Theme.textAgent
        }
    }

    private func kindLabel(_ item: QuickSwitcherItem) -> String {
        switch item.kind {
        case .channel: return "channel"
        case .companion: return "swim"
        }
    }
}
