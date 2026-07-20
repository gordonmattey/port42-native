import Testing
import Foundation
@testable import Port42Lib

// companions.list should be SPACE-SCOPED by default (a companion acts within its space), not the
// whole-instance roster. An explicit "*" opts into global. Regression for the "assumed instance ==
// space" trap.

@Suite("CompanionsScope — companions.list defaults to the caller's space")
struct CompanionsScopeTests {

    @Test("Unscoped call defaults to the principal's space")
    func defaultsToPrincipalSpace() {
        #expect(Port42Members.resolveScope(requested: nil, principalSpace: "space-P",
                                           currentSpace: "space-C") == "space-P")
    }

    @Test("Unscoped with no principal space falls back to the current space")
    func fallsBackToCurrentSpace() {
        #expect(Port42Members.resolveScope(requested: nil, principalSpace: nil,
                                           currentSpace: "space-C") == "space-C")
    }

    @Test("An explicit space id is honored")
    func explicitSpace() {
        #expect(Port42Members.resolveScope(requested: "space-X", principalSpace: "space-P",
                                           currentSpace: "space-C") == "space-X")
    }

    @Test("\"*\" opts into the global roster (nil filter)")
    func explicitGlobal() {
        #expect(Port42Members.resolveScope(requested: "*", principalSpace: "space-P",
                                           currentSpace: "space-C") == nil)
    }
}
