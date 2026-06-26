import Testing
import Foundation
@testable import Port42Lib

/// Locks the canonical space-member JSON shape that BOTH API surfaces (ToolExecutor + PortBridge)
/// emit via Port42Members.dict — so they can't drift again on member responses.
@Suite("Port42Members shaping")
struct Port42MembersTests {

    @Test("member dict has the full canonical shape, with owner namespacing")
    func memberDictShape() {
        let agent = SpaceMember(senderId: "a1", name: "claude14", type: "agent", owner: "gordon")
        let d = Port42Members.dict(agent)
        #expect(d["id"] as? String == "a1")
        #expect(d["name"] as? String == "claude14")
        #expect(d["type"] as? String == "agent")
        #expect(d["owner"] as? String == "gordon")
        #expect(d["qualifiedName"] as? String == "claude14@gordon")
    }

    @Test("human member (no owner) renders an empty owner and bare qualifiedName")
    func humanMemberShape() {
        let human = SpaceMember(senderId: "u1", name: "gordon", type: "human", owner: nil)
        let d = Port42Members.dict(human)
        #expect(d["type"] as? String == "human")
        #expect(d["owner"] as? String == "")            // nil owner → "" (stable JSON)
        #expect(d["qualifiedName"] as? String == "gordon")
        // The key set is fixed — both surfaces depend on exactly these fields.
        #expect(Set(d.keys) == ["id", "name", "type", "owner", "qualifiedName"])
    }
}
