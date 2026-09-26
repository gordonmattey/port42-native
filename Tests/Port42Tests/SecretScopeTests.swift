import Testing
import Foundation
@testable import Port42Lib

// A companion may only use the named secrets ticked in its settings. A terminal companion calls with
// its terminal's credential, as a peer, and the check keyed on the caller's kind, so it never ran for
// one: with the REST grant it could use every secret (found 2026-09-26).
@Suite("Secrets are scoped to the companion a caller acts as")
struct SecretScopeTests {

    /// A world with a terminal whose client credential belongs to `companion`.
    @MainActor
    func terminalCompanion(secrets: [String]?) throws -> (ParityWorld, Principal) {
        var w = try makeParityWorld(companionName: "scout")
        var c = w.companion
        c.secretNames = secrets
        w.state.companions = [c]
        w = ParityWorld(state: w.state, companion: c, space: w.space)
        let config = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
                                        spaceId: w.space.id, spaceName: w.space.name, companionName: "scout",
                                        companionId: nil, createdBy: "", companionPrompt: "", env: [:], initialInput: "")
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        let bridge = PortBridge(appState: w.state, spaceId: w.space.id, messageId: "t1")
        var panel = PortPanel(id: "t1", udid: "t1", html: json, bridge: bridge, spaceId: w.space.id,
                              createdBy: nil, messageId: "t1", size: CGSize(width: 400, height: 300))
        panel.portType = "terminal"
        w.state.portWindows.panels.append(panel)
        w.state.terminalClientPanels["terminal-t1"] = "t1"
        return (w, .peer(id: "terminal-t1", displayName: "scout", spaceId: w.space.id))
    }

    @MainActor
    func restCall(_ w: ParityWorld, as p: Principal, secret: String) async -> BridgeError? {
        let method = w.registry["rest.call"]!
        do { _ = try await method.run(p, BridgeArgs(["url": "http://127.0.0.1:1/", "secret": secret])) }
        catch let e as BridgeError { return e }
        catch { return nil }
        return nil
    }

    @Test("a terminal companion is refused a secret it was not given")
    @MainActor
    func terminalCompanionRefused() async throws {
        let (w, p) = try terminalCompanion(secrets: ["weather"])
        #expect(w.state.companion(actingAs: p)?.displayName == "scout", "the terminal's companion is found")
        let e = await restCall(w, as: p, secret: "bank")
        #expect(e?.code == BridgeErrorCode.permissionDenied.wire, "got \(String(describing: e))")
    }

    @Test("a terminal companion gets past the gate for a secret it was given")
    @MainActor
    func terminalCompanionAllowed() async throws {
        let (w, p) = try terminalCompanion(secrets: ["weather"])
        // Past the gate, the secret is looked up; it does not exist in this keychain-free world.
        let e = await restCall(w, as: p, secret: "weather")
        #expect(e?.code != BridgeErrorCode.permissionDenied.wire, "got \(String(describing: e))")
    }

    @Test("a caller that is no companion is not scoped here (that is the per-caller grant, Phase 4)")
    @MainActor
    func plainPeerUnchanged() async throws {
        let (w, _) = try terminalCompanion(secrets: [])
        let e = await restCall(w, as: .peer(id: "someone-else", displayName: "x", spaceId: nil), secret: "bank")
        #expect(e?.code != BridgeErrorCode.permissionDenied.wire)
    }
}
