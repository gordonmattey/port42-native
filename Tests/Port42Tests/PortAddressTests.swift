import Testing
import Foundation
@testable import Port42Lib

// Phase L0 of the local bus (docs/plan-port42-protocol-local-bus.md): the address grammar and the one
// resolution rule that replaces the five scattered id→port lookups. Pure, headless — no live surfaces.

@Suite("PortAddress")
struct PortAddressTests {

    @Test("parses the canonical port42://space/<s>/<p> form")
    func parsesCanonical() throws {
        let a = try #require(PortAddress.parse("port42://space/SPACE-1/PORT-9"))
        #expect(a.spaceId == "SPACE-1")
        #expect(a.portId == "PORT-9")
    }

    @Test("canonical round-trips a real address")
    func roundTrip() throws {
        let a = try #require(PortAddress.parse("port42://space/SPACE-1/PORT-9"))
        #expect(a.canonical == "port42://space/SPACE-1/PORT-9")
        #expect(PortAddress.parse(a.canonical) == a)
    }

    @Test("nil-space alias round-trips through `_` (canonical ∘ parse is identity)")
    func nilSpaceRoundTrips() throws {
        let bare = PortAddress(spaceId: nil, portId: "A1B2-UDID")
        #expect(bare.canonical == "port42://space/_/A1B2-UDID")
        let reparsed = try #require(PortAddress.parse(bare.canonical))
        #expect(reparsed == bare)          // `_` maps back to nil
        #expect(reparsed.spaceId == nil)
    }

    @Test("a bare id is not itself an address")
    func bareIdIsNotAnAddress() {
        #expect(PortAddress.parse("A1B2-UDID") == nil)
    }

    @Test("rejects a foreign scheme, a space invite (query, no path), and a wrong segment count")
    func rejectsNonAddresses() {
        #expect(PortAddress.parse("https://port42.ai/space/S/P") == nil)     // foreign scheme
        #expect(PortAddress.parse("port42://space?id=S&name=x") == nil)      // space invite form
        #expect(PortAddress.parse("port42://space/only-one") == nil)         // one segment
        #expect(PortAddress.parse("port42://agent/echo") == nil)             // wrong host
    }

    // MARK: - The instance segment (slice-02 milestone B, step 1)
    //
    // `port42://<peerID>/space/<space>/<port>`. The local two-segment form is UNCHANGED, which is
    // the whole point of having proved it locally first.
    //
    // **The trap, from §10b: a slot with one possible value is indistinguishable from a rename.**
    // Nothing in production can produce a peer id yet, so every test here uses a FOREIGN one
    // deliberately, exactly as `PortObjectGrantTests` had to for the grant object.

    static let peerA = "12D3KooWA1b2c3d4e5f6g7h8i9j0kLmNoPqRsTuVwXyZaBcDeFgH"
    static let peerB = "12D3KooWZ9y8x7w6v5u4t3s2r1q0pOnMlKjIhGfEdCbAzYxWvUtS"

    @Test("parses the peer-qualified form")
    func parsesPeerQualified() throws {
        let a = try #require(PortAddress.parse("port42://\(Self.peerA)/space/SPACE-1/PORT-9"))
        #expect(a.peerID == Self.peerA)
        #expect(a.spaceId == "SPACE-1")
        #expect(a.portId == "PORT-9")
    }

    @Test("the local form is unchanged and carries no peer")
    func localFormHasNoPeer() throws {
        let a = try #require(PortAddress.parse("port42://space/SPACE-1/PORT-9"))
        #expect(a.peerID == nil)
        #expect(a.canonical == "port42://space/SPACE-1/PORT-9", "the local rendering must not move")
    }

