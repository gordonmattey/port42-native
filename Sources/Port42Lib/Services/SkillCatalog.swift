import Foundation

/// Port42's knowledge as skills (nautilus Phase 5): five skills, by task, each a hand-written
/// `SKILL.md` and a `reference.md` generated from the registry. They ship as one plugin folder in the
/// app bundle (`Skills/port42-skills`), which Claude loads per session with `--plugin-dir` and Codex
/// finds in the `skills/` of the instance's own Codex home.
///
/// Every registry method belongs to exactly one skill. A method added without a home fails
/// `SkillCatalogTests`, so a skill cannot silently stop covering the API.
public enum SkillCatalog {

    public struct Skill: Equatable {
        public let name: String
        /// What the skill is for, in the words that make an agent load it.
        public let title: String
    }

    public static let skills: [Skill] = [
        Skill(name: "port42", title: "calling Port42: the command, identity, chats and errors"),
        Skill(name: "port42-ports", title: "making and changing ports"),
        Skill(name: "port42-compose", title: "ports feeding ports, and reacting to them"),
        Skill(name: "port42-team", title: "working with other agents"),
        Skill(name: "port42-devices", title: "the computer: terminal, screen, camera, audio, files, browser, automation, network"),
    ]

    /// The one skill a method belongs to, or nil when it has no home yet (a gate failure).
    public static func skill(for method: String) -> String? {
        let ns = method.contains(".") ? String(method[..<method.firstIndex(of: ".")!]) : method
        switch method {
        case "whoami", "help", "companions.list", "companions.get":
            return "port42"
        case "port.publish", "port.subscribe", "timer.every", "timer.after", "timer.cancel":
            return "port42-compose"
        case "companions.create", "companions.remove", "companions.update", "companions.delete", "companions.watch", "companions.unwatch", "companions.watches", "companions.invoke":
            return "port42-team"
        case "presentation":
            return "port42-ports"
        default: break
        }
        switch ns {
        case "imagine", "sessions":
            return "port42-team"
        case "user", "space", "chat", "presence":
            return "port42"
        case "port", "ports", "storage", "state", "invite", "remote":
            return "port42-ports"
        case "audio", "automation", "browser", "camera", "clipboard", "fs", "notify", "rest", "screen", "terminal", "ai":
            return "port42-devices"
        default:
            return nil
        }
    }

    /// The ports skill's `manual.md`: the port manual (`ports-context.txt`, rendered). One source: the
    /// same text `port42 help ports` prints after the skill itself.
    @MainActor
    public static func manual() -> String { AppState.portsContext }

    /// A skill's `SKILL.md` without its frontmatter, as bundled.
    public static func body(of skill: String) -> String? {
        guard let url = pluginURL?.appendingPathComponent("skills/\(skill)/SKILL.md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What `port42 help ports` prints: the ports skill, then the full manual.
    @MainActor
    public static func helpPorts() -> String {
        [body(of: "port42-ports"), manual()].compactMap { $0 }.joined(separator: "\n\n---\n\n")
    }

    /// Where the plugin lives in the running app.
    public static var pluginURL: URL? {
        Bundle.port42.url(forResource: "port42-skills", withExtension: nil)
    }

    /// One skill's `reference.md`: its methods, each with what it does, its arguments, its permission
    /// and how to call it with the `port42` command. Deterministic, so the committed file can be
    /// checked against it.
    @MainActor
    public static func reference(for skill: String, state: AppState) -> String {
        struct Entry { let name: String; let params: [String]; let permission: PortPermission?
                       let description: String; let streaming: Bool; let schema: [String: Any] }
        var entries: [Entry] = []
        for (name, m) in state.bridgeRegistry where Self.skill(for: name) == skill {
            entries.append(Entry(name: name, params: m.paramNames, permission: m.permission,
                                 description: m.description, streaming: false, schema: m.inputSchema))
        }
        for (name, m) in state.bridgeStreamRegistry where Self.skill(for: name) == skill {
            entries.append(Entry(name: name, params: m.paramNames, permission: m.permission,
                                 description: m.description, streaming: true, schema: m.inputSchema))
        }
        let title = skills.first { $0.name == skill }?.title ?? skill
        var out = "# \(skill) reference\n\n"
        out += "The methods for \(title). Generated from the running app's registry; do not edit.\n"
        out += "Call any of them with `port42 <method> key=value` (`key:=<json>` for numbers, booleans,\n"
        out += "arrays and objects; `key=@<file>` for a file's contents).\n"
        for e in entries.sorted(by: { $0.name < $1.name }) {
            out += "\n## \(e.name)\n\n"
            var tags: [String] = []
            if let p = e.permission { tags.append("needs the \(p.rawValue) permission") }
            if e.streaming { tags.append("streaming: over the gateway's WebSocket, not the command") }
            if !tags.isEmpty { out += "_\(tags.joined(separator: "; "))_\n\n" }
            if !e.description.isEmpty { out += e.description + "\n" }
            let params = renderSchemaParams(e.schema)
            if !params.isEmpty { out += "\n" + params }
            // A stream cannot come back through the command, so it gets no command example.
            if !e.streaming {
                let example = (["port42", e.name] + e.params.filter { $0 != "options" }.map { "\($0)=…" })
                    .joined(separator: " ")
                out += "\n    \(example)\n"
            }
        }
        return out
    }
}
