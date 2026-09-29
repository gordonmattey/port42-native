import Foundation

/// `/imagine` (docs/plan-imagine.md): one line from a person becomes a small team (a lead and two
/// engineers) that builds a port in its chat until the lead reports DONE.
///
/// A BOOTSTRAP (GM, 2026-09-26). It makes the space, the port (a placeholder, so it and its chat exist
/// from the first message), the three companions with their roles and the brief, and gets out of the
/// way: from then on they are ordinary companions in a space, managed like
/// any other. Nothing here closes a terminal or removes a companion, ever. The one thing it keeps
/// doing is the version budget, which bounds the team's token spend.
///
/// Port42 runs no model (D9), so nothing here interprets the line. These are fixed texts with
/// variables: the agents' generated codenames, the person's name, their line verbatim, a title taken
/// from it, and the version budget. Turning the line into a vision is the lead's first job.
public enum Imagine {

    /// Versions, not rounds: a round is not something Port42 can see. 10 (GM, 2026-09-26) lets a team of
    /// three land about three rounds, since each engineer's patch is a version.
    public static let defaultVersions = 10
    // No upper bound (GM, 2026-09-29: "there is no limit to improvement"). The budget is the person's
    // to set, as high as they like; it was capped at 20 and a higher --versions was cut to 20 silently.
    // 0 is NO LIMIT: the team's writes are never refused. 10 stays the default for a new team.

    /// Whether a budget limits anything: 0 (or less) is no limit.
    public static func limits(_ versions: Int) -> Bool { versions > 0 }

    /// A budget in words, for chat and briefs.
    public static func describe(_ versions: Int) -> String {
        limits(versions) ? "\(versions) versions" : "no version limit"
    }

    /// What a person typed, understood.
    public enum Command: Equatable {
        case start(line: String, versions: Int)
        /// `/imagine --versions N` with no line: set the budget of the team in this space.
        case budget(versions: Int)
    }

