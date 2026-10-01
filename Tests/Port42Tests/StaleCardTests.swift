import Testing
import Foundation
@testable import Port42Lib

/// **A card answered after its caller gave up acts for nobody** (#247).
///
/// A gateway call that waited on a permission card timed out at the gateway, the card stayed on
/// screen, and a later Allow still applied the change (companions.update, companions.delete) for a
/// caller that was gone. Now a caller that gives up takes its ask with it: cancelling the waiting
/// task withdraws its place on the card, the gateway tells the app when a caller gives up, and the app
/// tells the gateway when a call is waiting on a person so it is kept open long enough to answer.
@Suite("A stale card acts for nobody (#247)")
@MainActor
struct StaleCardTests {

    final class Box<T> { var value: T?; init() {} }

    func until(_ cond: () -> Bool) async {
        for _ in 0..<400 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    let caller = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")

    // MARK: - The coordinator

    @Test("a caller that gives up withdraws its card, and a late Allow answers nobody")
    func cancelWithdraws() async {
        let c = PermissionCoordinator()
        let outcome = Box<PermissionOutcome>()
        let task = Task { @MainActor in outcome.value = await c.decide(.clipboard, from: self.caller) }
        await until { c.current != nil }
        #expect(c.current != nil, "the ask must raise a card")

        task.cancel()
        await until { outcome.value != nil }
        #expect(outcome.value == .cancelled)
        #expect(c.current == nil, "the card of a caller that gave up stayed on screen")
        c.resolveCurrent(granted: true)   // the late click
        #expect(outcome.value == .cancelled, "a late Allow reached a caller that was gone")
    }

    @Test("two overlapping asks share one card; one giving up leaves it for the other")
    func coalescedAwaiters() async {
        let c = PermissionCoordinator()
        let first = Box<PermissionOutcome>(), second = Box<PermissionOutcome>()
        let t1 = Task { @MainActor in first.value = await c.decide(.clipboard, from: self.caller, detail: "x") }
        let t2 = Task { @MainActor in second.value = await c.decide(.clipboard, from: self.caller, detail: "x") }
        await until { c.current?.awaiterCount == 2 }
        #expect(c.current?.awaiterCount == 2, "same caller, permission and detail must share one card")
        #expect(c.queued.isEmpty)

        t1.cancel()
        await until { first.value != nil }
        #expect(first.value == .cancelled)
        #expect(c.current?.awaiterCount == 1, "the card went although someone still waits on it")

        c.resolveCurrent(granted: true)
        await until { second.value != nil }
        #expect(second.value == .granted)
        _ = t2
    }

    @Test("a queued card whose only caller gives up leaves the queue")
    func queuedWithdrawn() async {
        let c = PermissionCoordinator()
        let other = Principal.peer(id: "other-\(UUID().uuidString)", displayName: "other")
        let a = Task { @MainActor in _ = await c.decide(.clipboard, from: other) }
        await until { c.current != nil }
        let gaveUp = Box<PermissionOutcome>()
        let b = Task { @MainActor in gaveUp.value = await c.decide(.screen, from: self.caller) }
        await until { c.queued.count == 1 }

        b.cancel()
        await until { gaveUp.value != nil }
        #expect(gaveUp.value == .cancelled)
        #expect(c.queued.isEmpty, "a card nobody waits on stayed in the queue")
        c.resolveCurrent(granted: false)
        _ = await a.value
    }

    // MARK: - The door

    final class Wire {
        var sent: [[String: Any]] = []
        func record(_ text: String) {
            if let d = text.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { sent.append(o) }
        }
        func frames(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
    }

    static func call(_ id: String, method: String, args: String = "{}") -> String {
        "{\"type\":\"call\",\"call_id\":\"\(id)\",\"sender_id\":\"local-http\",\"method\":\"\(method)\",\"args\":\(args),\"credential\":\"p42_tok\"}"
    }
    static func cancel(_ id: String) -> String {
        "{\"type\":\"cancel\",\"call_id\":\"\(id)\",\"sender_id\":\"local-http\"}"
    }

    @Test("a call waiting on a card tells the gateway it is pending, and a cancel withdraws the card")
    func doorPendingAndCancel() async {
        let wire = Wire(), c = PermissionCoordinator(), d = GatewayDoor()
        d.sendOverride = { wire.record($0) }
        let outcome = Box<PermissionOutcome>()
        d.onCallReceived = { _, _, _, _, _, _ in
            outcome.value = await c.decide(.clipboard, from: self.caller)
            return ["ok": true]
        }
        d.receive(Self.call("http-1", method: "clipboard.write"))
        await until { c.current != nil && !wire.frames("pending").isEmpty }
        #expect(wire.frames("pending").first?["call_id"] as? String == "http-1",
                "the gateway was not told the call waits on a person")

        d.receive(Self.cancel("http-1"))
        await until { outcome.value != nil }
        #expect(outcome.value == .cancelled)
        #expect(c.current == nil, "the gateway's cancel left the card up")
    }

    // MARK: - End to end: a late Allow does not act

    static let config = TerminalPortConfig(
        command: "/bin/zsh", args: [], startupCommand: "bash", cwd: "/tmp",
        spaceId: "space-1", spaceName: "Demo", companionName: "shell", createdBy: "u1",
        companionPrompt: "")

    @Test("a push whose caller gave up types nothing, even when the person clicks Allow later")
    func lateAllowDoesNotAct() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a headless AppState reads as locked (APP-16)
        let typed = Box<Int>(); typed.value = 0
        let controller = GhosttyTerminalController(panelId: "term-s", config: Self.config, post: { _ in })
        controller.bindSurface { _, done in typed.value! += 1; done() }
        controller.bindAliveProbe { true }
        appState.terminalControllers["term-s"] = controller

        let wire = Wire(), d = GatewayDoor()
        d.sendOverride = { wire.record($0) }
        let caller = self.caller
        d.onCallReceived = { _, _, method, input, _, _ in
            do { return try await appState.runBridgeMethod(method, principal: caller, args: BridgeArgs(input)).toJSONObject() }
            catch { return ["error": "\(error)"] }
        }
        let token = appState.portInput.token(for: "term-s")
        d.receive(Self.call("http-2", method: "port.push",
                            args: "{\"id\":\"term-s\",\"data\":\"rm -rf ~/x\\n\",\"token\":\"\(token)\"}"))
        await until { appState.permissions.current != nil }
        #expect(appState.permissions.current != nil, "the push must ask for .terminal; got \(wire.sent)")

        d.receive(Self.cancel("http-2"))         // the gateway gave up on the caller
        await until { appState.permissions.current == nil }
        appState.permissions.resolveCurrent(granted: true)   // the person clicks Allow, too late
        await until { !wire.frames("response").isEmpty }
        #expect(typed.value == 0, "a late Allow typed into the terminal for a caller that was gone")
        #expect(!appState.grants(grantee: caller.id, on: .port("term-s"), zone: nil).contains(.terminal),
                "a late Allow left a grant behind")
    }
}
