import SwiftUI
import AppKit

/// Share one port with one person on another machine (nautilus Phase 4, 4.6b): choose what they can
/// do, then make a link to send them. The person makes it, so nobody is asked; the link is theirs to
/// send by any means, and the code, if any, by another.
struct ShareBox: View {
    @Binding var portKey: String?
    @ObservedObject var appState: AppState

    @State private var use = true
    @State private var edit = false
    @State private var wake = true
    @State private var code = false
    @State private var made: Made?
    @State private var error: String?

    struct Made: Equatable {
        let link: String
        let code: String?
        let discloses: [String]
    }

    private var title: String {
        appState.portWindows.panels.first { $0.udid == portKey }?.title ?? "this port"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("share")
                    .font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.accent)
                    .shadow(color: Port42Theme.accent.opacity(0.8), radius: 6)
                Text(title).font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary).lineLimit(1)
                Spacer()
                KeyCap(label: "esc")
            }
            if let made {
                result(made)
            } else {
                Text("with one person on another machine. they can always see it; choose what else.")
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                option("use it", "click, type, drive it", $use)
                option("edit it", "change the port itself", $edit)
                option("remote wake", "their companions can wake yours in its chat", $wake)
                option("require a code", "a six-digit code you send them another way", $code)
                if let error { Text(error).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.error) }
                Button(action: make) {
                    Text("[ copy link ↵ ]").font(Port42Theme.monoBold(13)).foregroundStyle(Port42Theme.accent)
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(28)
        .commandCard(width: 560)
        .onKeyPress(.escape) { portKey = nil; return .handled }
    }

    private func option(_ name: String, _ detail: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                Text(on.wrappedValue ? "[x]" : "[ ]").font(Port42Theme.mono(12))
                    .foregroundStyle(on.wrappedValue ? Port42Theme.accent : Port42Theme.textSecondary)
                Text(name).font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                Text(detail).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func result(_ made: Made) -> some View {
        Text("link copied. send it to them; it works once, for 7 days.")
            .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.accent)
        Text(made.link).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textPrimary)
            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        if let code = made.code {
            HStack(spacing: 8) {
                Text("code").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                Text(code).font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.accent).textSelection(.enabled)
                Text("send it another way").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
            }
        }
        if !made.discloses.isEmpty {
            Text("this port can use " + made.discloses.joined(separator: ", ")
                 + " on this Mac, and whoever you let in can make it do so.")
                .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 18) {
            Button("[ done ↵ ]") { portKey = nil }
                .buttonStyle(.plain).font(Port42Theme.monoBold(13)).foregroundStyle(Port42Theme.accent)
                .keyboardShortcut(.return, modifiers: [])
            Button(action: { copy(made.link) }) {
                Text("[ copy again ]").font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func make() {
        guard let portKey, let user = appState.currentUser else { return }
        var rights = ["see"]
        if use { rights.append("use") }
        if edit { rights.append("edit") }
        if wake { rights.append("wake_agents") }
        Task { @MainActor in
            do {
                let out = try await appState.runBridgeMethod(
                    "invite.create",
                    principal: .human(id: user.id, displayName: user.displayName, spaceId: appState.currentSpace?.id),
                    args: BridgeArgs(["port": portKey, "rights": rights, "requireCode": code]))
                let o = out.toJSONObject() as? [String: Any] ?? [:]
                let link = o["link"] as? String ?? ""
                made = Made(link: link, code: o["code"] as? String, discloses: o["discloses"] as? [String] ?? [])
                copy(link)
                error = nil
            } catch {
                self.error = (error as? BridgeError)?.message ?? error.localizedDescription
            }
        }
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}