    @Test("a peer-qualified address round-trips, including with a nil space")
    func peerRoundTrips() throws {
        let a = try #require(PortAddress.parse("port42://\(Self.peerA)/space/SPACE-1/PORT-9"))
        #expect(a.canonical == "port42://\(Self.peerA)/space/SPACE-1/PORT-9")
        #expect(PortAddress.parse(a.canonical) == a)

        let noSpace = PortAddress(peerID: Self.peerA, spaceId: nil, portId: "A1B2-UDID")
        #expect(noSpace.canonical == "port42://\(Self.peerA)/space/_/A1B2-UDID")
        #expect(PortAddress.parse(noSpace.canonical) == noSpace)
    }

    @Test("two peers naming the same space and port are DIFFERENT addresses")
    func peersAreDistinct() throws {
        let a = try #require(PortAddress.parse("port42://\(Self.peerA)/space/S/P"))
        let b = try #require(PortAddress.parse("port42://\(Self.peerB)/space/S/P"))
        let local = try #require(PortAddress.parse("port42://space/S/P"))
        #expect(a != b, "the peer is part of the identity, not decoration")
        #expect(a != local)
        #expect(b != local)
    }

    @Test("only PortAddress.swift builds a port address, anywhere in the source tree")
    func oneAddressBuilder() throws {
        // The same rule `PortNotify.topic` carries, and for the same reason: the OUTPUT defect was a
        // topic built by hand with an interpolated optional, where each end was internally
        // consistent and only a rule about the string itself could reach it. An address now has a
        // peer segment, so a hand-built one is a second grammar waiting to disagree with this one.
        //
        // Invite links are a DISJOINT grammar — `port42://space?…` and `port42://agent?…` carry a
        // query and no path — so they are not addresses and are not caught here.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift"
            && url.lastPathComponent != "PortAddress.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///"), !t.hasPrefix("*") else { continue }
                if t.contains("port42://"), t.contains("/space/") {
                    offenders.append("\(url.lastPathComponent):\(n + 1)  \(t)")
                }
            }
        }
        #expect(offenders.isEmpty, "a port address built outside PortAddress.swift: \(offenders)")
    }

    @Test("rejects malformed peer-qualified forms")
    func rejectsMalformedPeerForms() {
        // A peer with no `space` marker, so the path shape is ambiguous.
        #expect(PortAddress.parse("port42://\(Self.peerA)/SPACE-1/PORT-9") == nil)
        // A peer and a space marker but no port.
        #expect(PortAddress.parse("port42://\(Self.peerA)/space/SPACE-1") == nil)
        // Too many segments.
        #expect(PortAddress.parse("port42://\(Self.peerA)/space/S/P/extra") == nil)
        // The literal host `space` is the LOCAL marker and can never be a peer id.
        #expect(PortAddress.parse("port42://space/space/S/P") == nil)
    }
}

@Suite("PortResolution")
struct PortResolutionTests {

    // A small fixture world.
    let terminals: [(id: String, name: String)] = [("TERM-1", "echo")]
    let panels: [PortCandidate] = [
        // id != udid, as it is for any post-migration port — the case that broke the single-id design.
        PortCandidate(id: "PANEL-ID-1", udid: "PANEL-UDID-1", messageId: "MSG-1",
                      title: "Pricing Calculator", portType: nil),
        PortCandidate(id: "BROWSER-ID-1", udid: "BROWSER-UDID-1", messageId: nil,
                      title: "Docs", portType: "browser"),
    ]
    let inlineIds: Set<String> = ["INLINE-1"]

    func resolve(_ s: String, dbHas: @escaping (String) -> Bool = { _ in false }) -> PortRef? {
        PortResolution.resolve(s, terminals: terminals, panels: panels,
                               inlineMessageIds: inlineIds, dbHas: dbHas)
    }

    @Test("resolves a terminal by id and by fuzzy name, canonicalizing to the id")
    func terminal() {
        #expect(resolve("TERM-1")?.kind == .terminal)
        #expect(resolve("ech")?.kind == .terminal)          // contains-match on companion name
        #expect(resolve("ech")?.id == "TERM-1")
    }

