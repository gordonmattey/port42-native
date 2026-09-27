import SwiftUI

/// The running sessions, grouped into the spaces they will go to (docs/plan-session-import.md). Shared
/// by the first-run step and the ⌘K action. Drag a row onto a group's heading to move it, onto "new
/// space" to start one; the pencil renames a group; the box ticks a session in or out.
struct SessionImportList: View {
    let candidates: [SessionImport.Candidate]
    @Binding var selection: SessionImport.Selection
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var dropTarget: String?

    private var byId: [String: SessionImport.Candidate] {
        Dictionary(candidates.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var accent: Color { Port42Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("\(selection.ticked.count) of \(candidates.count) selected")
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                Button("select all") { selection.ticked = Set(candidates.map(\.sessionId)) }
                    .buttonStyle(.plain).font(Port42Theme.mono(11)).foregroundStyle(accent)
                Button("select none") { selection.ticked = [] }
                    .buttonStyle(.plain).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                Spacer()
            }
            ForEach(selection.groups) { g in
                let rows = g.sessions
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        heading(g)
                        ForEach(rows, id: \.self) { id in
                            if let c = byId[id] { row(c) }
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(dropTarget == g.id ? accent.opacity(0.08) : Color.clear))
                    .dropDestination(for: String.self) { items, _ in
                        for id in items { selection.move(id, to: g.id) }
                        return true
                    } isTargeted: { dropTarget = $0 ? g.id : (dropTarget == g.id ? nil : dropTarget) }
                }
            }
            Text("+ new space  (drop a session here)")
                .font(Port42Theme.mono(11))
                .foregroundStyle(dropTarget == "new" ? accent : Port42Theme.textSecondary)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(dropTarget == "new" ? accent : Port42Theme.border))
                .dropDestination(for: String.self) { items, _ in
                    for id in items { selection.moveToNewGroup(id, named: byId[id].map { "\($0.project) \($0.branch ?? "")".trimmingCharacters(in: .whitespaces) } ?? "new space") }
                    return true
                } isTargeted: { dropTarget = $0 ? "new" : (dropTarget == "new" ? nil : dropTarget) }
        }
    }

    @ViewBuilder private func heading(_ g: SessionImport.Group) -> some View {
        HStack(spacing: 8) {
            Text("#").font(Port42Theme.monoBold(13)).foregroundStyle(accent)
            if renaming == g.id {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.monoBold(13))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .onSubmit { selection.rename(g.id, to: draftName); renaming = nil }
            } else {
                Text(g.name).font(Port42Theme.monoBold(13)).foregroundStyle(Port42Theme.textPrimary)
                Button { draftName = g.name; renaming = g.id } label: {
                    Text("✎").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Rename this space")
            }
            Spacer()
        }
    }

    private func row(_ c: SessionImport.Candidate) -> some View {
        let on = selection.ticked.contains(c.sessionId)
        return HStack(spacing: 10) {
            Button { selection.toggle(c.sessionId) } label: {
                Text(on ? "[x]" : "[ ]").font(Port42Theme.mono(12))
                    .foregroundStyle(on ? accent : Port42Theme.textSecondary)
            }
            .buttonStyle(.plain)
            Text(c.cli == .claude ? "claude" : "codex ")
                .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textSecondary)
                .frame(width: 52, alignment: .leading)
            Text(c.branch ?? "—")
                .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary.opacity(0.85))
                .frame(width: 110, alignment: .leading).lineLimit(1)
            Text(c.title.isEmpty ? "(no title yet)" : "\"\(c.title)\"")
                .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if c.panes > 1 {
                Text("open in \(c.panes) terminals").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
            }
            Text(Self.age(c.lastActive)).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
        }
        .padding(.leading, 18)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .draggable(c.sessionId)
        .opacity(on ? 1 : 0.6)
    }

    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// After an import: what came in, and the originals to close, since they now fall behind.
struct SessionImportDone: View {
    let results: [SessionImportResult]
    let candidates: [SessionImport.Candidate]

    var body: some View {
        let byId = Dictionary(candidates.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 4) {
            ForEach(results, id: \.request.sessionId) { r in
                Text("✓ \(r.request.space)   \(r.request.cli.rawValue) \(byId[r.request.sessionId]?.branch ?? "")  → \(CompanionName.mention(r.companion))")
                    .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.accent)
            }
            Spacer().frame(height: 8)
            Text("> close the originals now. they'll fall behind:")
                .font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textPrimary)
            ForEach(results, id: \.request.sessionId) { r in
                let c = byId[r.request.sessionId]
                Text("    \(c?.app ?? "terminal") · \(Self.short(r.request.cwd))\(c?.branch.map { " (\($0))" } ?? "")\(c?.tty.map { "  \($0)" } ?? "")")
                    .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textSecondary)
            }
        }
    }

    static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = p.split(separator: "/")
        return parts.count > 3 ? "~/…/" + parts.suffix(2).joined(separator: "/") : p
    }
}
