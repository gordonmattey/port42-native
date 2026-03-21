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

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Fold
                    if let f = fold {
                        SectionBlock(title: "fold", badge: "depth \(f.depth)") {
                            if let est = f.established, !est.isEmpty {
                                FieldRow(label: "Established") {
                                    TagList(items: est)
                                }
                            }
                            if let ten = f.tensions, !ten.isEmpty {
                                FieldRow(label: "In tension") {
                                    TagList(items: ten)
                                }
                            }
                            if let h = f.holding, !h.isEmpty {
                                FieldRow(label: "Holding") {
                                    Text(h)
                                        .font(Port42Theme.mono(12))
                                        .foregroundStyle(Port42Theme.textPrimary)
                                }
                            }
                            if f.depth == 0 && (f.established ?? []).isEmpty && (f.tensions ?? []).isEmpty && f.holding == nil {
                                Text("no fold yet")
                                    .font(Port42Theme.mono(12))
                                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                            }
                            Button("Reset fold") {
                                resetFold()
                            }
                            .buttonStyle(.plain)
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                            .padding(.top, 4)
                        }
                    } else {
                        SectionBlock(title: "fold", badge: "depth 0") {
                            Text("no fold yet")
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                        }
                    }

                    // MARK: Position
                    SectionBlock(title: "position") {
                        if let p = position, !p.isEmpty {
                            if let r = p.read, !r.isEmpty {
                                FieldRow(label: "Read") {
                                    Text(r)
                                        .font(Port42Theme.mono(12))
                                        .foregroundStyle(Port42Theme.textPrimary)
                                }
                            }
                            if let s = p.stance, !s.isEmpty {
                                FieldRow(label: "Stance") {
                                    Text(s)
                                        .font(Port42Theme.mono(12))
                                        .foregroundStyle(Port42Theme.textPrimary)
                                }
                            }
                            if let w = p.watching, !w.isEmpty {
                                FieldRow(label: "Watching") {
                                    TagList(items: w)
                                }
                            }
                        } else {
                            Text("no position formed yet")
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                        }
                    }

                    // MARK: Creases
                    SectionBlock(title: "creases", badge: creases.isEmpty ? nil : "\(creases.count)") {
                        if creases.isEmpty {
                            Text("no creases yet")
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                        } else {
                            ForEach(creases, id: \.id) { crease in
                                CreaseCard(crease: crease, onForget: {
                                    forgetCrease(crease.id)
                                })
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 560)
        .background(Port42Theme.bgPrimary)
        .onAppear { loadState() }
    }

    private func loadState() {
        fold = try? appState.db.fetchFold(companionId: companion.id, channelId: channelId)
        position = try? appState.db.fetchPosition(companionId: companion.id, channelId: channelId)
        creases = (try? appState.db.fetchCreases(companionId: companion.id, channelId: channelId, limit: 20)) ?? []
    }

    private func forgetCrease(_ id: String) {
        try? appState.db.deleteCrease(id: id)
        creases.removeAll { $0.id == id }
    }

    private func resetFold() {
        guard var f = fold else { return }
        f.established = nil
        f.tensions = nil
        f.holding = nil
        f.depth = 0
        f.updatedAt = Date()
        try? appState.db.saveFold(f)
        fold = f
    }
}

// MARK: - Sub-components

private struct SectionBlock<Content: View>: View {
    let title: String
    let badge: String?
    @ViewBuilder let content: () -> Content

    init(title: String, badge: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.badge = badge
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .textCase(.uppercase)
                if let b = badge {
                    Text(b)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Port42Theme.accent.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            content()
        }
        .padding(14)
        .background(Port42Theme.bgSecondary)
        .cornerRadius(8)
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
            content()
        }
    }
}

private struct TagList: View {
    let items: [String]
    var body: some View {
        FlowLayout(items: items) { item in
            Text(item)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Port42Theme.bgInput)
                .cornerRadius(4)
        }
    }
}

private struct CreaseCard: View {
    let crease: CompanionCrease
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(crease.content)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: onForget) {
                    Text("forget")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            if let pred = crease.prediction, let act = crease.actual {
                VStack(alignment: .leading, spacing: 2) {
                    Text("expected: \(pred)")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                    Text("got: \(act)")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                }
            }
            HStack {
                Text("weight \(String(format: "%.1f", crease.weight))")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                Spacer()
            }
        }
        .padding(10)
        .background(Port42Theme.bgPrimary)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
    }
}

/// Simple flow layout for tags.
private struct FlowLayout<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            self.buildRows(in: geo.size.width)
        }
        .frame(height: CGFloat(buildRowCount()) * 26)
    }

    private func buildRowCount() -> Int {
        max(1, Int(ceil(Double(items.count) / 4.0)))
    }

    private func buildRows(in totalWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let rows = chunk(items, size: max(1, Int(totalWidth / 90)))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { item in
                        content(item)
                    }
                }
            }
        }
    }

    private func chunk<T>(_ array: [T], size: Int) -> [[T]] {
        stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }
}
