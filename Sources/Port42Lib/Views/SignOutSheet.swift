import SwiftUI
import AppKit

public struct SignOutSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var isHovering = false
    @State private var autoUpdatesEnabled: Bool = UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
    @StateObject private var instructionsSvc = InstructionService.shared
    @State private var newSecretName = ""
    @State private var newSecretValue = ""
    @State private var newSecretType: Port42AuthStore.SecretType = .bearerToken
    @State private var secrets: [Port42AuthStore.Secret] = Port42AuthStore.shared.listSecrets()
    @AppStorage(ShellMode.takeoverKey) private var fullscreenTakeover = false



    enum SettingsTab: String, CaseIterable { case ai = "AI", grants = "Access", secrets = "Secrets", remote = "Remote", display = "Display", updates = "Updates" }
    @State private var tab: SettingsTab = .ai
    /// Bumped on revoke. The grant store is not `@Published` (it is read on every gated dispatch and
    /// publishing it would redraw the world per permission check), so the manager re-reads on demand.
    @State private var grantsRefresh: UInt = 0
    @State private var newClientName = ""
    /// Where the last hand-made client's token landed. The PATH, never the token itself (NFR2).
    @State private var lastMintedTokenPath: String?
    @State private var providerSel = "Anthropic"     // AI tab provider picker (was a radio-accordion)

    /// Space accent — keys the whole panel like the companion cards. Defaults to the theme accent for
    /// the classic (non-shell) app, which has no per-space color.
    let accent: Color
    public init(isPresented: Binding<Bool>, accent: Color = Port42Theme.accent) {
        self._isPresented = isPresented
        self.accent = accent
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header — left-aligned tracking label (shell style-guide §1), no centered logo/name.
            HStack {
                Text("SETTINGS").font(Port42Theme.monoBold(13)).foregroundStyle(Port42Theme.textSecondary).tracking(3)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 14)

            // Stats (§9c — no dividers, spacing groups them)
            VStack(spacing: 10) {
                statRow(label: "spaces", value: "\(appState.spaces.count)")
                statRow(label: "companions", value: "\(appState.companions.count)")
                statRow(label: "messages", value: "\(appState.messages.count)+")
            }
            .padding(.bottom, 14).padding(.horizontal, 24)

            // Tabs (shell §3 seg) — one section fully open at a time; no accordion.
            tabBar.padding(.horizontal, 24).padding(.bottom, 12)

            // The selected section, fully open. Each builder self-gates on `tab`.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    aiConnectionSection
                    grantsSection
                    secretsSection
                    remoteAccessSection
                    displaySection
                    if tab == .updates { updatesSection }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            // (Sign-out / power / reset live in the shell's Port42 mark menu, top-left.)
        }
        .frame(width: 460, height: 640)
        .background(Port42Theme.shellCard)
    }

    /// Shell segmented tab bar (§3) — the whole segment is tappable.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                let on = tab == t
                Button { tab = t } label: {
                    Text(t.rawValue).font(Port42Theme.mono(11)).foregroundStyle(on ? accent : Port42Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(on ? accent.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())     // clear bg isn't hittable → make the whole segment tappable
                }.buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    /// Shell segmented control (§3) — whole segment tappable.
    private func seg(_ opts: [String], sel: String, _ onTap: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(opts, id: \.self) { o in
                let on = o == sel
                Button { onTap(o) } label: {
                    Text(o).font(Port42Theme.mono(10)).foregroundStyle(on ? accent : Port42Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(on ? accent.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    /// CLI context install (CLAUDE.md / GEMINI.md / AGENTS.md) — lives on the AI screen
    /// (it wires the CLI LLM companions), not Remote Access.
    private var cliInstructionsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CLI CONTEXT").font(Port42Theme.mono(9)).tracking(2).foregroundStyle(Port42Theme.textSecondary)
                Text("installs Port42 context into your CLI tool config so agents can use the RPC API:")
                    .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    cliInstructionButton(label: "CLAUDE.md", installed: instructionsSvc.hasClaudeInstructions,
                                         action: { instructionsSvc.installInstructions(for: "claude") })
                    cliInstructionButton(label: "GEMINI.md", installed: instructionsSvc.hasGeminiInstructions,
                                         action: { instructionsSvc.installInstructions(for: "gemini") })
                    cliInstructionButton(label: "AGENTS.md", installed: instructionsSvc.hasCodexInstructions,
                                         action: { instructionsSvc.installInstructions(for: "codex") })
                }
            }
        }
        .padding(.top, 12)
    }


    @ViewBuilder
    private var aiConnectionSection: some View {
        if tab == .ai {
            Text("Port42 runs AI agents as CLIs in terminal ports: Claude Code, Codex, or your own. Each signs in to its own account in its own terminal; Port42 holds no model and no provider key.")
                .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            cliInstructionsBlock
        }
    }

    @ViewBuilder
    private var remoteAccessSection: some View {
        if tab == .remote {
            VStack(alignment: .leading, spacing: 12) {
                // The three blanket "allow without prompting" toggles are GONE (D12, A.3). They
                // granted terminal, filesystem and screen to anything that called, which is not a
                // caller and so could never be revoked from one. What replaced them is the Access
                // tab: every capability is asked for once, per grantee, and can be withdrawn there.
                Text("Callers ask for each capability once. See what you have allowed, and take it back, under Access.")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                // CLI install (CLAUDE.md/GEMINI.md/AGENTS.md) moved to the AI tab — it wires the CLI LLMs.
            }
            .padding(.leading, 8)
            .padding(.top, 8)
        }
    }

    private func remoteApiToggle(_ label: String, value: Binding<Bool>) -> some View {
        let on = value.wrappedValue
        return Button(action: { value.wrappedValue.toggle() }) {          // §4 chip — whole capsule tappable
            Text(label).font(Port42Theme.mono(11))
                .foregroundStyle(on ? accent : Port42Theme.textPrimary)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background((on ? accent.opacity(0.12) : Color.white.opacity(0.04)), in: Capsule())
                .overlay(Capsule().stroke(on ? accent.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func cliInstructionButton(label: String, installed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(installed ? .green : accent)
                Text(label)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(installed ? Color.green.opacity(0.1) : accent.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }









    @ViewBuilder
    private var displaySection: some View {
        if tab == .display {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FULLSCREEN MODE").font(Port42Theme.mono(9)).tracking(2).foregroundStyle(Port42Theme.textSecondary)
                        Text("take over the screen — hides the Dock & menu bar. Off runs Port42 as a normal window.")
                            .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $fullscreenTakeover).labelsHidden().toggleStyle(.switch).tint(accent)
                        .onChange(of: fullscreenTakeover) { _, _ in applyTakeoverSetting() }
                }
            }
        }
    }

    /// Flip fullscreen takeover live — @AppStorage has already written the flag, so re-apply the one
    /// authoritative window presentation (no restart).
    private func applyTakeoverSetting() {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) else { return }
        ShellMode.applyShellWindow(to: window)
    }




    /// One revocable chip per capability, wrapping.
    private struct FlowChips: View {
        let permissions: [PortPermission]
        let onRevoke: (PortPermission) -> Void

        var body: some View {
            HStack(spacing: 5) {
                ForEach(permissions, id: \.rawValue) { perm in
                    Button { onRevoke(perm) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: perm.iconName).font(.system(size: 8))
                            Text(perm.rawValue).font(Port42Theme.mono(9))
                            Image(systemName: "xmark").font(.system(size: 7)).opacity(0.5)
                        }
                        .foregroundStyle(Port42Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Revoke \(perm.rawValue)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Access (the permission manager, slice-02 milestone A step 2 / D13)
    //
    // THE FIRST TIME IN THE PRODUCT'S LIFE THAT A GRANTED PERMISSION CAN BE SEEN. Nothing under
    // `Views/` had ever read the grant store, so consent was invisible from the moment it was given:
    // the store grew to 144 grants, of which only 9 could still fire, and nobody could have known.
    //
    // Grouped by GRANTEE, because "who can do things to my machine" is the question a person
    // actually has. Each row is one object in one zone, with its capabilities and a revoke.

    /// One grantee's grants, assembled for display.
    private struct GranteeGrants: Identifiable {
        let id: String                       // the grantee id
        let scopes: [Scope]
        struct Scope: Identifiable {
            let id: String                   // object + zone
            let object: String
            let zone: String                 // "" = unzoned
            let permissions: [PortPermission]
            let lastUsedAt: Date?
        }
    }

    private var granteeGrants: [GranteeGrants] {
        let rows = appState.allGrants()
        let byGrantee = Dictionary(grouping: rows, by: \.grantee)
        return byGrantee.keys.sorted().map { grantee in
            let scopes = Dictionary(grouping: byGrantee[grantee] ?? [],
                                    by: { "\($0.object)\u{1}\($0.zone)" })
            let ordered = scopes.keys.sorted().map { key -> GranteeGrants.Scope in
                let group = scopes[key] ?? []
                return GranteeGrants.Scope(
                    id: key,
                    object: group[0].object,
                    zone: group[0].zone,
                    permissions: group.map(\.permission).sorted { $0.rawValue < $1.rawValue },
                    lastUsedAt: group.compactMap(\.lastUsedAt).max())
            }
            return GranteeGrants(id: grantee, scopes: ordered)
        }
    }

    /// Both labels are pure and live in `PortGrantDisplay`, so the dead-zone rule the manager exists
    /// to surface is unit-tested rather than asserted by a view.
    private func objectLabel(_ object: String) -> String {
        PortGrantDisplay.objectLabel(object)
    }

    private func zoneLabel(_ zone: String) -> (text: String, isDead: Bool) {
        PortGrantDisplay.zoneLabel(zone, spaceNames: liveSpaceNames)
    }

    private var liveSpaceNames: [String: String] {
        Dictionary(appState.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private func usedLabel(_ date: Date?) -> String {
        guard let date else { return "never used" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "used today" }
        if days == 1 { return "used yesterday" }
        return "used \(days) days ago"
    }

    /// **ADD A CLIENT BY HAND** — the enrolment route for a caller nobody installs (CR4).
    ///
    /// Children enrol at spawn and the CLI enrols at install, so what is left needing a human is a
    /// script, a cron job, a curl at a terminal: things with no installer to hang a named act on, and
    /// no human present at CALL time to answer a prompt. Pairing was dropped, so this is the only
    /// route they have — which is why it blocks enforcement rather than being a convenience.
    ///
    /// It shows the PATH rather than the token. The token is the thing to keep out of scrollback and
    /// out of a screenshot; the path is what the caller actually needs, since the documented client
    /// flow is "read a known file".
    @ViewBuilder
    private var addByHandRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("name a script or tool", text: $newClientName)
                    .font(Port42Theme.mono(11))
                    .textFieldStyle(.plain)
                    .padding(4)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.3), lineWidth: 1))
                    .onSubmit { addClientByHand() }

                Button(action: addClientByHand) {
                    Text("add")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(newClientName.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Port42Theme.textSecondary : accent)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(newClientName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let path = lastMintedTokenPath {
                // The credential itself is never shown (NFR2) — only where it landed.
                Text("Token written to \(path)\nSend it as: Authorization: Bearer <contents>")
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(accent.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    private func addClientByHand() {
        let raw = newClientName.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let id = ClientRegistry.slug(raw)
        guard appState.clientRegistry.register(id: id, name: raw, kind: .manual) != nil else { return }
        lastMintedTokenPath = appState.clientRegistry.tokenPath(id: id).path
        newClientName = ""
        grantsRefresh &+= 1
    }

    @ViewBuilder
    private var grantsSection: some View {
        if tab == .grants {
            VStack(alignment: .leading, spacing: 10) {
                Text("Everything you have allowed, and who holds it. Revoking takes effect on the next call.")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))

                addByHandRow

                // Enrolled clients (slice-02 half two, step 4). A client is a GRANTEE KIND beside
                // companion, port and peer, which is why "who is connected" and "what did I grant"
                // are one screen rather than two answering the same question (D13).
                //
                // A token IS enforced (step 5): a client listed here is the complete set of callers
                // that can reach the bridge through the gateway, and revoking one refuses it on its
                // next call with no gateway restart. So this list is not informational — it is the
                // door, and an empty list means nothing outside the app can call in.
                let clients = appState.enrolledClients()
                if !clients.isEmpty {
                    Text("CONNECTED")
                        .font(Port42Theme.mono(9)).tracking(2)
                        .foregroundStyle(Port42Theme.textSecondary)
                        .padding(.top, 4)
                    ForEach(clients) { client in
                        HStack(spacing: 8) {
                            Text(client.name)
                                .font(Port42Theme.monoBold(12))
                                .foregroundStyle(Port42Theme.textPrimary)
                            Text(client.kind.rawValue)
                                .font(Port42Theme.mono(9))
                                .foregroundStyle(Port42Theme.textSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                            Spacer()
                            Button("revoke client") {
                                appState.revokeClient(id: client.id)
                                grantsRefresh &+= 1
                            }
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                            .buttonStyle(.plain)
                        }
                        .id("client-\(client.id)-\(grantsRefresh)")
                    }
                    Text("GRANTED")
                        .font(Port42Theme.mono(9)).tracking(2)
                        .foregroundStyle(Port42Theme.textSecondary)
                        .padding(.top, 8)
                }

                let all = granteeGrants
                if all.isEmpty {
                    Text("Nothing has been granted yet.")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(all) { grantee in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(grantee.id)
                                    .font(Port42Theme.monoBold(12))
                                    .foregroundStyle(Port42Theme.textPrimary)
                                Spacer()
                                Button("revoke all") {
                                    appState.revokeAllGrants(grantee: grantee.id)
                                    grantsRefresh &+= 1
                                }
                                .font(Port42Theme.mono(10))
                                .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                                .buttonStyle(.plain)
                            }

                            ForEach(grantee.scopes) { scope in
                                let zone = zoneLabel(scope.zone)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(objectLabel(scope.object))
                                            .font(Port42Theme.mono(11))
                                            .foregroundStyle(Port42Theme.textPrimary)
                                        Text(zone.text)
                                            .font(Port42Theme.mono(10))
                                            .foregroundStyle(zone.isDead ? Color.orange.opacity(0.8)
                                                                       : Port42Theme.textSecondary)
                                        Spacer()
                                        Text(usedLabel(scope.lastUsedAt))
                                            .font(Port42Theme.mono(9))
                                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                                    }
                                    // One chip per capability, each individually revocable — which is
                                    // what the table bought. Under the old comma-joined defaults key
                                    // the smallest thing you could withdraw was everything.
                                    FlowChips(permissions: scope.permissions) { perm in
                                        appState.revokeGrant(grantee: grantee.id, object: scope.object,
                                                             zone: scope.zone, permission: perm)
                                        grantsRefresh &+= 1
                                    }
                                }
                                .padding(.leading, 10)
                            }
                        }
                        .padding(.vertical, 6)
                        .id("\(grantee.id)-\(grantsRefresh)")
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Secrets

    private func secretTypeLabel(_ t: Port42AuthStore.SecretType) -> String {
        switch t {
        case .bearerToken: return "Bearer"
        case .apiKey: return "API Key"
        case .basicAuth: return "Basic"
        case .header: return "Header"
        }
    }

    @ViewBuilder
    private var secretsSection: some View {
        if tab == .secrets {
            VStack(alignment: .leading, spacing: 10) {
                Text("Named credentials for rest.call. Companions reference these by name — they never see the raw value.")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))

                // Existing secrets
                ForEach(secrets) { secret in
                    HStack(spacing: 8) {
                        Text(secret.name)
                            .font(Port42Theme.monoBold(12))
                            .foregroundStyle(Port42Theme.textPrimary)
                        Text(secret.type.rawValue)
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(3)
                        Spacer()
                        Button(action: {
                            Port42AuthStore.shared.deleteSecret(name: secret.name)
                            secrets = Port42AuthStore.shared.listSecrets()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Add new secret
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("name", text: $newSecretName)
                            .font(Port42Theme.mono(11))
                            .textFieldStyle(.plain)
                            .frame(width: 100)
                            .padding(4)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.3), lineWidth: 1))

                        Menu {
                            Button("Bearer") { newSecretType = .bearerToken }
                            Button("API Key") { newSecretType = .apiKey }
                            Button("Basic") { newSecretType = .basicAuth }
                            Button("Header") { newSecretType = .header }
                        } label: {
                            HStack(spacing: 5) {
                                Text(secretTypeLabel(newSecretType)).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Port42Theme.textSecondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .frame(width: 110)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }

                    HStack(spacing: 8) {
                        SecureField("credential value", text: $newSecretValue)
                            .font(Port42Theme.mono(11))
                            .textFieldStyle(.plain)
                            .padding(4)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.3), lineWidth: 1))

                        Button(action: {
                            let name = newSecretName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            let value = newSecretValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty, !value.isEmpty else { return }
                            Port42AuthStore.shared.saveSecret(name: name, type: newSecretType, value: value)
                            secrets = Port42AuthStore.shared.listSecrets()
                            newSecretName = ""
                            newSecretValue = ""
                        }) {
                            let ready = !newSecretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                        !newSecretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            Text("add").font(Port42Theme.monoBold(11))                 // §7 accent-filled commit
                                .foregroundStyle(ready ? .black : Port42Theme.textSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(ready ? accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(newSecretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  newSecretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Port42Theme.textSecondary)
            Text("updates")
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)
            Spacer()

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            Text("v\(version) (\(build))")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
        }

        HStack(spacing: 8) {
            Button(action: {
                isPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                    Text("check now")
                        .font(Port42Theme.monoBold(12))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accent.opacity(0.1))
                .cornerRadius(7)
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle(isOn: $autoUpdatesEnabled) {
                Text("auto")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(accent)
            .onChange(of: autoUpdatesEnabled) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "SUAutomaticallyUpdate")
                UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks")
            }
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)
            Spacer()
            Text(value)
                .font(Port42Theme.monoBold(13))
                .foregroundStyle(Port42Theme.textPrimary)
        }
    }




    private func doSignOut() {
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            appState.lockApp()
        }
    }

    private func doOff() {
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            appState.powerOff()
        }
    }

    private func doReset() {
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            appState.resetApp()
        }
    }
}
