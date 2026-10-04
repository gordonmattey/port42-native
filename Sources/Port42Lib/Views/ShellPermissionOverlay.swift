import SwiftUI

/// The permission ask, as a SHELL surface — the one render site for every caller (a port's JS, a
/// companion's tool use, the gateway).
///
/// It lives at the shell root rather than inside a tile because the old card rendered in `ChatView`
/// (a chat TILE): focused on a port, it was off-screen and the gated call hung forever. The
/// tool-use card had it worse — its site went away with ContentView (60fc1d7) and nothing replaced
/// it, so every gated gateway call hung with no prompt at all.
///
/// Deliberately unlike the other shell overlays: **the scrim does not dismiss.** A stray click
/// outside must not silently deny something a companion is waiting on. Esc denies, explicitly.
struct ShellPermissionOverlay: View {
    @ObservedObject var coordinator: PermissionCoordinator
    let accent: Color
    let request: PermissionRequest

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Blocking scrim: captures clicks so nothing behind reacts, but answers nothing.
            Color.black.opacity(0.6).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }

            VStack(spacing: 14) {
                // Who's asking — the first thing you need, and what scope keys off.
                Text(request.asker.uppercased())
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(accent)
                    .tracking(1.2)

                Image(systemName: request.permission.iconName)
                    .font(.system(size: 26))
                    .foregroundStyle(accent)

                Text(request.permission.permissionDescription.title)
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.textPrimary)

                Text(request.permission.permissionDescription.message)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let ask = request.crossSpace {
                    // #238: the first card on the shared layout (docs/plan-permission-card.md): who
                    // wants to do what to what, with the rights to pick and their weight.
                    CrossSpaceCardBody(ask: ask, accent: accent) { choice in
                        coordinator.resolveCurrent(granted: choice != nil, choice: choice)
                    }
                } else {
                    if let detail = request.detail {
                        Text(detail)
                            .font(Port42Theme.monoBold(12))
                            .foregroundStyle(Port42Theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Narrate the macOS dialogs that follow, BEFORE they land (the mic case fires two
                    // more consent sheets — Microphone, then Speech Recognition).
                    if let followUp = request.systemFollowUp {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 10))
                                .foregroundStyle(accent.opacity(0.8))
                                .padding(.top, 1)
                            Text(followUp)
                                .font(Port42Theme.mono(11))
                                .foregroundStyle(Port42Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent.opacity(0.25), lineWidth: 1))
                    }

                    // Say what "Allow" actually does. The old code silently wrote a per-(companion,
                    // space) grant the human was never shown.
                    Text(request.principal.scopeDescription)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(action: { coordinator.resolveCurrent(granted: false) }) {
                            Text("Deny")
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textSecondary)
                                .frame(width: 96, height: 30)
                                .background(Port42Theme.bgSecondary)
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)

                        Button(action: { coordinator.resolveCurrent(granted: true) }) {
                            Text("Allow")
                                .font(Port42Theme.mono(12))
                                .fontWeight(.medium)
                                .foregroundStyle(.black)
                                .frame(width: 96, height: 30)
                                .background(accent)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }

                // A queue is never a surprise.
                if coordinator.pendingCount > 1 {
                    Text("1 of \(coordinator.pendingCount) waiting")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                }
            }
            .padding(24)
            .frame(width: request.crossSpace == nil ? 380 : 440)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("Permission request from \(request.asker)")
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Port42Theme.bgPrimary)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 40)
            )
            .scaleEffect(appeared ? 1 : 0.96)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { appeared = true } }
        // Re-run the entrance for each queued ask so an advancing queue reads as a new card.
        .id(request.id)
    }
}

/// The cross-space card's own part (#238): both ports named, a box per right with see ticked and
/// nothing stronger, the space box off, and Deny or Allow. `answer(nil)` denies.
struct CrossSpaceCardBody: View {
    let ask: CrossSpaceAsk
    let accent: Color
    let answer: (CrossSpaceChoice?) -> Void

    @State private var picked: Set<RemoteRight> = CrossSpaceAsk.preset
    @State private var wholeSpace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.sentence)
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            // Port42's own option style, as the share box draws it ([x] in the accent), not the system checkbox
            // (Gordon, 2026-10-03: the card's colors and boxes did not match the others).
            ForEach(CrossSpaceAsk.offered, id: \.self) { right in
                option(binding(right)) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(CrossSpaceAsk.name(right))
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textPrimary)
                            if right == ask.needs, right != .see {
                                Text("this call needs it")
                                    .font(Port42Theme.mono(10))
                                    .foregroundStyle(accent)
                            }
                        }
                        Text(CrossSpaceAsk.meaning(right))
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityLabel(CrossSpaceAsk.accessibilityLabel(right, needs: ask.needs))
            }

            Divider().overlay(Port42Theme.border)

            option($wholeSpace) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ask.spaceBoxLabel)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                    Text("See and use only. Edit is only ever given port by port.")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
            }
            .accessibilityLabel("\(ask.spaceBoxLabel). See and use only.")

            Text("Kept until you change it in Settings, Access.")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 12) {
                Button(action: { answer(nil) }) {
                    Text("Deny")
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 96, height: 30)
                        .background(Port42Theme.bgSecondary)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: { answer(CrossSpaceChoice(rights: picked, wholeSpace: wholeSpace)) }) {
                    Text("Allow")
                        .font(Port42Theme.mono(12))
                        .fontWeight(.medium)
                        .foregroundStyle(.black)
                        .frame(width: 96, height: 30)
                        .background(picked.isEmpty ? accent.opacity(0.35) : accent)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty)
                .accessibilityLabel(CrossSpaceAsk.allowLabel(picked, wholeSpace: wholeSpace))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    /// One box on the card, as the share box draws its options: `[x]` in the accent when on, `[ ]` when off.
    private func option<Label: View>(_ on: Binding<Bool>, @ViewBuilder label: () -> Label) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(on.wrappedValue ? "[x]" : "[ ]").font(Port42Theme.mono(12))
                    .foregroundStyle(on.wrappedValue ? accent : Port42Theme.textSecondary)
                label()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? [.isSelected] : [])
    }

    private func binding(_ right: RemoteRight) -> Binding<Bool> {
        Binding(get: { picked.contains(right) },
                set: { on in if on { picked.insert(right) } else { picked.remove(right) } })
    }
}
