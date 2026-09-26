import Foundation

/// `/imagine` (docs/plan-imagine.md): one line from a person becomes a small team (a lead and two
/// engineers) that builds a port in its chat until the lead reports DONE.
///
/// Port42 runs no model (D9), so nothing here interprets the line. These are fixed texts with
/// variables: the agents' generated codenames, the person's name, their line verbatim, a title taken
/// from it, and the version budget. Turning the line into a vision is the lead's first job.
public enum Imagine {

    public static let defaultVersions = 5
    public static let maxVersions = 20

    /// What a person typed, understood.
    public enum Command: Equatable {
        case start(line: String, versions: Int)
        /// `/imagine --versions N` with no line: set the budget of the team in this space.
        case budget(versions: Int)
        case stop
    }

    /// `/imagine <line>`, `/imagine --versions N <line>`, `/imagine --versions N` or `/imagine stop`.
    /// Nil for anything else, which is posted as text.
    public static func parse(_ input: String) -> Command? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased() == "/imagine" || t.lowercased().hasPrefix("/imagine ") else { return nil }
        var rest = String(t.dropFirst("/imagine".count)).trimmingCharacters(in: .whitespaces)
        if rest.lowercased() == "stop" { return .stop }
        var versions = defaultVersions
        if rest.hasPrefix("--versions") {
            let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let n = Int(parts[1]), n >= 1 else { return nil }
            versions = min(n, maxVersions)
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

    /// The lead's role, its system prompt for the whole session.
    public static func leadRole() -> String {
        """
        You lead an imagine team. You own the vision and the version budget. You do not build: you set \
        the vision, split the work between your engineers so they never edit the same part, check each \
        version works (its console and DOM), and decide the next step. Work in the port's chat; answer \
        the person in the space's chat in one line. Stop at DONE.
        """
    }

    /// An engineer's role, its system prompt for the whole session.
    public static func engineerRole(lead: String) -> String {
        """
        You are an engineer on an imagine team led by @\(lead). Build what the lead gives you in the \
        port, only your part. Check it works before you say so, then report in the port's chat to \
        @\(lead): what you changed and what you checked.
        """
    }

    /// The first message, to the lead. The person's line goes in verbatim.
    ///
    /// ONLY THE LEAD IS @MENTIONED. An @mention delivers, so a brief that named the engineers with @
    /// reached all three, and on Dev4 the first CLI to start (a Codex engineer) wrote the vision and
    /// ran the team. The engineers are named plainly; the lead hands them work with @.
    public static func brief(line: String, person: String, lead: String, eng1: String, eng2: String,
                             title: String, versions: Int) -> String {
        """
        @\(lead) /imagine from \(person): "\(line)"
        You lead two engineers, \(eng1) and \(eng2) (hand them work with @ and their name). Make one web \
        port titled '\(title)' that realizes this, in at most \(versions) versions.
        1. Reply here in one line saying what you are going for, then write the vision in 3 to 5 lines \
        in the port's chat.
        2. Have \(eng1) make v1. For each later version, give both engineers concrete, non-overlapping \
        next steps toward the vision, check the result, and push further.
        3. When the vision is met or the budget is spent, post in the port's chat a message that starts \
        with DONE and says what the port now is, and one line here.
        """
    }

    /// The writes that make a version of a port, and so spend the budget.
    public static let versionWrites: Set<String> = ["port.update", "port.patch"]

    /// Is this write past the team's budget? Only the team's own writes count against it, only while
    /// the team runs, and only once the port already has `versions` versions.
    public static func overBudget(team: ImagineTeam, writer: String, versionsSoFar: Int) -> Bool {
        team.stoppedAt == nil && team.isMember(writer) && versionsSoFar >= team.versions
    }

    /// Told to the lead when the team's write that reaches the budget lands.
    public static func budgetSpent(lead: String, versions: Int) -> String {
        "@\(lead) that was version \(versions) of \(versions), the budget for this port. Further writes by the team are refused. Check the port and post DONE."
    }

    /// Posted in the space when a team stops. Bare names, so it wakes nobody.
    public static func stopped(_ team: ImagineTeam) -> String {
        "The imagine team (\(team.members.joined(separator: ", "))) has stopped and is gone. The port and its chats stay."
    }
}

/// The team a space was imagined with: for stop and the version budget.
public struct ImagineTeam: Equatable {
    public let spaceId: String
    public let lead: String
    public let eng1: String
    public let eng2: String
    public let title: String
    public var versions: Int
    public let startedAt: Date
    public var stoppedAt: Date?

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
        let title = Imagine.title(from: line)
        guard let space = createSpace(name: title, select: testCommand == nil) else {
            throw BridgeError.badArg("could not make a space for '\(title)'")
        }
        let taken = Set(companions.map { $0.displayName.lowercased() })
        var names: [String] = []
        while names.count < 3 {
            let n = CompanionCodename.generate(seed: UUID().uuidString)
            if !taken.contains(n.lowercased()) && !names.contains(n) { names.append(n) }
        }
        let (lead, eng1, eng2) = (names[0], names[1], names[2])
        let codex = ClaudeCodeSetup.findBinary("codex") != nil
        let seats: [(name: String, cli: String, role: String)] = [
            (lead, "claude", Imagine.leadRole()),
            (eng1, "claude", Imagine.engineerRole(lead: lead)),
            (eng2, codex ? "codex" : "claude", Imagine.engineerRole(lead: lead)),
        ]
        for seat in seats {
            let c = ShellNewCompanionView.makeCompanion(
                owner: person.id, name: seat.name, cli: testCommand == nil ? seat.cli : "custom",
                command: testCommand ?? "", argsText: "", workingDir: "", prompt: seat.role,
                hidden: false, secrets: [])
            try createCompanion(c, spaceId: space.id)
        }
        let team = ImagineTeam(spaceId: space.id, lead: lead, eng1: eng1, eng2: eng2, title: title,
                               versions: min(max(versions, 1), Imagine.maxVersions), startedAt: Date())
        try db.saveImagineTeam(team)
        let brief = Imagine.brief(line: line, person: person.displayName, lead: lead, eng1: eng1, eng2: eng2,
                                  title: title, versions: team.versions)
        _ = try await runBridgeMethod("chat.post",
                                      principal: .human(id: person.id, displayName: person.displayName, spaceId: space.id),
                                      args: BridgeArgs(["port": space.id, "text": brief]))
        return team
    }

