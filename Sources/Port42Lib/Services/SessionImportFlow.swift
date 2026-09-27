import Foundation

/// Bring running sessions into Port42 (docs/plan-session-import.md), step 3: the import itself. THE one
/// path for the first-run step, the ⌘K action and `sessions.import`.
public struct SessionImportResult: Equatable {
    public let request: SessionImport.Request
    public let spaceId: String
    public let companion: String
    public let portId: String?
}

@MainActor
extension AppState {

    /// Each session becomes a companion in its space whose terminal resumes it as a fork: Claude through
    /// the shim (`PORT42_FORK_FROM`: forked into the terminal's own pinned session on the first launch,
    /// that session resumed after), Codex through `codex fork <id>` (switched to `codex resume` of its
    /// fork once it reports it, `noteSessionId`). The originals are not touched. Spaces with a name
    /// already in use are reused, so a second import lands beside the first.
    @discardableResult
    func importSessions(_ requests: [SessionImport.Request], person: AppUser) throws -> [SessionImportResult] {
        var spaceIds: [String: String] = [:]
        var results: [SessionImportResult] = []
        for r in requests {
            let spaceId: String
            if let known = spaceIds[r.space] {
                spaceId = known
            } else if let existing = spaces.first(where: { $0.name == AppState.spaceName(r.space) }) {
                spaceId = existing.id
            } else {
                guard let made = createSpace(name: r.space, select: false) else {
                    throw BridgeError.badArg("could not make a space named '\(r.space)'")
                }
                spaceId = made.id
            }
            spaceIds[r.space] = spaceId

            var name = r.name, k = 2
            while companions.contains(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
                name = "\(r.name)-\(k)"; k += 1
            }
            var c = ShellNewCompanionView.makeCompanion(
                owner: person.id, name: name, cli: r.cli.rawValue, command: "", argsText: "",
                workingDir: r.cwd, prompt: "", hidden: false, secrets: [])
            switch r.cli {
            case .claude: c.envVars = ["PORT42_FORK_FROM": r.sessionId]
            case .codex: c.args = ["fork", r.sessionId]
            }
            let made = try createCompanion(c, spaceId: spaceId)
            let port = portWindows.panels.first { terminal($0.terminalConfig, isFor: made) }?.udid
            p42log("[Port42] imported %@ session %@ into '%@' as %@", r.cli.rawValue, r.sessionId, r.space, name)
            results.append(SessionImportResult(request: r, spaceId: spaceId, companion: name, portId: port))
        }
        return results
    }
}

@MainActor
func registerSessionImportMethods(into r: inout BridgeRegistry, appState: AppState) {
    r["sessions.find"] = BridgeMethod(permission: .terminal, paramNames: [], toolExposed: false,
        description: "The Claude Code and Codex sessions running on this Mac that Port42 did not start, each with its project, branch, title, last activity and the app it runs in, grouped into a space per project. What the first-run import and ⌘K 'bring in running sessions' offer.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, _ in
        let found = SessionImport.find(procs: SessionImport.probe(), home: NSHomeDirectory())
        let sel = SessionImport.Selection.initial(found)
        let iso = ISO8601DateFormatter()
        return .object([
            "sessions": .array(found.map { c in .object([
                "id": .string(c.sessionId), "cli": .string(c.cli.rawValue), "cwd": .string(c.cwd),
                "project": .string(c.project), "branch": c.branch.map { .string($0) } ?? .null,
                "title": .string(c.title), "last_active": .string(iso.string(from: c.lastActive)),
                "app": c.app.map { .string($0) } ?? .null, "ticked": .bool(sel.ticked.contains(c.sessionId)),
            ]) }),
            "groups": .array(sel.groups.map { g in .object(["name": .string(g.name), "sessions": .array(g.sessions.map { .string($0) })]) }),
        ])
    }

    r["sessions.import"] = BridgeMethod(permission: .terminal, paramNames: ["sessions"], toolExposed: false,
        description: "Bring running sessions into Port42 as forks: each becomes a companion in its space whose terminal starts with a copy of the whole conversation; the original is not touched and should then be closed. Each item: {id, cli, cwd, space, name}.",
        inputSchema: [
            "type": "object",
            "properties": ["sessions": ["type": "array", "description": "The sessions to bring in: {id, cli (claude|codex), cwd, space, name}.",
                                        "items": ["type": "object"]]],
            "required": ["sessions"],
        ]) { _, args in
        guard let person = appState.currentUser else { throw BridgeError.badArg("no signed-in person") }
        guard let items = args.dictionary["sessions"] as? [[String: Any]] else { throw BridgeError.missingArg("sessions") }
        let reqs: [SessionImport.Request] = try items.map { o in
            guard let id = o["id"] as? String, let cliName = o["cli"] as? String, let cli = SessionImport.CLI(rawValue: cliName),
                  let cwd = o["cwd"] as? String, let space = o["space"] as? String else {
                throw BridgeError.badArg("each session needs id, cli (claude or codex), cwd and space")
            }
            return SessionImport.Request(sessionId: id, cli: cli, cwd: cwd, space: space, name: (o["name"] as? String) ?? space)
        }
        let results = try appState.importSessions(reqs, person: person)
        return .object(["imported": .array(results.map { r in .object([
            "id": .string(r.request.sessionId), "space": .string(r.spaceId), "companion": .string(r.companion),
            "port": r.portId.map { .string($0) } ?? .null]) })])
    }
}