    /// `/imagine <line>`, `/imagine --versions N <line>` or `/imagine --versions N`. Nil for anything
    /// else, which is posted as text. A bare `/imagine stop` is nil too, so it never starts a team
    /// building "stop" (there is no stop: a team is ordinary companions once started).
    public static func parse(_ input: String) -> Command? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased() == "/imagine" || t.lowercased().hasPrefix("/imagine ") else { return nil }
        var rest = String(t.dropFirst("/imagine".count)).trimmingCharacters(in: .whitespaces)
        if rest.lowercased() == "stop" { return nil }
        var versions = defaultVersions
        if rest.hasPrefix("--versions") {
            let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let n = Int(parts[1]), n >= 0 else { return nil }
            versions = n
            rest = parts.count == 3 ? String(parts[2]) : ""
            if rest.trimmingCharacters(in: .whitespaces).isEmpty { return .budget(versions: versions) }
        }
        let line = rest.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : .start(line: line, versions: versions)
    }

    /// The port's title, from the line: whitespace collapsed, at most 60 characters, cut at a word.
    public static func title(from line: String) -> String {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + " " + w
            if next.count > 60 { break }
            out = next
        }
        return out.isEmpty ? String(line.prefix(60)) : out
    }

    /// A short space name from the line (GM, 2026-09-27: spaces were the line's first 60 characters,
    /// typos and all): its first few meaningful words, the asking and the filler dropped.
    /// "a starfield you can steer with the mouse" → "starfield steer mouse".
    public static func spaceName(from line: String) -> String {
        let lead = ["i want you to", "i want", "can you", "could you", "please", "make me", "make",
                    "build me", "build", "create", "give me", "imagine", "show me", "write"]
        var t = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for p in lead where t.hasPrefix(p + " ") { t = String(t.dropFirst(p.count + 1)); changed = true }
        }
        let filler: Set<String> = ["a", "an", "the", "that", "which", "you", "can", "could", "with", "of", "for",
                                   "to", "and", "or", "on", "in", "my", "me", "i", "it", "is", "are", "be",
                                   "so", "by", "from", "as", "at", "your", "our", "some", "into", "using"]
        let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !filler.contains($0) && $0.count > 1 }
        let picked = words.prefix(3).joined(separator: " ")
        return picked.isEmpty ? title(from: line) : picked
    }

    /// The team's names, by role, after the space's first word, so the terminals, the mentions and the
    /// presence line say who does what (GM, 2026-09-27: codenames like "calm-moth" said nothing).
    /// A name already taken gets a number.
    public static func teamNames(for space: String, taken: Set<String>) -> (lead: String, eng1: String, eng2: String) {
        let base = space.split { !$0.isLetter && !$0.isNumber }.first.map(String.init)?.lowercased() ?? "team"
        func free(_ n: String) -> String {
            var name = n, k = 2
            while taken.contains(name.lowercased()) { name = "\(n)-\(k)"; k += 1 }
            return name
        }
        return (free(base + "-lead"), free(base + "-eng-1"), free(base + "-eng-2"))
    }

    /// The CLI an imagine team runs on: the one the person chose, while it is installed; else the first
    /// installed; else the choice as it stands (the terminal then says it is missing).
    public static func teamCLI(chosen: String?, installed: [String]) -> String {
        if let chosen, installed.contains(chosen) { return chosen }
        return installed.first ?? chosen ?? "claude"
    }

    /// The lead's role, its system prompt for the whole session.
    ///
    /// Checking means what a person would see. On Dev4 a lead passed a v1 on a clean console and a
    /// full DOM while its canvas drew nothing at all (a NaN in its steering). And a team waited forever
    /// on an engineer whose turn ended without a report, so the lead asks after a silent one.
    public static func leadRole() -> String {
        """
        You lead an imagine team. You own the vision and the version budget. You do not build: you set \
        the vision, split the work between your engineers so they never edit the same part, check each \
        version works, and decide the next step. Check what a person would see: its error count \
        (port_console level=count, reading the errors only if there are any), and for anything drawn, \
        its pixels (count the lit pixels of the canvas with port_exec); no errors and a full DOM can \
        still be a black screen. If an engineer has not reported back, ask them \
        where they are. The space's chat, where the person follows the team, holds the vision, one line \
        per version and DONE. Run the work on the port in the port's chat: hand-offs, reports and \
        checks. Never post into another companion's terminal chat. Stop at DONE.
        """
    }

    /// An engineer's role, its system prompt for the whole session.
    public static func engineerRole(lead: String) -> String {
        """
        You are an engineer on an imagine team led by @\(lead). Build what the lead gives you in the \
        port, only your part. Check it works as a person would see it (its error count with \
        port_console level=count, and for anything drawn, its pixels) before you say so. Work on the port happens in the port's chat. End every \
        turn with a message to @\(lead) there, even when the work is not done: what you changed, what \
        you checked, what is left. A turn that ends without one leaves the team waiting. Never post \
        into another companion's terminal chat.
        """
    }

    /// The first message, to the lead. The person's line goes in verbatim.
    ///
    /// ONLY THE LEAD IS @MENTIONED. An @mention delivers, so a brief that named the engineers with @
    /// reached all three, and on Dev4 the first CLI to start (a Codex engineer) wrote the vision and
    /// ran the team. The engineers are named plainly; the lead hands them work with @.
    ///
    /// THE PORT IS NAMED, WITH ITS ID. It is made at bootstrap, so the work can move to its chat from
    /// the start. Before, the port and its chat did not exist until v1, every exchange began in the
    /// space's chat, and replies (which go back to the chat that asked) kept it there (Dev4, run 5).
    public static func brief(line: String, person: String, lead: String, eng1: String, eng2: String,
                             title: String, port: String, versions: Int) -> String {
        """
        @\(lead) /imagine from \(person): "\(line)"
        You lead two engineers, \(eng1) and \(eng2) (hand them work with @ and their name). The port is \
        already made: '\(title)', id \(port). Build in it, never a second one; it holds a placeholder \
        until v1. Realize this \(Imagine.limits(versions) ? "in at most \(versions) versions" : "with no version limit").
        1. Reply here in the space's chat with the vision, in 3 to 5 lines.
        2. Run the versions in the port's chat (port42 chat.post port=\(port)): have \(eng1) make v1 \
        there, then for each later version give both engineers concrete, non-overlapping next steps, \
        check the result, and push further. Here, post one line per version.
        3. When the vision is met or the budget is spent, post here a message that starts with DONE and \
        says what the port now is.
        """
    }

    /// The port's first version, made at bootstrap: it names what is coming.
    public static func placeholder(title: String, line: String) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        return """
        <title>\(esc(title))</title>
        <meta name="version" content="0">
        <div style="height:100vh;display:flex;align-items:center;justify-content:center;flex-direction:column;gap:8px;font:13px ui-monospace,monospace;opacity:.7">
        <div>an imagine team is building this</div><div style="opacity:.6">\(esc(line))</div></div>
        """
    }

    /// The writes that make a version of a port, and so spend the budget.
    public static let versionWrites: Set<String> = ["port.update", "port.patch"]

    /// Is this write past the team's budget? Only the team's own writes count against it, and only
    /// once the port already has `versions` versions.
    ///
    /// `versionsSoFar` counts the team's versions: on the port made at bootstrap, its placeholder is
    /// not one of them.
    public static func overBudget(team: ImagineTeam, writer: String, versionsSoFar: Int) -> Bool {
        team.isMember(writer) && limits(team.versions) && versionsSoFar >= team.versions
    }

    /// Told to the lead when the team's write that reaches the budget lands.
    public static func budgetSpent(lead: String, versions: Int) -> String {
        "@\(lead) that was version \(versions) of \(versions), the budget for this port. Further writes by the team are refused. Check the port and post DONE."
    }

}

