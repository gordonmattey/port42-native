import Testing
import Foundation
@testable import Port42Lib

// Auto-register CLI companion (docs/summer2026-todo.md): when a claude terminal fires SessionStart,
// register it only if its name isn't already a named roster companion (Maker/Critic own their
// identity); a plain-terminal codename is new, so it registers.

@Suite("AutoRegisterCompanion — the register-or-skip decision")
struct AutoRegisterCompanionTests {

    @Test("A name that is already a companion is NOT re-registered")
    func skipsExistingCompanion() {
        #expect(AppState.shouldAutoRegisterTerminal(name: "Maker",
                                                    existingCompanionNames: ["Maker", "Critic"]) == false)
    }

    @Test("A new codename registers")
    func registersNewName() {
        #expect(AppState.shouldAutoRegisterTerminal(name: "witty-lynx",
                                                    existingCompanionNames: ["Maker", "Critic"]) == true)
    }

    @Test("An empty name never registers")
    func skipsEmpty() {
        #expect(AppState.shouldAutoRegisterTerminal(name: "", existingCompanionNames: []) == false)
    }
}
