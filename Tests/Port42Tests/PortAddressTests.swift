import Testing
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
        _ = resolve("PANEL-ID-1", dbHas: { probed2 = true; return true })
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
}
