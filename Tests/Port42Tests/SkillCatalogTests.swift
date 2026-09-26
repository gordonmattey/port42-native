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

    /// A skill that teaches a call with a wrong argument name teaches a call that fails. Every
    /// `port42 <method> key=...` example in a SKILL.md must name a real method and only arguments
    /// that method declares (found writing them: `script=` for `source=`, `session=` for `sessionId=`).
    @Test("every port42 example in a skill names a real method and only its real arguments")
    func examplesAreReal() throws {
        let state = try makeParityWorld().state
        var declared: [String: Set<String>] = [:]
        for (name, m) in state.bridgeRegistry {
            let props = (m.inputSchema["properties"] as? [String: Any]).map { Set($0.keys) } ?? []
            declared[name] = props.union(m.paramNames).union(["token"])
        }
        for (name, m) in state.bridgeStreamRegistry {
            let props = (m.inputSchema["properties"] as? [String: Any]).map { Set($0.keys) } ?? []
            declared[name] = props.union(m.paramNames)
        }
        // port.create takes its options at the top level: every property of the options object.
        if let opts = ((state.bridgeRegistry["port.create"]?.inputSchema["properties"] as? [String: Any])?.keys) {
            declared["port.create", default: []].formUnion(opts)
        }
        var problems: [String] = []
        for skill in SkillCatalog.skills.map(\.name) {
            let md = try String(contentsOf: Self.pluginRoot().appendingPathComponent("skills/\(skill)/SKILL.md"), encoding: .utf8)
            for line in md.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                guard t.hasPrefix("port42 "), !t.hasPrefix("port42 <method>"), !t.hasPrefix("port42 help") else { continue }
                let words = t.components(separatedBy: " ").filter { !$0.isEmpty }
                guard words.count >= 2 else { continue }
                let method = words[1].trimmingCharacters(in: CharacterSet(charactersIn: "`.,"))
                guard let allowed = declared[method] else { problems.append("\(skill): no method \(method)"); continue }
                for w in words.dropFirst(2) where w.contains("=") {
                    let key = String(w.prefix { $0 != "=" && $0 != ":" })
                    if !key.isEmpty && !allowed.contains(key) { problems.append("\(skill): \(method) has no argument '\(key)'") }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("the ports skill's manual.md is the port manual, and help ports prints the skill then the manual")
    func manualIsFresh() throws {
        _ = try makeParityWorld()
        let url = Self.pluginRoot().appendingPathComponent("skills/port42-ports/manual.md")
        if ProcessInfo.processInfo.environment["PORT42_REGEN_SKILLS"] == "1" {
            try SkillCatalog.manual().write(to: url, atomically: true, encoding: .utf8)
        }
        #expect((try? String(contentsOf: url, encoding: .utf8)) == SkillCatalog.manual(), "manual.md is stale")
        let help = SkillCatalog.helpPorts()
        #expect(help.hasPrefix("# Making and changing ports"), "help ports must lead with the ports skill")
        #expect(help.contains(SkillCatalog.manual()))
    }

    /// Everything today's brief teaches must have a home once the brief shrinks (decision 2): the
    /// load-bearing phrases of `CompanionProtocol.chats`, found in some skill.
    @Test("every rule the brief teaches today has a home in a skill")
    func briefRulesHaveAHome() throws {
        let all = try SkillCatalog.skills.map { s in
            try String(contentsOf: Self.pluginRoot().appendingPathComponent("skills/\(s.name)/SKILL.md"), encoding: .utf8)
        }.joined(separator: "\n").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for phrase in ["port42 whoami", "exact name", "port42 chat.read port=", "port42 chat.post port=",
                       "port42 ports.list", "work on it rather than making a second", "keep the details in the port's chat",
                       "port42 port.patch", "=@file", "port42 port.console", "port42 port.getDom",
                       "token_required", "stale_write", "current", "port42 companions.watch",
                       "Do not also post it", "never guess", "another tool's token"] {
            #expect(all.localizedCaseInsensitiveContains(phrase), "no skill says: \(phrase)")
        }
    }

    @Test("each SKILL.md stays short: it is read whole when it loads")
    func sizeBudget() throws {
        for skill in SkillCatalog.skills.map(\.name) {
            let bytes = try Data(contentsOf: Self.pluginRoot().appendingPathComponent("skills/\(skill)/SKILL.md")).count
            #expect(bytes <= 6_000, "\(skill)/SKILL.md is \(bytes) bytes; the budget is 6,000")
        }
    }
}
