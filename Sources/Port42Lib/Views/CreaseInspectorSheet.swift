import SwiftUI

/// Companion state inspector — accessible only in a swim.
/// Shows fold orientation, current position, and creases (prediction breaks).
public struct CreaseInspectorSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let companion: AgentConfig
    let channelId: String

    @State private var fold: CompanionFold?
    @State private var position: CompanionPosition?
    @State private var creases: [CompanionCrease] = []
    @State private var tab: Tab = .fold

    enum Tab: String, CaseIterable {
        case fold = "fold"
        case position = "position"
        case creases = "creases"
    }

    public init(companion: AgentConfig, channelId: String) {
        self.companion = companion
        self.channelId = channelId
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(companion.displayName)
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.textAgent)
                    Text("inner state")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Port42Theme.bgSecondary)

            Divider().background(Port42Theme.border)

            // Tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { t in
                    TabButton(
                        label: tabLabel(t),
                        badge: tabBadge(t),
                        isActive: tab == t,
                        action: { tab = t }
                    )
                }
            }
            .background(Port42Theme.bgSecondary)

            Divider().background(Port42Theme.border)

            // Content
            ScrollView {
                Group {
                    switch tab {
                    case .fold:    FoldPanel(fold: fold, onReset: resetFold)
                    case .position: PositionPanel(position: position)
                    case .creases: CreasesPanel(creases: creases, onForget: forgetCrease)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 540)
        .background(Port42Theme.bgPrimary)
        .onAppear { loadState() }
    }

    // MARK: - Helpers

    private func tabLabel(_ t: Tab) -> String { t.rawValue }

    private func tabBadge(_ t: Tab) -> String? {
        switch t {
        case .fold:     return fold.map { "depth \($0.depth)" }
        case .position: return position?.isEmpty == false ? "set" : nil
        case .creases:  return creases.isEmpty ? nil : "\(creases.count)"
        }
    }

    private func loadState() {
        fold     = try? appState.db.fetchFold(companionId: companion.id, channelId: channelId)
        position = try? appState.db.fetchPosition(companionId: companion.id, channelId: channelId)
        creases  = (try? appState.db.fetchCreases(companionId: companion.id, channelId: channelId, limit: 20)) ?? []
    }

    private func forgetCrease(_ id: String) {
        try? appState.db.deleteCrease(id: id)
        creases.removeAll { $0.id == id }
    }

    private func resetFold() {
        guard var f = fold else { return }
        f.established = nil
        f.tensions    = nil
        f.holding     = nil
        f.depth       = 0
        f.updatedAt   = Date()
        try? appState.db.saveFold(f)
        fold = f
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let label: String
    let badge: String?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(Port42Theme.monoBold(11))
                    .textCase(.uppercase)
                if let b = badge {
                    Text(b)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(isActive ? Port42Theme.accent : Port42Theme.textSecondary.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((isActive ? Port42Theme.accent : Port42Theme.textSecondary).opacity(0.1))
                        .cornerRadius(3)
                }
            }
            .foregroundStyle(isActive ? Port42Theme.accent : Port42Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle()
                        .fill(Port42Theme.accent)
                        .frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fold Panel

private struct FoldPanel: View {
    let fold: CompanionFold?
    let onReset: () -> Void

    var body: some View {
        if let f = fold, f.depth > 0 || !(f.established ?? []).isEmpty || !(f.tensions ?? []).isEmpty || f.holding != nil {
            VStack(alignment: .leading, spacing: 16) {
                if let est = f.established, !est.isEmpty {
                    StateField(label: "established") { TagList(items: est) }
                }
                if let ten = f.tensions, !ten.isEmpty {
                    StateField(label: "in tension") { TagList(items: ten) }
                }
                if let h = f.holding, !h.isEmpty {
                    StateField(label: "holding") {
                        Text(h)
                            .font(Port42Theme.mono(12))
                            .foregroundStyle(Port42Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().background(Port42Theme.border)
                Button("reset fold") { onReset() }
                    .buttonStyle(.plain)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            }
        } else {
            EmptyState(text: "no fold yet")
        }
    }
}

// MARK: - Position Panel

private struct PositionPanel: View {
    let position: CompanionPosition?

    var body: some View {
        if let p = position, !p.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if let r = p.read, !r.isEmpty {
                    StateField(label: "read") {
                        Text(r)
                            .font(Port42Theme.mono(12))
                            .foregroundStyle(Port42Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let s = p.stance, !s.isEmpty {
                    StateField(label: "stance") {
                        Text(s)
                            .font(Port42Theme.mono(12))
                            .foregroundStyle(Port42Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let w = p.watching, !w.isEmpty {
                    StateField(label: "watching") { TagList(items: w) }
                }
            }
        } else {
            EmptyState(text: "no position formed yet")
        }
    }
}

// MARK: - Creases Panel

private struct CreasesPanel: View {
    let creases: [CompanionCrease]
    let onForget: (String) -> Void

    var body: some View {
        if creases.isEmpty {
            EmptyState(text: "no creases yet")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(creases, id: \.id) { crease in
                    CreaseCard(crease: crease, onForget: { onForget(crease.id) })
                }
            }
        }
    }
}

// MARK: - Shared sub-components

private struct StateField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }
}

private struct EmptyState: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Port42Theme.mono(12))
            .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }
}

private struct TagList: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("–")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                    Text(item)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct CreaseCard: View {
    let crease: CompanionCrease
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(crease.content)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("forget", action: onForget)
                    .buttonStyle(.plain)
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            }
            if let pred = crease.prediction, let act = crease.actual {
                VStack(alignment: .leading, spacing: 2) {
                    Text("expected: \(pred)")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                    Text("got: \(act)")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                }
            }
            Text("weight \(String(format: "%.1f", crease.weight))")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
        }
        .padding(12)
        .background(Port42Theme.bgSecondary)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
    }
}

