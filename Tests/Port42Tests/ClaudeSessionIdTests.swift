import Testing
import Foundation
@testable import Port42Lib

// Step 3 of the command-companion cwd fix (docs/plan-companion-cwd.md): each command port gets a
// deterministic claude session id so companions sharing one space dir land on distinct
// transcripts, and a respawn resumes the same thread. Key: "<spaceId>:<companionId>" for saved
// companions; "<spaceId>:<panelId>" for ad-hoc port.create terminals (no companion). Derived via
// UUIDv5 so the id is a valid UUID (accepted by `claude --session-id`) and recomputable at spawn.

@Suite("ClaudeSessionId — deterministic per-(space,companion) session ids")
struct ClaudeSessionIdTests {

    let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!

    @Test("UUIDv5 matches the RFC 4122 reference vector (algorithm is correct)")
    func matchesRfcVector() {
        // Known vector: v5(DNS, "www.example.com") = 2ed6657d-e927-568b-95e1-2665a8aea6a2
        let got = ClaudeSessionId.uuidV5(namespace: dnsNamespace, name: "www.example.com")
        #expect(got.lowercased() == "2ed6657d-e927-568b-95e1-2665a8aea6a2")
    }

    @Test("Same (space, companion) is deterministic; the panel id is ignored when a companion is present")
    func deterministic() {
        let a = ClaudeSessionId.derive(spaceId: "space-A", companionId: "comp-1", panelId: "panel-X")
        let b = ClaudeSessionId.derive(spaceId: "space-A", companionId: "comp-1", panelId: "panel-Y")
        #expect(a == b)
    }

    @Test("Different companions in one space get distinct ids (the collision fix)")
    func distinctPerCompanion() {
        let a = ClaudeSessionId.derive(spaceId: "space-A", companionId: "comp-1", panelId: "p")
        let b = ClaudeSessionId.derive(spaceId: "space-A", companionId: "comp-2", panelId: "p")
        #expect(a != b)
    }

    @Test("The same companion in different spaces gets distinct ids")
    func distinctPerSpace() {
        let a = ClaudeSessionId.derive(spaceId: "space-A", companionId: "comp-1", panelId: "p")
        let b = ClaudeSessionId.derive(spaceId: "space-B", companionId: "comp-1", panelId: "p")
        #expect(a != b)
    }

    @Test("Ad-hoc (no companion) keys on the panel id")
    func adHocKeysOnPanel() {
        let adHoc = ClaudeSessionId.derive(spaceId: "space-A", companionId: nil, panelId: "panel-X")
        let byKey = ClaudeSessionId.uuidV5(namespace: ClaudeSessionId.namespace, name: "space-A:panel-X")
        #expect(adHoc == byKey)
        // distinct panels → distinct ids
        let other = ClaudeSessionId.derive(spaceId: "space-A", companionId: nil, panelId: "panel-Y")
        #expect(adHoc != other)
    }

    @Test("Output is a valid version-5 UUID (accepted by --session-id)")
    func isValidV5Uuid() {
        let id = ClaudeSessionId.derive(spaceId: "space-A", companionId: "comp-1", panelId: "p")
        let uuid = UUID(uuidString: id)
        #expect(uuid != nil)
        // version nibble (first char of the 3rd group) must be '5'
        let group = id.split(separator: "-")
        #expect(group.count == 5)
        #expect(group[2].first == "5")
    }

    @Test("Known-answer pin guards against namespace/algorithm drift")
    func knownAnswer() {
        let id = ClaudeSessionId.derive(spaceId: "space-A", companionId: "comp-1", panelId: "ignored")
        #expect(id == "c1e275f0-629f-596e-9c45-72e34a8b0289")
    }
}
