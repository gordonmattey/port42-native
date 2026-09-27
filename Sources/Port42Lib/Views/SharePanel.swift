import SwiftUI

// MARK: - The sharing pill (nautilus Phase 4, 4.6b; Gordon chose the pill, 2026-09-26)
//
// One word in a tile's chrome says whose the port is and who else is in it: "shared · 2" on a port of
// this instance, "Ada's" on a tile of someone else's. Everything about sharing is one click behind
// it, so the chrome gains one control however many sharing actions there are.

struct SharePillButton: View {
    @ObservedObject var appState: AppState
    let pill: SharePill
    let tileId: String
    let portKey: String?
    let accent: Color
    var onInvite: () -> Void

    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Text(pill.label)
                .font(Port42Theme.mono(9))
                .foregroundStyle(offline ? Port42Theme.textPrimary : accent)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Port42Theme.bgHover, in: Capsule())
                .overlay(Capsule().strokeBorder(accent.opacity(offline ? 0 : 0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Group {
                switch pill {
                case .shared:
                    if let portKey {
                        ShareHostPanel(appState: appState, portKey: portKey) { open = false; onInvite() }
                    }
                case .theirs:
                    ShareGuestPanel(appState: appState, tileId: tileId) { open = false }
                }
            }
            .padding(12)
            .frame(width: 300)
            .background(Port42Theme.bgPrimary)
        }
    }

    private var offline: Bool { if case .theirs(_, false) = pill { return true }; return false }

    private var help: String {
        switch pill {
        case .shared: return "Who this port is shared with. Click to change it."
        case .theirs(let host, true): return "\(host)'s port, live from their machine. Click for what you can do."
        case .theirs(let host, false): return "\(host)'s machine cannot be reached. This shows the port as it last was; it reconnects on its own."
        }
    }
}

/// On a port of this instance: who has it, what each can do, the invites out, and a new invite.
struct ShareHostPanel: View {
    @ObservedObject var appState: AppState
    let portKey: String
    var onInvite: () -> Void

    var body: some View {
        let sharing = appState.sharing[portKey] ?? PortSharing()
        VStack(alignment: .leading, spacing: 10) {
            SharePanelHeading("shared with")
            if sharing.people.isEmpty {
                Text("nobody yet").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
            }
            ForEach(sharing.people) { person in
                HStack(spacing: 6) {
                    Text(person.name).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach([RemoteRight.use, .edit, .wakeAgents], id: \.self) { right in
                        let on = person.rights.contains(right)
                        RightChip(label: ShareWords.right(right), on: on) {
                            appState.setRemoteRight(right, !on, peer: person.peer, port: portKey)
                        }
                    }
                    Button { appState.stopSharing(peer: person.peer, port: portKey) } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain).help("Stop sharing with \(person.name)")
                }
            }
            let invites = appState.openInvites().filter { $0.portKey == portKey }
            if !invites.isEmpty {
                HStack {
                    Text(invites.count == 1 ? "1 invite not used yet" : "\(invites.count) invites not used yet")
                        .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    Button("withdraw") { invites.forEach { appState.withdrawInvite(id: $0.id) } }
                        .buttonStyle(.plain).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textPrimary)
                }
            }
            Divider().opacity(0.4)
            Button(action: onInvite) {
                Text("+ invite someone").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }
}

/// On a tile of someone else's port: whose, what you can do, remote wake, and leaving.
struct ShareGuestPanel: View {
    @ObservedObject var appState: AppState
    let tileId: String
    var onDone: () -> Void

    var body: some View {
        let row = appState.mirroredRemote(tileId)
        let status = appState.mirrorStatus[tileId]
        VStack(alignment: .leading, spacing: 10) {
            SharePanelHeading("from \(row?.hostName ?? status?.hostName ?? "another machine")")
            Text("you can " + ShareWords.rights(row?.rights ?? []))
                .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("remote wake").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                    Text("their chat can wake your companions here, on your model")
                        .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                RightChip(label: status?.wakes == true ? "on" : "off", on: status?.wakes == true) {
                    appState.setMirrorWakes(tile: tileId, !(status?.wakes ?? false))
                }
            }
            Divider().opacity(0.4)
            Button { appState.leaveRemotePort(tile: tileId); onDone() } label: {
                Text("leave: close it here").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Closes the tile and forgets the port on this machine. They can invite you again.")
        }
    }
}

/// How sharing reads to a person: the rights in words.
enum ShareWords {
    static func right(_ r: RemoteRight) -> String {
        switch r {
        case .see: return "see"
        case .use: return "use"
        case .edit: return "edit"
        case .wakeAgents: return "wake"
        }
    }

    /// "see, use and edit": the rights a person holds, in a sentence.
    static func rights(_ rs: [RemoteRight]) -> String {
        let words = RemoteRight.allCases.filter(rs.contains).map(right)
        guard let last = words.last else { return "nothing yet" }
        return words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last
    }
}

struct SharePanelHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Port42Theme.mono(9)).tracking(2).foregroundStyle(Port42Theme.textSecondary)
    }
}

struct RightChip: View {
    let label: String
    let on: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(Port42Theme.mono(9))
                .foregroundStyle(on ? Port42Theme.accent : Port42Theme.textSecondary.opacity(0.7))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(on ? Port42Theme.accent.opacity(0.12) : Port42Theme.bgHover, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
