import SwiftUI

/// Accept an invite to someone's port (nautilus Phase 4, 4.6b): whose it is, what it lets you do,
/// remote wake (on by default, Gordon 2026-09-26), and the code if they sent one. Nothing is joined
/// until the person says so here.
struct AcceptBox: View {
    @Binding var link: String?
    @ObservedObject var appState: AppState
    @ObservedObject var shell: ShellState

    @State private var wake = true
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    private var coupon: InviteCoupon? { link.flatMap(InviteCoupon.fromLink) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("join")
                    .font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.accent)
                    .shadow(color: Port42Theme.accent.opacity(0.8), radius: 6)
                Text(coupon.map { "\($0.hostName)'s \($0.portTitle)" } ?? "an invite")
                    .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary).lineLimit(1)
                Spacer()
                KeyCap(label: "esc")
            }
            if let c = coupon {
                Text("\(c.hostName) is sharing a port with you. it opens here.")
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("you can " + ShareWords.rights(c.rights.compactMap(RemoteRight.init(rawValue:))))
                    .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                Button { wake.toggle() } label: {
                    HStack(spacing: 10) {
                        Text(wake ? "[x]" : "[ ]").font(Port42Theme.mono(12))
                            .foregroundStyle(wake ? Port42Theme.accent : Port42Theme.textSecondary)
                        Text("remote wake").font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                        Text("their chat can wake your companions")
                            .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if c.code {
                    HStack(spacing: 10) {
                        Text("code").font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textSecondary)
                        TextField("six digits they sent you", text: $code)
                            .textFieldStyle(.plain).font(Port42Theme.monoBold(14)).foregroundStyle(Port42Theme.accent)
                            .frame(width: 180)
                    }
                }
                if let error { Text(error).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.error) }
                Button(action: accept) {
                    Text(working ? "> joining…" : "[ open it ↵ ]").font(Port42Theme.monoBold(13))
                        .foregroundStyle(Port42Theme.accent)
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: []).disabled(working)
            } else {
                Text("that link is not an invite Port42 can read.")
                    .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textSecondary)
            }
        }
        .padding(28)
        .commandCard(width: 560)
        .onKeyPress(.escape) { link = nil; return .handled }
    }

    private func accept() {
        guard let link, let user = appState.currentUser else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                var args: [String: Any] = ["link": link, "remoteWake": wake]
                if !code.isEmpty { args["code"] = code }
                let out = try await appState.runBridgeMethod(
                    "invite.accept",
                    principal: .human(id: user.id, displayName: user.displayName, spaceId: appState.currentSpace?.id),
                    args: BridgeArgs(args))
                if let tile = (out.toJSONObject() as? [String: Any])?["tile"] as? String {
                    shell.bringToFront(tile)
                }
                self.link = nil
            } catch {
                self.error = (error as? BridgeError)?.message ?? error.localizedDescription
            }
        }
    }
}