    /// Stop the team imagined in a space: close its terminals, drop its watches and remove its
    /// companions. The port and the chats stay.
    ///
    /// REMOVED, not only taken out of the space. A mention reaches any companion that exists and
    /// re-adds it to the space, so on Dev4 a stopped team came back within minutes: one member's
    /// last reply @mentioned another, which respawned its terminal. `deleteCompanion` is not used,
    /// because it also closes the ports a companion made, and the port is what the person keeps.
    @discardableResult
    func stopImagine(spaceId: String) throws -> ImagineTeam {
        guard var team = try db.imagineTeam(spaceId: spaceId) else {
            throw BridgeError(code: .notFound, message: "no imagine team in space '\(spaceId)'", details: ["space": spaceId])
        }
        // Stopping again is allowed and cleans up whatever of the team still exists.
        let first = team.stoppedAt == nil
        for name in team.members {
            for panel in portWindows.panels
            where panel.terminalConfig?.companionName.caseInsensitiveCompare(name) == .orderedSame {
                portWindows.close(panel.id)
            }
            guard let c = companions.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            companionWatches.removeAll(companionId: c.id)
            try db.removeAllSpacesForAgent(c.id)
            try db.deleteAgent(id: c.id)
        }
        companions = try db.getAllAgents()
        refreshSpaceCompanions()
        guard first else { return team }
        team.stoppedAt = Date()
        try db.saveImagineTeam(team)
        _ = try postToChat(key: spaceId, text: Imagine.stopped(team),
                           from: .peer(id: ChatRouting.port42SenderId, displayName: "port42", spaceId: spaceId))
        return team
    }

    /// What a person typed into a chat: `/imagine …` runs the command and posts nothing; anything
    /// else is posted as the person. THE one path for every chat input.
    func submitChatInput(key: String, text: String, testCommand: String? = nil) async throws {
        guard let cmd = Imagine.parse(text) else { return try await postToChatAsPerson(key: key, text: text) }
        let space = spaceOfChat(key)
        try await runImagine(cmd, spaceId: space, testCommand: testCommand)
    }

