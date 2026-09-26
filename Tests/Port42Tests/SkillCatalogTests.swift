import Testing
import Foundation
@testable import Port42Lib

// Port42's skills (nautilus Phase 5). Every registry method belongs to exactly one skill, and each
// skill's reference.md is generated from the registry, so a skill cannot describe a method that no
// longer exists or miss one that was added.
//
// Regenerate after a registry change, then read the diff:
//   PORT42_REGEN_SKILLS=1 swift test --filter SkillCatalogTests
@Suite("Skills cover the registry")
@MainActor
struct SkillCatalogTests {

    static func pluginRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib/Skills/port42-skills")
    }

    @Test("every registry method has exactly one skill")
    func everyMethodHasAHome() throws {
        let state = try makeParityWorld().state
        let names = Array(state.bridgeRegistry.keys) + Array(state.bridgeStreamRegistry.keys)
        let homeless = names.filter { SkillCatalog.skill(for: $0) == nil }.sorted()
        #expect(homeless.isEmpty, "methods with no skill: \(homeless). Give each a home in SkillCatalog.skill(for:)")
        let known = Set(SkillCatalog.skills.map(\.name))
        let unknown = names.compactMap { SkillCatalog.skill(for: $0) }.filter { !known.contains($0) }
        #expect(unknown.isEmpty, "methods mapped to a skill that does not exist: \(unknown)")
    }

    @Test("each skill's committed reference equals the one generated from the registry")
    func referencesAreFresh() throws {
        let state = try makeParityWorld().state
        for skill in SkillCatalog.skills.map(\.name) {
            let generated = SkillCatalog.reference(for: skill, state: state)
            let url = Self.pluginRoot().appendingPathComponent("skills/\(skill)/reference.md")
            if ProcessInfo.processInfo.environment["PORT42_REGEN_SKILLS"] == "1" {
                try generated.write(to: url, atomically: true, encoding: .utf8)
            }
            let committed = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            #expect(committed == generated, "\(skill)/reference.md is stale: PORT42_REGEN_SKILLS=1 swift test --filter SkillCatalogTests")
        }
    }

    @Test("every skill folder exists with a SKILL.md whose name matches")
    func foldersMatch() throws {
        for skill in SkillCatalog.skills.map(\.name) {
            let md = try String(contentsOf: Self.pluginRoot().appendingPathComponent("skills/\(skill)/SKILL.md"), encoding: .utf8)
            #expect(md.hasPrefix("---\nname: \(skill)\n"), "\(skill)/SKILL.md must open with its name")
        }
    }
}
