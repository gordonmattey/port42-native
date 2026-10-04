import Testing
import Foundation
@testable import Port42Lib

// #238: a port reaches a port in another space only by a grant (docs/plan-cross-space-ports.md).
// The checks the plan names: not_found by default; a card on the first call; a see grant reads and is
// refused `port.push` as permission_denied; each right allows exactly its methods; revoking in Access
// takes effect at once; a fork or a share carries no grant; the space box gives see and use on every
// port in the space and never edit.

@Suite("Ports across spaces (#238)")
@MainActor
struct CrossSpacePortsTests {

    struct World {
        let w: ParityWorld
        let growth: Space
        let reader: String      // "Launch desk, small", in port42-app
        let desk: String        // "Launch desk", in port42-growth
        let drafts: String      // "Drafts", in port42-growth
        let p: Principal        // the reader's page

        var state: AppState { w.state }

        /// A write sends the port's token (CAS), as every writer does.
        @MainActor func token(_ id: String) -> String {
            state.portInput.token(for: state.resolvePortRef(id)?.key ?? id)
        }
    }

    func makeWorld() throws -> World {
        let w = try makeParityWorld(spaceName: "port42-app")
        let growth = Space.create(name: "port42-growth")
        try w.state.db.saveSpace(growth)
        w.state.spaces.append(growth)
        func port(_ title: String, _ space: String) throws -> String {
            let created = w.state.createPort(
                type: "web", title: title, html: "<title>\(title)</title><div>desk</div>", command: nil,
                cwd: nil, systemPrompt: nil, spaceId: space, createdBy: w.companion.id,
                createdByName: w.companion.displayName, presentation: "tiled")
            let id = try #require(created["id"] as? String)
            // No live page: nothing here needs one, and a WKWebView per port loads WebKit for the
            // suites that do (found by cosmic-hare: the full gate flaked on them with this suite in).
            w.state.portWindows.findPort(by: id).map { w.state.portWindows.stop($0.id) }
            return id
        }
        let reader = try port("Launch desk, small", w.space.id)
        let desk = try port("Launch desk", growth.id)
        let drafts = try port("Drafts", growth.id)
        let p = Principal.forPortBridge(createdBy: w.companion.id, messageId: reader, instanceFallback: "test",
                                        title: "Launch desk, small", spaceId: w.space.id)
        return World(w: w, growth: growth, reader: reader, desk: desk, drafts: drafts, p: p)
    }