    @Test("terminal wins over web (precedence matches PortPushRoute)")
    func terminalWinsOverWeb() {
        let r = PortResolution.resolve("DUAL",
                                       terminals: [("DUAL", "dual")],
                                       panels: [PortCandidate(id: "DUAL", udid: "DUAL-UDID",
                                                              messageId: nil, title: "x", portType: nil)],
                                       inlineMessageIds: [], dbHas: { _ in false })
        #expect(r?.kind == .terminal)
    }

    @Test("a panel resolves by id, udid, messageId, and title — carrying the full identity")
    func panelIdentityTriple() {
        // The regression case: matching by udid must still surface panel.id (the webViews key).
        for needle in ["PANEL-ID-1", "PANEL-UDID-1", "MSG-1", "pricing"] {
            let r = resolve(needle)
            #expect(r?.kind == .web)
            #expect(r?.id == "PANEL-ID-1")        // webViews / management key
            #expect(r?.udid == "PANEL-UDID-1")    // DB key
            #expect(r?.messageId == "MSG-1")      // inline key
        }
    }

    @Test("a browser panel resolves .browser")
    func browserPanel() {
        #expect(resolve("BROWSER-UDID-1")?.kind == .browser)
        #expect(resolve("Docs")?.kind == .browser)
    }

    @Test("an inline-only bridge resolves .web with only a messageId")
    func inlineOnly() {
        let r = resolve("INLINE-1")
        #expect(r?.kind == .web)
        #expect(r?.messageId == "INLINE-1")
        #expect(r?.id == nil)
    }

    @Test("a DB-only udid resolves .unknown (honest) and is probed lazily")
    func dbOnly() {
        var probed = false
        let r = resolve("ARCHIVED-1", dbHas: { probed = true; return $0 == "ARCHIVED-1" })
        #expect(r?.kind == .unknown)
        #expect(r?.udid == "ARCHIVED-1")
        #expect(probed)   // the DB was consulted for this miss-on-live case

        // The common path (a live web port) must NOT touch the DB.
        var probed2 = false
        _ = resolve("PANEL-ID-1", dbHas: { _ in probed2 = true; return true })
        #expect(!probed2)
    }

    @Test("an unknown id resolves to nil")
    func unknown() {
        #expect(resolve("NOPE") == nil)
    }

    @Test("resolves a full address and carries its space")
    func fullAddress() {
        let r = resolve("port42://space/SPACE-7/PANEL-UDID-1")
        #expect(r?.kind == .web)
        #expect(r?.id == "PANEL-ID-1")
        #expect(r?.spaceId == "SPACE-7")
    }

    // MARK: - A peer-qualified address does not resolve to a local port (step 1)
    //
    // The resolver's job is to find a port HERE. An address naming another instance names a port
    // that is not here, and the honest answer is nil until the wire exists (milestone B step 3).
    // Without this, `port42://<someone-else>/space/S/PANEL-UDID-1` would silently resolve to OUR
    // panel of the same id and a caller would drive the wrong machine's port.

    @Test("an address naming ANOTHER peer does not resolve to a local port of the same id")
    func foreignPeerDoesNotResolveLocally() {
        let foreign = "port42://\(PortAddressTests.peerA)/space/SPACE-7/PANEL-UDID-1"
        #expect(resolve(foreign) == nil, "a remote address resolved to a local port")
        // The identical address without the peer still resolves, so the peer is what refused it.
        #expect(resolve("port42://space/SPACE-7/PANEL-UDID-1")?.id == "PANEL-ID-1")
    }

    @Test("an address naming THIS instance's own peer resolves locally")
    func ownPeerResolvesLocally() {
        let mine = "port42://\(PortAddressTests.peerA)/space/SPACE-7/PANEL-UDID-1"
        let r = PortResolution.resolve(mine, terminals: terminals, panels: panels,
                                       inlineMessageIds: inlineIds, dbHas: { _ in false },
                                       localPeerID: PortAddressTests.peerA)
        #expect(r?.id == "PANEL-ID-1", "our own peer id must not make a local port unreachable")
        #expect(r?.spaceId == "SPACE-7")
    }
}
