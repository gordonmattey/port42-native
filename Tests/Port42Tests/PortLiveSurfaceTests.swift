import Testing
import Foundation
@testable import Port42Lib

/// **A write to a port with no live surface is refused, and does not move the token** (2026-07-29).
///
/// GM measured the fourth instance of register §5's class: four `port.push` calls to a terminal whose
/// app had exited each returned `{"ok": true}` and advanced the activity token (`:0 → :1 → :3 → :5 →
/// :8`), and nothing ran. `touch /tmp/p42-alive` created no file. The port was in `ports.list`
/// throughout, because the DB row outlived the process.
///
/// The two earlier fixes in this class covered "target absent" (`port.rename` on a missing port) and
/// "argument wrong" (`port.push` with missing data). This is **"target present, argument fine, backing
/// process dead"**, which neither reaches.
///
/// **The token corruption is the serious part.** The counter moved, so a later CAS write is told it
/// raced a real mutation. A token claims *has this port changed since I looked*, and that claim is
/// false for any mutation that does not count — here a mutation counted that never happened. Locally
/// that costs a wasted retry; at slice-02 it makes CAS lie across the wire, undetectably, which is
/// the mechanism the whole wire half stakes its acceptance on.
@Suite("A write needs a live surface")
struct PortLiveSurfaceTests {

    /// The declaration is the contract, so it is asserted on the registry rather than on a comment.
    @MainActor
    func registry() throws -> [String: BridgeMethod] {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        return appState.bridgeRegistry
    }

    @Test("the verbs that DELIVER to a surface declare that they need one")
    @MainActor
    func deliveringVerbsDeclareIt() throws {
        let r = try registry()
        // push types into a pty, exec runs JS in a webview, move drags a live tile. All three are
        // meaningless against a port that is only a database row.
        #expect(r["port.push"]?.needsLiveSurface == true)
        #expect(r["port.exec"]?.needsLiveSurface == true)
        #expect(r["port.move"]?.needsLiveSurface == true)
    }

    @Test("the verbs that act on the STORED port do NOT require a live one")
    @MainActor
    func storedVerbsStayPermissive() throws {
        let r = try registry()
        // This is why the check is declared per verb instead of applied to every write.
        // `PortSurfaceKind.unknown` exists precisely so a parked or closed port stays addressable
        // for these, and refusing them would be a regression rather than a fix.
        #expect(r["port.restore"]?.needsLiveSurface == false,
                "restore is documented to work on a DB-only port")
        #expect(r["port.rename"]?.needsLiveSurface == false)
        #expect(r["port.update"]?.needsLiveSurface == false)
        #expect(r["port.patch"]?.needsLiveSurface == false)
    }

    @Test("a read never requires a live surface, because reading is not delivering")
    @MainActor
    func readsAreUnaffected() throws {
        let r = try registry()
        for name in ["port.getHtml", "port.getDom", "port.history", "ports.list"] {
            #expect(r[name]?.needsLiveSurface == false, "\(name) is a read")
            #expect(r[name]?.writesTarget == nil, "\(name) is a read")
        }
    }

    @Test("EVERY verb declaring needsLiveSurface also declares what it writes to")
    @MainActor
    func liveSurfaceImpliesAWrite() throws {
        // The flag is only consulted on the write path, so a verb that declares it without a
        // `writesTarget` has a requirement that is silently never enforced — the exact shape of bug
        // this seam exists to remove. Structural, so a verb added tomorrow cannot get it wrong.
        let r = try registry()
        let offenders = r.filter { $0.value.needsLiveSurface && $0.value.writesTarget == nil }
            .keys.sorted()
        #expect(offenders.isEmpty,
                "declares needsLiveSurface but no writesTarget, so it is never checked: \(offenders)")
    }

    // MARK: - Behavior, through the seam

    /// A port that exists only as a database row: exactly the state GM hit when Dev3's app exited.
    @MainActor
    func dbOnlyPortKey(_ appState: AppState) throws -> String {
        let udid = "dead-port-\(UUID().uuidString)"
        let bridge = PortBridge(appState: NSObject(), spaceId: nil)
        let panel = PortPanel(id: udid, udid: udid, html: "", bridge: bridge,
                              spaceId: nil, createdBy: nil, messageId: nil,
                              userTitle: "a terminal that died",
                              size: CGSize(width: 400, height: 300))
        try appState.db.savePortPanel(PersistedPortPanel(from: panel))
        // Deliberately NOT registered in `portWindows.panels` or `terminalControllers`: the row
        // exists and nothing is running behind it, which is precisely the state that produced the bug.
        return udid
    }

    @Test("pushing to a port with no live surface THROWS no_surface")
    @MainActor
    func pushToDeadPortIsRefused() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let udid = try dbOnlyPortKey(appState)
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")

        // Resolution must still FIND it — the bug was never that the port was missing.
        let ref = try #require(appState.resolvePortRef(udid))
        #expect(ref.kind == .unknown, "a DB-only port is what .unknown means")

        do {
            _ = try appState.applyWriteSideEffects(
                writesTarget: "id", needsLiveSurface: true,
                args: BridgeArgs(["id": udid, "data": "touch /tmp/p42-alive\n"]), principal: p)
            Issue.record("a push to a dead port was accepted")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.noSurface.rawValue,
                    "got \(e.code) — the caller's repair differs from not_found")
        }
    }

    @Test("THE POINT: a refused write does not move the token")
    @MainActor
    func refusedWriteLeavesTheTokenAlone() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let udid = try dbOnlyPortKey(appState)
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")

        let before = appState.portInput.token(for: udid)

        // Four pushes, as GM ran. Every one must be refused, and the counter must not budge —
        // it advanced :0 → :1 → :3 → :5 → :8 before this fix.
        //
        // **Each push carries a VALID `expect` token, and that is load-bearing.** Calibration caught
        // an earlier version of this test passing under a disabled liveness check: with no token the
        // write was refused by `token_required` first, so the counter stayed put for a reason that
        // had nothing to do with liveness, and the test proved nothing. Supplying the current token
        // clears both earlier gates, leaving liveness as the only thing that can refuse.
        for _ in 0..<4 {
            _ = try? appState.applyWriteSideEffects(
                writesTarget: "id", needsLiveSurface: true,
                args: BridgeArgs(["id": udid, "data": "x\n",
                                  PortActivity.expectParam: appState.portInput.token(for: udid)]),
                principal: p)
        }

        let note = "the token advanced for writes that never landed — a later CAS write would be "
            + "told it raced a mutation that never happened"
        #expect(appState.portInput.token(for: udid) == before, "\(note)")
    }

    @Test("a verb that does NOT need a live surface still writes to a DB-only port")
    @MainActor
    func storedWriteStillWorks() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let udid = try dbOnlyPortKey(appState)
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")
        let before = appState.portInput.token(for: udid)

        // `rename`/`restore` shape: no liveness requirement, so the seam lets it through and the
        // token moves as it should. Without this, "fix the lie" would have become "break restore".
        let key = try appState.applyWriteSideEffects(
            writesTarget: "id", needsLiveSurface: false,
            args: BridgeArgs(["id": udid, "title": "renamed",
                              PortActivity.expectParam: before]), principal: p)
        #expect(key == udid)
        #expect(appState.portInput.token(for: udid) != before, "a real write must count")
    }
}