/// The team a space was imagined with: for the version budget.
public struct ImagineTeam: Equatable {
    public let spaceId: String
    public let lead: String
    public let eng1: String
    public let eng2: String
    public let title: String
    public var versions: Int
    public let startedAt: Date
    /// The port made at bootstrap (its udid); nil for a team started before ports were pre-made.
    public var port: String? = nil

    public var members: [String] { [lead, eng1, eng2] }

    public func isMember(_ name: String) -> Bool {
        members.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

@MainActor
extension AppState {

    /// Start an imagine team for a line. THE one path: ⌘I, `/imagine` in a chat and `imagine.start`.
    ///
    /// A space named from the line, three agents with generated codenames (a Claude lead, a Claude
    /// engineer, and a Codex engineer when Codex is installed), each with its role as its prompt and
    /// its terminal on the desktop, then the brief posted as the person. Messages wait for each
    /// agent's CLI to be ready, so the brief can go at once.
    ///
    /// `testCommand` replaces the agents' CLIs with a headless command, so tests start no terminal.
    @discardableResult
    func startImagine(line: String, versions: Int = Imagine.defaultVersions, person: AppUser,
                      testCommand: String? = nil) async throws -> ImagineTeam {
        let title = Imagine.title(from: line)          // the port keeps the fuller title
        var roomName = Imagine.spaceName(from: line), k = 2
        let spaceNames = Set(spaces.map { $0.name.lowercased() })
        while spaceNames.contains(AppState.spaceName(roomName)) { roomName = Imagine.spaceName(from: line) + " \(k)"; k += 1 }
        guard let space = createSpace(name: roomName, select: testCommand == nil) else {
            throw BridgeError.badArg("could not make a space for '\(title)'")
        }
        let taken = Set(companions.map { $0.displayName.lowercased() })
        let (lead, eng1, eng2) = Imagine.teamNames(for: roomName, taken: taken)
        // The port first, so the brief can name it and the work has a chat from the start.
        let made = try await runBridgeMethod("port.create",
                                             principal: .human(id: person.id, displayName: person.displayName, spaceId: space.id),
                                             args: BridgeArgs(["type": "web", "title": title, "space_id": space.id,
                                                               "html": Imagine.placeholder(title: title, line: line)]))
        guard case .object(let o) = made, case .string(let portId)? = o["id"] else {
            throw BridgeError(code: .methodFailed, message: "could not make the port for '\(title)'")
        }
        // The whole team runs on the agent the person chose (GM, 2026-09-27: a person who picked Codex
        // got two Claude agents, which they may not even have). Not a mix because a second one exists.
        let cli = Imagine.teamCLI(chosen: preferredCLI,
                                  installed: ["claude", "codex"].filter { ClaudeCodeSetup.findBinary($0) != nil })
        let seats: [(name: String, cli: String, role: String)] = [
            (lead, cli, Imagine.leadRole()),
            (eng1, cli, Imagine.engineerRole(lead: lead)),
            (eng2, cli, Imagine.engineerRole(lead: lead)),
        ]
        for seat in seats {
            let c = ShellNewCompanionView.makeCompanion(
                owner: person.id, name: seat.name, cli: testCommand == nil ? seat.cli : "custom",
                command: testCommand ?? "", argsText: "", workingDir: "", prompt: seat.role,
                hidden: false, secrets: [])
            try createCompanion(c, spaceId: space.id)
        }
        let team = ImagineTeam(spaceId: space.id, lead: lead, eng1: eng1, eng2: eng2, title: title,
                               versions: max(versions, 0), startedAt: Date(), port: portId)
        try db.saveImagineTeam(team)
        let brief = Imagine.brief(line: line, person: person.displayName, lead: lead, eng1: eng1, eng2: eng2,
                                  title: title, port: portId, versions: team.versions)
        _ = try await runBridgeMethod("chat.post",
                                      principal: .human(id: person.id, displayName: person.displayName, spaceId: space.id),
                                      args: BridgeArgs(["port": space.id, "text": brief]))
        return team
    }

    /// What a person typed into a chat: `/imagine …` runs the command and posts nothing; anything
    /// else is posted as the person. THE one path for every chat input.
    func submitChatInput(key: String, text: String, testCommand: String? = nil) async throws {
        guard let cmd = Imagine.parse(text) else { return try await postToChatAsPerson(key: key, text: text) }
        let space = spaceOfChat(key)
        try await runImagine(cmd, spaceId: space, testCommand: testCommand)
    }

    /// Run a parsed /imagine command. `spaceId` is where the budget applies (the chat's space,
    /// or the current one from ⌘I); a start makes its own space.
    func runImagine(_ cmd: Imagine.Command, spaceId: String?, testCommand: String? = nil) async throws {
        switch cmd {
        case .start(let line, let versions):
            guard let person = currentUser else { throw BridgeError.badArg("no signed-in person to imagine for") }
            try await startImagine(line: line, versions: versions, person: person, testCommand: testCommand)
        case .budget(let n):
            guard let spaceId else { throw BridgeError.badArg("/imagine --versions works in the space the team was imagined in") }
            let team = try setImagineBudget(spaceId: spaceId, versions: n)
            _ = try postToChat(key: spaceId, text: "The imagine budget is now \(Imagine.describe(team.versions)).",
                               from: .peer(id: ChatRouting.port42SenderId, displayName: "port42", spaceId: spaceId))
        }
    }

    /// The space a chat belongs to: the space itself, or the space of the port whose chat it is.
    func spaceOfChat(_ key: String) -> String? {
        if spaces.contains(where: { $0.id == key }) || ((try? db.getAllSpaces()) ?? []).contains(where: { $0.id == key }) {
            return key
        }
        return portWindows.panels.first { $0.id == key || $0.udid == key }?.spaceId ?? currentSpace?.id
    }

    /// Set the version budget of the team imagined in a space (it may be raised after it is spent).
    @discardableResult
    func setImagineBudget(spaceId: String, versions: Int) throws -> ImagineTeam {
        guard var team = try db.imagineTeam(spaceId: spaceId) else {
            throw BridgeError(code: .notFound, message: "no imagine team in space '\(spaceId)'", details: ["space": spaceId])
        }
        team.versions = max(versions, 0)
        try db.saveImagineTeam(team)
        return team
    }

    /// The team whose budget a write would spend: a version-making write, by a member, to a port in
    /// the team's space. Nil for every other write, which is nearly all of them.
    func imagineBudgetTarget(method: String, args: BridgeArgs, principal: Principal) -> (ImagineTeam, PortRef)? {
        guard Imagine.versionWrites.contains(method), principal.kind != .human, principal.kind != .port,
              let raw = args.string("id"), let ref = resolvePortRef(raw),
              let space = portWindows.panels.first(where: { $0.id == ref.id || ($0.udid == ref.udid && ref.udid != nil) })?.spaceId,
              let team = try? db.imagineTeam(spaceId: space), team.isMember(principal.displayName)
        else { return nil }
        return (team, ref)
    }

    /// The team's versions of a port: on the port made at bootstrap, not counting its placeholder.
    func imagineVersionCount(_ ref: PortRef, team: ImagineTeam) -> Int {
        guard let udid = ref.udid else { return 0 }
        let all = (try? db.fetchPortVersions(portUdid: udid).count) ?? 0
        return udid == team.port ? max(0, all - 1) : all
    }

    /// Before a write: refuse it past the budget, with its own code, before its token moves.
    func imagineBudgetGate(method: String, args: BridgeArgs, principal: Principal) throws {
        guard let (team, ref) = imagineBudgetTarget(method: method, args: args, principal: principal) else { return }
        let n = imagineVersionCount(ref, team: team)
        guard Imagine.overBudget(team: team, writer: principal.displayName, versionsSoFar: n) else { return }
        throw BridgeError(
            code: .budgetSpent,
            message: "This port has \(n) versions, the imagine team's budget of \(team.versions) is spent. "
                   + "Tell @\(team.lead); the lead posts DONE, or asks the person to raise it (/imagine --versions N in the space).",
            details: ["versions": String(n), "budget": String(team.versions), "lead": team.lead])
    }

    /// After a write landed: when it was the version that reached the budget, tell the lead.
    func imagineBudgetNotice(method: String, args: BridgeArgs, principal: Principal) {
        guard let (team, ref) = imagineBudgetTarget(method: method, args: args, principal: principal),
              Imagine.limits(team.versions),
              imagineVersionCount(ref, team: team) == team.versions, let key = PortRef.key(ref) else { return }
        _ = try? postToChat(key: key, text: Imagine.budgetSpent(lead: team.lead, versions: team.versions),
                            from: .peer(id: ChatRouting.port42SenderId, displayName: "port42", spaceId: team.spaceId))
    }
}

@MainActor
func registerImagineMethods(into r: inout BridgeRegistry, appState: AppState) {
    r["imagine.start"] = BridgeMethod(permission: .terminal, paramNames: ["line", "versions"],
        description: "Start an imagine team: from one line, a new space with its port (a placeholder until v1) and a lead and two engineers (their terminals on its desktop) who build that port, in at most `versions` versions (default \(Imagine.defaultVersions)), until the lead posts DONE. Returns the space, the port, the team's names, the port title and the budget. The same as ⌘I or typing /imagine in a chat.",
        inputSchema: [
            "type": "object",
            "properties": [
                "line": ["type": "string", "description": "What to make, in the person's words."],
                "versions": ["type": "integer", "description": "The version budget (default \(Imagine.defaultVersions); no upper limit; 0 is no limit at all)."],
            ],
            "required": ["line"],
        ]) { _, args in
        guard let person = appState.currentUser else { throw BridgeError.badArg("no signed-in person to imagine for") }
        let line = try args.requireString("line").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw BridgeError.badArg("line is empty") }
        let team = try await appState.startImagine(line: line, versions: args.int("versions") ?? Imagine.defaultVersions,
                                                   person: person)
        return .object(["space": .string(team.spaceId), "port": .string(team.port ?? ""), "lead": .string(team.lead),
                        "eng1": .string(team.eng1), "eng2": .string(team.eng2), "title": .string(team.title),
                        "versions": .int(team.versions)])
    }

    r["imagine.budget"] = BridgeMethod(permission: nil, paramNames: ["space", "versions"],
        description: "Set the version budget of the imagine team in a space, for example to let it keep going after the budget is spent. The team's writes to its port past the budget are refused with budget_spent. The same as typing /imagine --versions N in that space's chat.",
        inputSchema: [
            "type": "object",
            "properties": [
                "space": ["type": "string", "description": "The space the team was imagined in."],
                "versions": ["type": "integer", "description": "The new budget, in versions of the port: any number, or 0 (or leave it out) for no limit."],
            ],
            "required": ["space"],
        ]) { _, args in
        let n = args.int("versions") ?? 0   // missing is no limit
        let team = try appState.setImagineBudget(spaceId: try args.requireString("space"), versions: n)
        return .object(["space": .string(team.spaceId), "versions": .int(team.versions)])
    }
}
