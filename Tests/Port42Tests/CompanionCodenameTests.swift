import Testing
import Foundation
@testable import Port42Lib

// Auto-register CLI companion (docs/summer2026-todo.md): a claude terminal that isn't a named
// companion gets a deterministic, friendly codename seeded by its panel id — stable across
// respawn (a random-per-launch name would churn), distinct per seed, adjective-animal shape.

@Suite("CompanionCodename — deterministic friendly names")
struct CompanionCodenameTests {

    @Test("Same seed always yields the same name (stable across respawn)")
    func deterministic() {
        let seed = "70D3A348-46E4-4842-B614-3858424CDBD5"
        #expect(CompanionCodename.generate(seed: seed) == CompanionCodename.generate(seed: seed))
    }

    @Test("Different seeds yield different names (no collision for distinct panels)")
    func distinctSeeds() {
        let a = CompanionCodename.generate(seed: "panel-A")
        let b = CompanionCodename.generate(seed: "panel-B")
        #expect(a != b)
    }

    @Test("Shape is adjective-animal, lowercase, mention-safe (no spaces)")
    func shape() {
        let name = CompanionCodename.generate(seed: "panel-A")
        let parts = name.split(separator: "-")
        #expect(parts.count == 2)
        #expect(name == name.lowercased())
        #expect(!name.contains(" "))
    }

    @Test("Does not depend on String.hashValue (which is randomized per process)")
    func stableAcrossProcesses() {
        // A known seed pins a known output, so a switch to a per-run hash would break this.
        #expect(CompanionCodename.generate(seed: "port42") == "witty-lynx")
    }
}
