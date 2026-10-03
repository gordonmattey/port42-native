import Testing
import Foundation
@testable import Port42Lib

/// **A wake line reaches the companion as sent, and is never mirrored as the person's** (#253).
///
/// Gordon's plain post in one space turned up in a port's chat in another space as
/// `[gordon in the chat of port '…']: is everyone working on something ?child-33243ff5-…`. The wake
/// line was typed as keys; Claude Code's file picker took the `@` and its Enter added the
/// companion's token file; the line no longer started `[@`, so it was mirrored into a chat as if the
/// person had typed it. And the companion behind that token had been deleted, its client still live.
@Suite("Wake lines (#253)")
@MainActor
struct WakeLineTests {

    @Test("a wake line, which carries an @, is pasted whole rather than typed as keys")
    func atLinesArePasted() {
        let wake = ChatRouting.terminalLine(sender: "gordon", source: "the chat of port 'engineering operator'",
                                            text: "is everyone working on something ?")
        #expect(wake.contains("@"))
        #expect(TerminalWrite.message(TerminalWrite.trimming(wake).body).paste,
                "a typed @ opens the CLI's file picker, which rewrote the line")
        #expect(TerminalWrite.message("look at @~/notes.txt").paste)
        #expect(!TerminalWrite.message("ok, starting the build now").paste, "plain short text is still typed")
    }

    @Test("a line Port42 typed is recognised even after a TUI rewrote it")
    func garbledWakeIsStillInjected() {
        let garbled = "[gordon in the chat of port 'engineering operator' (id 7606B386)]: is everyone "
                    + "working on something ?child-33243ff5-0b4b-44f5-9d38-bd14dbc36fe1-d2ed12ef-f612"
        #expect(ChatRouting.isInjectedLine(garbled), "a rewritten wake line was taken for the person's own")
        #expect(ChatRouting.isInjectedLine("[@gordon in #genesis]: hi"))
        #expect(!ChatRouting.isInjectedLine("please look at the release notes"))
        #expect(!ChatRouting.isInjectedLine("[draft] ready for review"), "brackets alone are not a wake line")
    }

    @Test("deleting a companion revokes every client its terminals enrolled under")
    func deleteRevokesChildClients() throws {
        let w = try makeParityWorld()
        let appState = w.state, c = w.companion
        let reg = appState.clientRegistry
        let inA = ClientRegistry.childId(companionId: c.id, spaceId: "space-a")
        let inB = ClientRegistry.childId(companionId: c.id, spaceId: "space-b")
        let tokenA = try #require(reg.register(id: inA, name: c.displayName, kind: .child))
        reg.register(id: inB, name: c.displayName, kind: .child)
        let other = ClientRegistry.childId(companionId: "someone-else", spaceId: "space-a")
        reg.register(id: other, name: "someone-else", kind: .child)

        appState.deleteCompanion(c)

        #expect(reg.client(id: inA)?.isActive == false, "a deleted companion's client stayed live")
        #expect(reg.client(id: inB)?.isActive == false)
        #expect(!FileManager.default.fileExists(atPath: reg.tokenPath(id: inA).path), "its token file stayed")
        #expect(throws: BridgeError.self, "a deleted companion's token still reached the bridge") {
            _ = try appState.resolveGatewayCaller(credential: tokenA, senderId: "x")
        }
        #expect(reg.client(id: other)?.isActive == true, "another companion's client was revoked")
        reg.revoke(id: other)
    }

    @Test("deleting a companion closes its terminals, even after a rename, and leaves another companion's open")
    func deleteClosesTerminals() throws {
        let w = try makeParityWorld()
        var gone = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "gone",
                                             command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        gone.openInTerminal = true
        var kept = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "kept",
                                             command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        kept.openInTerminal = true
        try w.state.db.saveAgent(gone); try w.state.db.saveAgent(kept)
        w.state.companions = [gone, kept]
        func spawn(_ c: AgentConfig) -> String? {
            w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                            title: c.displayName, companionName: c.displayName,
                                            companionId: c.id, systemPrompt: nil, postCard: false)
        }
        let goneTerm = try #require(spawn(gone)), keptTerm = try #require(spawn(kept))
        #expect(w.state.portWindows.panels.contains { $0.id == goneTerm })
        // Renamed after its terminal was spawned: the terminal still names the old name, and only
        // its companion id ties it to the companion being deleted.
        gone.displayName = "gone-renamed"
        try w.state.db.saveAgent(gone)
        w.state.companions = [gone, kept]

        w.state.deleteCompanion(gone)

        #expect(!w.state.portWindows.panels.contains { $0.id == goneTerm }, "a deleted companion's terminal stayed open")
        #expect(w.state.portWindows.panels.contains { $0.id == keptTerm }, "another companion's terminal was closed")
        withExtendedLifetime(w.state) {}
    }
}