    /// Run a call; if it raises a card, answer it (nil denies). Bounded: a call that raises no card
    /// finishes on its own, and the wait gives up after two seconds.
    func call(_ x: World, _ method: String, _ args: [String: Any], as p: Principal? = nil,
              answer: CrossSpaceChoice? = nil) async -> (value: BridgeValue?, error: BridgeError?, card: CrossSpaceAsk?) {
        final class Box { var done = false }
        let box = Box()
        let task = Task { @MainActor in
            defer { box.done = true }
            return try await x.state.runBridgeMethod(method, principal: p ?? x.p, args: BridgeArgs(args))
        }
        var card: CrossSpaceAsk?
        for _ in 0..<400 where !box.done {
            if let current = x.state.permissions.current {
                card = current.crossSpace
                x.state.permissions.resolveCurrent(granted: answer != nil, choice: answer)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        do { return (try await task.value, nil, card) } catch { return (nil, error as? BridgeError, card) }
    }

    func key(_ x: World, _ id: String) throws -> String { try #require(x.state.resolvePortRef(id)?.key) }

    /// The world's ports hold no live page (`makeWorld`), so this suite adds no WebKit load.
    @Test("the suite's ports run no page")
    func noLivePages() throws {
        let x = try makeWorld()
        for id in [x.reader, x.desk, x.drafts] {
            let panel = try #require(x.state.portWindows.findPort(by: id))
            #expect(x.state.portWindows.webViews[panel.id] == nil, "\(panel.title) still has a live page")
        }
    }

    @Test("ungranted stays not_found: the first call asks, and a no leaves it not_found")
    func defaultNotFound() async throws {
        let x = try makeWorld()
        let r = await call(x, "state.get", ["port": x.desk], answer: nil)
        let card = try #require(r.card, "the first call did not ask")
        // Found on dev8: the header named the port's creator, though the grant goes to the port.
        #expect(card.readerTitle == "Launch desk, small")
        #expect(card.sentence == "Launch desk, small (port42-app) wants to see Launch desk in port42-growth")
        #expect(r.error?.code == BridgeErrorCode.notFound.wire, "a no must look like a port that is not there")
        #expect(x.state.crossSpaceGrants().isEmpty, "a no was kept as a grant")
    }

    @Test("a port in another space is never reached by its title, and a port's own space asks nothing")
    func titleAndOwnSpace() async throws {
        let x = try makeWorld()
        let byTitle = await call(x, "state.get", ["port": "Launch desk"], answer: CrossSpaceChoice(rights: [.see], wholeSpace: false))
        #expect(byTitle.card == nil, "a title raised a card, so a page can probe another space by name")
        #expect(byTitle.error?.code == BridgeErrorCode.notFound.wire)

        let own = await call(x, "port.getHtml", ["id": x.reader])
        #expect(own.card == nil && own.error == nil, "reading a port in its own space asked")
    }

    @Test("a see grant reads the port, and port.push is refused as permission_denied naming use")
    func seeGrant() async throws {
        let x = try makeWorld()
        let first = await call(x, "state.get", ["port": x.desk], answer: CrossSpaceChoice(rights: [.see], wholeSpace: false))
        #expect(first.card != nil)
        #expect(first.error == nil, "a see grant did not let state.get through: \(String(describing: first.error))")

        for method in ["port.getHtml", "port.history", "port.console"] {
            let r = await call(x, method, ["id": x.desk])
            #expect(r.card == nil, "\(method) asked again after see was granted")
            #expect(r.error == nil, "\(method) refused with see granted: \(String(describing: r.error))")
        }
        let push = await call(x, "port.push", ["id": x.desk, "data": ["go": true]])
        #expect(push.card == nil, "a call needing more than was granted raised a second card")
        #expect(push.error?.code == BridgeErrorCode.permissionDenied.wire)
        #expect(push.error?.message.contains("'use'") == true, "the refusal does not name the right")
    }

    @Test("each right allows exactly its methods")
    func eachRight() async throws {
        let methods: [(String, RemoteRight, (World) -> [String: Any])] = [
            ("port.getHtml", .see, { ["id": $0.desk] }),
            ("state.get", .see, { ["port": $0.desk] }),
            ("chat.read", .see, { ["port": $0.desk] }),
            ("chat.post", .use, { ["port": $0.desk, "text": "approve"] }),
            ("port.rename", .edit, { ["id": $0.desk, "title": "Launch desk", "token": $0.token($0.desk)] }),
            ("port.fork", .fork, { ["id": $0.desk] }),
        ]
        for granted in [RemoteRight.see, .use, .edit, .fork] {
            let x = try makeWorld()
            x.state.grantCrossSpace(CrossSpaceChoice(rights: [granted], wholeSpace: false), for: ask(x, needs: granted))
            for (method, right, args) in methods {
                let r = await call(x, method, args(x))
                #expect(r.card == nil, "\(method) asked with \(granted) already granted")
                if right == granted {
                    #expect(r.error == nil, "\(method) refused with \(granted): \(String(describing: r.error))")
                } else {
                    #expect(r.error?.code == BridgeErrorCode.permissionDenied.wire,
                            "\(method) (needs \(right)) was not refused with only \(granted)")
                }
            }
        }
    }

    @Test("no right reaches a method outside the table: port.exec stays not_found")
    func outsideTheTable() async throws {
        let x = try makeWorld()
        x.state.grantCrossSpace(CrossSpaceChoice(rights: Set(CrossSpaceAsk.offered), wholeSpace: false), for: ask(x, needs: .see))
        for (method, args) in [("port.exec", ["id": x.desk, "js": "1"]),
                               ("port.manage", ["id": x.desk, "action": "focus"])] as [(String, [String: Any])] {
            let r = await call(x, method, args)
            #expect(r.card == nil)
            #expect(r.error?.code == BridgeErrorCode.notFound.wire, "\(method) reached a port in another space")
        }
    }

    @Test("a terminal in another space is never reached, whatever the port holds on it")
    func terminalNeverReached() async throws {
        let x = try makeWorld()
        // A terminal in the other space. Its panel says so; the grant covers it as fully as it can.
        let draftsKey = try key(x, x.drafts)
        let i = try #require(x.state.portWindows.panels.firstIndex { $0.udid == draftsKey })
        x.state.portWindows.panels[i].portType = "terminal"
        #expect(x.state.portWindows.findPort(by: draftsKey)?.portType == "terminal")
        let a = ask(x, needs: .see)
        x.state.grantCrossSpace(CrossSpaceChoice(rights: Set(CrossSpaceAsk.offered), wholeSpace: false),
                                for: CrossSpaceAsk(readerKey: a.readerKey, readerTitle: a.readerTitle,
                                                   readerSpace: a.readerSpace, targetKey: try key(x, x.drafts),
                                                   targetTitle: "Drafts", targetSpaceId: x.growth.id,
                                                   targetSpace: "port42-growth", needs: .see))
        for (method, args) in [("port.getHtml", ["id": x.drafts]), ("port.history", ["id": x.drafts]),
                               ("chat.read", ["port": x.drafts])] as [(String, [String: Any])] {
            let r = await call(x, method, args)
            #expect(r.card == nil, "\(method) asked about a terminal in another space")
            #expect(r.error?.code == BridgeErrorCode.notFound.wire, "\(method) reached a terminal in another space")
        }
    }

    @Test("a call admitted to one port in another space reaches that port and no other")
    func admissionIsOnePort() async throws {
        let x = try makeWorld()
        let desk = try key(x, x.desk)
        let admitted = x.p.reaching(desk)
        func notFound(_ what: String, _ body: () async throws -> Void) async {
            do { try await body(); Issue.record("\(what): a call admitted to the desk reached Drafts") } catch {
                #expect((error as? BridgeError)?.code == BridgeErrorCode.notFound.wire, "\(what): \(error)")
            }
        }
        // The admitted port itself passes every seam, so the refusals below are about the key.
        _ = try x.state.requireReadablePort(x.desk, by: admitted)
        _ = try x.state.requireReadableChat(x.desk, by: admitted)
        #expect(x.state.admitsCrossSpace(desk, by: admitted))

        // Every seam that admits by `admitsCrossSpace`, asked about the other port in that space.
        await notFound("requireReadablePort") { _ = try x.state.requireReadablePort(x.drafts, by: admitted) }
        await notFound("requireReadableChat") { _ = try x.state.requireReadableChat(x.drafts, by: admitted) }
        await notFound("the write seam") {
            try x.state.applyWriteSideEffects(writesTarget: "id", args: BridgeArgs(["id": x.drafts]), principal: admitted)
        }
        for (method, args) in [("state.get", ["port": x.drafts]), ("port.fork", ["id": x.drafts]),
                               ("port.getHtml", ["id": x.drafts])] as [(String, [String: Any])] {
            let m = try #require(x.w.registry[method])
            await notFound(method) { _ = try await m.run(admitted, BridgeArgs(args)) }
        }
        #expect(!x.state.admitsCrossSpace(try key(x, x.drafts), by: admitted))
        #expect(!x.state.admitsCrossSpace(desk, by: x.p), "a call the gate did not admit was admitted")
    }

    @Test("a port posting into another space wakes its companions only with wake_agents")
    func wakes() async throws {
        let x = try makeWorld()
        let desk = try key(x, x.desk)
        let admitted = x.p.reaching(desk)
        x.state.grantCrossSpace(CrossSpaceChoice(rights: [.use], wholeSpace: false), for: ask(x, needs: .use))
        #expect(!x.state.crossSpaceWakes(admitted, chat: desk), "use alone woke the other space's companions")
        x.state.grantCrossSpace(CrossSpaceChoice(rights: [.wakeAgents], wholeSpace: false), for: ask(x, needs: .use))
        #expect(x.state.crossSpaceWakes(admitted, chat: desk))
        #expect(x.state.crossSpaceWakes(x.p, chat: desk), "a post in a port's own space must wake as before")
    }

    @Test("revoking in Settings, Access takes effect on the next call")
    func revoke() async throws {
        let x = try makeWorld()
        _ = await call(x, "state.get", ["port": x.desk], answer: CrossSpaceChoice(rights: [.see, .use], wholeSpace: false))
        let row = try #require(x.state.crossSpaceGrants().first)
        #expect(row.reader == "Launch desk, small (port42-app)")
        #expect(row.target == "Launch desk in port42-growth")
        #expect(row.rights == [.see, .use])

        x.state.setCrossSpaceRights([.see], grantee: row.grantee, object: row.object)
        let narrowed = await call(x, "chat.post", ["port": x.desk, "text": "hi"])
        #expect(narrowed.error?.code == BridgeErrorCode.permissionDenied.wire, "unticking use did not take effect")

        x.state.setCrossSpaceRights([], grantee: row.grantee, object: row.object)
        let gone = await call(x, "state.get", ["port": x.desk], answer: nil)
        #expect(gone.card != nil, "after a revoke the next call should ask again")
        #expect(gone.error?.code == BridgeErrorCode.notFound.wire, "a revoked grant still reached the port")
    }

    @Test("a fork carries no grant, and a grant is never another machine's share")
    func forkAndShare() async throws {
        let x = try makeWorld()
        x.state.grantCrossSpace(CrossSpaceChoice(rights: [.see], wholeSpace: false), for: ask(x, needs: .see))
        let fork = try await x.state.runBridgeMethod("port.fork", principal: x.w.principal,
                                                     args: BridgeArgs(["id": x.reader, "space_id": x.w.space.id]))
        guard case let .object(o) = fork, case let .string(copy)? = o["id"] else {
            Issue.record("port.fork returned no id"); return
        }
        x.state.portWindows.findPort(by: copy).map { x.state.portWindows.stop($0.id) }
        let asCopy = Principal.forPortBridge(createdBy: x.w.companion.id, messageId: copy, instanceFallback: "test",
                                             title: "Launch desk, small (copy)", spaceId: x.w.space.id)
        let r = await call(x, "state.get", ["port": x.desk], as: asCopy, answer: nil)
        #expect(r.card != nil, "the copy did not have to ask: it inherited the original's grant")
        #expect(r.error?.code == BridgeErrorCode.notFound.wire)

        #expect(x.state.sharedPorts().isEmpty, "a cross-space grant was listed as shared with another machine")
        let guest = Principal.remote(peer: "guest-peer", displayName: "guest")
        do {
            try x.state.authorizeRemote("state.get", principal: guest, args: BridgeArgs(["port": try key(x, x.desk)]))
            Issue.record("a guest reached the port through a local port's grant")
        } catch {}
    }

    @Test("the space box gives see and use on every port in that space, and never edit")
    func spaceBox() async throws {
        let x = try makeWorld()
        let first = await call(x, "port.rename", ["id": x.desk, "title": "Launch desk", "token": x.token(x.desk)],
                               answer: CrossSpaceChoice(rights: [.see, .use, .edit], wholeSpace: true))
        #expect(first.error == nil, "edit on the port itself was not granted: \(String(describing: first.error))")

        let read = await call(x, "state.get", ["port": x.drafts])
        #expect(read.card == nil && read.error == nil, "the space box did not give see on another port there")
        let post = await call(x, "chat.post", ["port": x.drafts, "text": "signal"])
        #expect(post.card == nil && post.error == nil, "the space box did not give use on another port there")
        let rename = await call(x, "port.rename", ["id": x.drafts, "title": "mine now"])
        #expect(rename.error?.code == BridgeErrorCode.permissionDenied.wire, "the space box gave edit")

        let rows = x.state.crossSpaceGrants()
        let wide = try #require(rows.first { $0.object.hasPrefix("space:") })
        #expect(wide.target == "every port in port42-growth")
        #expect(wide.rights == [.see, .use] && wide.offered == [.see, .use])
        x.state.setCrossSpaceRights([.see, .use, .edit], grantee: wide.grantee, object: wide.object)
        let again = await call(x, "port.rename", ["id": x.drafts, "title": "mine now"])
        #expect(again.error?.code == BridgeErrorCode.permissionDenied.wire, "Access let edit onto a whole space")
    }

    @Test("the card offers see ticked and nothing stronger, the space box off, and coalesces")
    func card() async throws {
        #expect(CrossSpaceAsk.preset == [.see])
        #expect(CrossSpaceAsk.offered == [.see, .use, .edit, .wakeAgents, .fork])
        #expect(!CrossSpaceAsk.spaceWide.contains(.edit))
        #expect(CrossSpaceAsk.accessibilityLabel(.edit, needs: .use) == "Edit, change its code and name")
        #expect(CrossSpaceAsk.allowLabel([], wholeSpace: false) == "Allow, nothing ticked")
        #expect(CrossSpaceAsk.allowLabel([.see, .use], wholeSpace: true)
                == "Allow see, use, and see and use on every port in the space")

        let x = try makeWorld()
        let a = Task { @MainActor in try await x.state.runBridgeMethod("state.get", principal: x.p, args: BridgeArgs(["port": x.desk])) }
        let b = Task { @MainActor in try await x.state.runBridgeMethod("chat.post", principal: x.p, args: BridgeArgs(["port": x.desk, "text": "go"])) }
        for _ in 0..<400 where (x.state.permissions.current?.awaiterCount ?? 0) < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(x.state.permissions.pendingCount == 1, "two calls from one port to one target raised two cards")
        #expect(x.state.permissions.current?.asker == "Launch desk, small",
                "the card named \(x.state.permissions.current?.asker ?? "nobody"), not the port the grant goes to")
        x.state.permissions.resolveCurrent(granted: true, choice: CrossSpaceChoice(rights: [.see], wholeSpace: false))
        _ = try await a.value
        do { _ = try await b.value; Issue.record("chat.post went through with see only") } catch {
            #expect((error as? BridgeError)?.code == BridgeErrorCode.permissionDenied.wire)
        }
    }