    /// Run a parsed /imagine command. `spaceId` is where stop and the budget apply (the chat's space,
    /// or the current one from ⌘I); a start makes its own space.
    func runImagine(_ cmd: Imagine.Command, spaceId: String?, testCommand: String? = nil) async throws {
        switch cmd {
        case .start(let line, let versions):
            guard let person = currentUser else { throw BridgeError.badArg("no signed-in person to imagine for") }
            try await startImagine(line: line, versions: versions, person: person, testCommand: testCommand)
        case .stop:
            guard let spaceId else { throw BridgeError.badArg("/imagine stop works in the space the team was imagined in") }
            try stopImagine(spaceId: spaceId)
        case .budget(let n):
            guard let spaceId else { throw BridgeError.badArg("/imagine --versions works in the space the team was imagined in") }
            let team = try setImagineBudget(spaceId: spaceId, versions: n)
            _ = try postToChat(key: spaceId, text: "The imagine budget is now \(team.versions) versions.",
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
        team.versions = min(max(versions, 1), Imagine.maxVersions)
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

    func imagineVersionCount(_ ref: PortRef) -> Int {
        guard let udid = ref.udid else { return 0 }
        return (try? db.fetchPortVersions(portUdid: udid).count) ?? 0
    }

    /// Before a write: refuse it past the budget, with its own code, before its token moves.
    func imagineBudgetGate(method: String, args: BridgeArgs, principal: Principal) throws {
        guard let (team, ref) = imagineBudgetTarget(method: method, args: args, principal: principal) else { return }
        let n = imagineVersionCount(ref)
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
              team.stoppedAt == nil, imagineVersionCount(ref) == team.versions, let key = PortRef.key(ref) else { return }
        _ = try? postToChat(key: key, text: Imagine.budgetSpent(lead: team.lead, versions: team.versions),
                            from: .peer(id: ChatRouting.port42SenderId, displayName: "port42", spaceId: team.spaceId))
    }
}

@MainActor
func registerImagineMethods(into r: inout BridgeRegistry, appState: AppState) {
    r["imagine.start"] = BridgeMethod(permission: .terminal, paramNames: ["line", "versions"],
        description: "Start an imagine team: from one line, a new space with a lead and two engineers (their terminals on its desktop) who build a web port for it in its chat, in at most `versions` versions (default \(Imagine.defaultVersions)), until the lead posts DONE. Returns the space, the team's names, the port title and the budget. The same as ⌘I or typing /imagine in a chat.",
        inputSchema: [
            "type": "object",
            "properties": [
                "line": ["type": "string", "description": "What to make, in the person's words."],
                "versions": ["type": "integer", "description": "The version budget (default \(Imagine.defaultVersions), at most \(Imagine.maxVersions))."],
            ],
            "required": ["line"],
        ]) { _, args in
        guard let person = appState.currentUser else { throw BridgeError.badArg("no signed-in person to imagine for") }
        let line = try args.requireString("line").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw BridgeError.badArg("line is empty") }
        let team = try await appState.startImagine(line: line, versions: args.int("versions") ?? Imagine.defaultVersions,
                                                   person: person)
        return .object(["space": .string(team.spaceId), "lead": .string(team.lead), "eng1": .string(team.eng1),
                        "eng2": .string(team.eng2), "title": .string(team.title), "versions": .int(team.versions)])
    }

    r["imagine.stop"] = BridgeMethod(permission: nil, paramNames: ["space"],
        description: "Stop the imagine team in a space: its terminals close and it leaves the space; the port and the chats stay. The same as typing /imagine stop in that space's chat.",
        inputSchema: [
            "type": "object",
            "properties": ["space": ["type": "string", "description": "The space the team was imagined in (imagine_start returns it)."]],
            "required": ["space"],
        ]) { _, args in
        let team = try appState.stopImagine(spaceId: try args.requireString("space"))
        return .object(["space": .string(team.spaceId), "stopped": .array(team.members.map { .string($0) })])
    }

    r["imagine.budget"] = BridgeMethod(permission: nil, paramNames: ["space", "versions"],
        description: "Set the version budget of the imagine team in a space, for example to let it keep going after the budget is spent. The team's writes to its port past the budget are refused with budget_spent. The same as typing /imagine --versions N in that space's chat.",
        inputSchema: [
            "type": "object",
            "properties": [
                "space": ["type": "string", "description": "The space the team was imagined in."],
                "versions": ["type": "integer", "description": "The new budget, in versions of the port (at most \(Imagine.maxVersions))."],
            ],
            "required": ["space", "versions"],
        ]) { _, args in
        guard let n = args.int("versions") else { throw BridgeError.missingArg("versions") }
        let team = try appState.setImagineBudget(spaceId: try args.requireString("space"), versions: n)
        return .object(["space": .string(team.spaceId), "versions": .int(team.versions)])
    }
}