    /// The pattern check CI keeps: every box on the cross-space card, its Allow, and the Access rows
    /// say what they do to VoiceOver, and the card holds VoiceOver while it is up. Dropping one fails
    /// here rather than leaving someone on VoiceOver with "checkbox, checkbox, Allow".
    @Test("the card and its Access rows keep their VoiceOver names (CI check)")
    func namesStayInPlace() throws {
        func source(_ file: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/Port42Lib/Views/\(file)"), encoding: .utf8)
        }
        let overlay = try source("ShellPermissionOverlay.swift")
        let start = try #require(overlay.range(of: "struct CrossSpaceCardBody: View {"))
        let card = String(overlay[start.lowerBound...])
        #expect(card.contains(".accessibilityLabel(CrossSpaceAsk.accessibilityLabel(right, needs: ask.needs))"),
                "a right's box lost its name")
        #expect(card.contains(".accessibilityLabel(CrossSpaceAsk.allowLabel(picked, wholeSpace: wholeSpace))"),
                "Allow no longer says what it gives")
        #expect(card.contains(".accessibilityLabel(\"\\(ask.spaceBoxLabel). See and use only.\")"),
                "the space box lost its name")
        #expect(card.contains(".keyboardShortcut(.cancelAction)"), "Esc no longer denies the card")
        #expect(!card.contains(".keyboardShortcut(.defaultAction)"), "Return must never allow a grant")
        #expect(overlay.contains(".accessibilityAddTraits(.isModal)"), "the card no longer holds VoiceOver")
        #expect(overlay.contains("Text(request.asker.uppercased())")
                && overlay.contains(".accessibilityLabel(\"Permission request from \\(request.asker)\")"),
                "the card's header no longer names the port the grant goes to")

        let access = try source("SignOutSheet.swift")
        #expect(access.contains(".accessibilityLabel(\"Revoke \\(row.reader) reaching \\(row.target)\")"),
                "a cross-space revoke is a bare \"revoke\" again")
    }

    @Test("while Port42 is locked nothing is asked and the call is told so")
    func locked() async throws {
        let x = try makeWorld()
        x.state.permissions.canPrompt = { false }
        let r = await call(x, "state.get", ["port": x.desk])
        #expect(r.error?.code == BridgeErrorCode.locked.wire)
    }

    func ask(_ x: World, needs: RemoteRight) -> CrossSpaceAsk {
        CrossSpaceAsk(readerKey: (try? key(x, x.reader)) ?? x.reader, readerTitle: "Launch desk, small",
                      readerSpace: "port42-app", targetKey: (try? key(x, x.desk)) ?? x.desk,
                      targetTitle: "Launch desk", targetSpaceId: x.growth.id, targetSpace: "port42-growth",
                      needs: needs)
    }
}
