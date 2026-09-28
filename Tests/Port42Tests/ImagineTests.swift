import Testing
import Foundation
@testable import Port42Lib

// /imagine (docs/plan-imagine.md): fixed texts with variables, and the command's parser.
@Suite("Imagine: texts and parser")
struct ImagineTests {

    @Test("the parser: a line, a budget; anything else, and a bare stop, is text")
    func parse() {
        #expect(Imagine.parse("/imagine a shader that reacts to music") == .start(line: "a shader that reacts to music", versions: Imagine.defaultVersions))
        #expect(Imagine.parse("  /imagine --versions 3 a clock  ") == .start(line: "a clock", versions: 3))
        #expect(Imagine.parse("/imagine --versions 99 x") == .start(line: "x", versions: Imagine.maxVersions))
        #expect(Imagine.parse("/imagine stop") == nil, "there is no stop, and it must not start a team building \"stop\"")
        #expect(Imagine.parse("/imagine --versions 8") == .budget(versions: 8), "no line: the budget of this space's team")
        #expect(Imagine.parse("/imagine") == nil, "no line, nothing to build")
        #expect(Imagine.parse("/imagine --versions nope x") == nil)
        #expect(Imagine.parse("/imagined world") == nil, "only the command, not a word that starts with it")
        #expect(Imagine.parse("let's /imagine this") == nil)
    }

    @Test("the title comes from the line, capped at a word")
    func title() {
        #expect(Imagine.title(from: "a shader   that reacts\nto music") == "a shader that reacts to music")
        let long = Imagine.title(from: String(repeating: "word ", count: 30))
        #expect(long.count <= 60 && !long.hasSuffix(" ") && long.hasSuffix("word"))
    }

    @Test("the brief fills every variable and keeps the line verbatim")
    func brief() {
        let line = "a shader that reacts to music, \"loud\" & bright"
        let b = Imagine.brief(line: line, person: "gordon", lead: "swift-pika", eng1: "merry-wren",
                              eng2: "merry-koi", title: "a shader that reacts to music", port: "P-1", versions: 5)
        #expect(b.hasPrefix("@swift-pika /imagine from gordon: \"\(line)\""))
        #expect(b.contains("You lead two engineers, merry-wren and merry-koi"))
        #expect(MentionParser.extractMentions(from: b).map { $0.lowercased() } == ["@swift-pika"],
                "the brief must @mention only the lead, or it reaches the engineers too")
        #expect(b.contains("already made: 'a shader that reacts to music', id P-1"))
        #expect(b.contains("in at most 5 versions"))
        #expect(b.contains("have merry-wren make v1"))
        #expect(b.contains("starts with DONE"))
        #expect(b.contains("Reply here in the space's chat") && b.contains("Run the versions in the port's chat (port42 chat.post port=P-1)"),
                "the vision in the space's chat, the work in the port's chat, named by id (GM)")
        #expect(!b.contains("{"), "an unfilled variable")
    }

    @Test("roles: the lead does not build; an engineer reports to its lead by name")
    func roles() {
        #expect(Imagine.leadRole().contains("You do not build"))
        #expect(Imagine.leadRole().contains("Stop at DONE"))
        #expect(Imagine.leadRole().contains("pixels") && Imagine.leadRole().contains("black screen"),
                "the lead must check what a person sees, not only the console and DOM")
        #expect(Imagine.leadRole().contains("ask them where they are"))
        for role in [Imagine.leadRole(), Imagine.engineerRole(lead: "swift-pika")] {
            #expect(role.contains("port's chat") && role.contains("Never post into another companion's terminal chat"))
        }
        let e = Imagine.engineerRole(lead: "swift-pika")
        #expect(e.contains("led by @swift-pika") && e.contains("to @swift-pika"))
    }

    @Test("start: a space from the line, three agents in it with their roles, the team recorded, the brief posted as the person")
    @MainActor
    func start() async throws {
        let w = try makeParityWorld()
        let person = try #require(w.state.currentUser)
        let team = try await w.state.startImagine(line: "a clock made of light", versions: 3, person: person,
                                                  testCommand: "true")
        let space = try #require(w.state.spaces.first { $0.id == team.spaceId } ?? (try w.state.db.getAllSpaces()).first { $0.id == team.spaceId })
        #expect(space.name == "clock-made-light")
        let members = Set(try w.state.db.getAgentsForSpace(spaceId: team.spaceId).map(\.displayName))
        #expect(members == Set(team.members), "the team is not in its space: \(members)")
        #expect(Set(team.members).count == 3, "codenames collided")
        let byName = Dictionary(uniqueKeysWithValues: w.state.companions.map { ($0.displayName, $0) })
        #expect(byName[team.lead]?.systemPrompt == Imagine.leadRole())
        #expect(byName[team.eng1]?.systemPrompt == Imagine.engineerRole(lead: team.lead))
        #expect(byName[team.eng2]?.systemPrompt == Imagine.engineerRole(lead: team.lead))
        let stored = try #require(try w.state.db.imagineTeam(spaceId: team.spaceId))
        #expect(stored.members == team.members && stored.title == team.title && stored.versions == 3)
        #expect(abs(stored.startedAt.timeIntervalSince(team.startedAt)) < 1)
        let first = try #require(try w.state.db.chatEntries(chat: team.spaceId, after: 0, limit: 10).first)
        #expect(first.fromName == person.displayName, "the brief must come from the person who imagined it")
        #expect(first.text.hasPrefix("@\(team.lead) /imagine from \(person.displayName): \"a clock made of light\""))
        #expect(first.text.contains("in at most 3 versions"))
        // The port is made at bootstrap, in the space, with the title, and named in the brief by id.
        let port = try #require(team.port)
        let panel = try #require(w.state.portWindows.panels.first { $0.udid == port })
        #expect(panel.spaceId == team.spaceId && panel.title == team.title)
        #expect(panel.html.contains("an imagine team is building this"))
        #expect(stored.port == port)
        #expect(first.text.contains("id \(port)"))
    }

    @Test("the budget binds only a running team's own writes, once the port has that many versions")
    func overBudget() {
        let t = ImagineTeam(spaceId: "s", lead: "Lead-A", eng1: "eng-b", eng2: "eng-c", title: "t", versions: 3,
                            startedAt: Date())
        #expect(!Imagine.overBudget(team: t, writer: "eng-b", versionsSoFar: 2))
        #expect(Imagine.overBudget(team: t, writer: "eng-b", versionsSoFar: 3))
        #expect(Imagine.overBudget(team: t, writer: "lead-a", versionsSoFar: 3), "names match as the gateway spells them")
        #expect(!Imagine.overBudget(team: t, writer: "gordon", versionsSoFar: 9), "not the team's write")
    }

    // MARK: - The budget, through the dispatcher

    @MainActor
    struct Run {
        let w: ParityWorld
        let team: ImagineTeam
        let udid: String
        /// The team's versions: the placeholder made at bootstrap is not one.
        func versions() throws -> Int { try w.state.db.fetchPortVersions(portUdid: udid).count - 1 }
        func write(as name: String, _ html: String) async throws {
            let p: Principal = .peer(id: "child-\(name)", displayName: name, spaceId: team.spaceId)
            _ = try await w.state.runBridgeMethod("port.update", principal: p, args: BridgeArgs(
                ["id": udid, "html": "<title>\(team.title)</title>\(html)", "token": w.state.portInput.token(for: udid)]))
        }
        func person(_ method: String, _ args: [String: Any]) async throws -> BridgeValue {
            let u = w.state.currentUser!
            return try await w.state.runBridgeMethod(method, principal: .human(id: u.id, displayName: u.displayName, spaceId: team.spaceId),
                                                     args: BridgeArgs(args))
        }
    }

    @MainActor
    func run(versions: Int) async throws -> Run {
        let w = try makeParityWorld()
        let team = try await w.state.startImagine(line: "a clock made of light", versions: versions,
                                                  person: w.state.currentUser!, testCommand: "true")
        // The port /imagine made; its placeholder does not count against the budget.
        return Run(w: w, team: team, udid: try #require(team.port))
    }

    @Test("past the budget the team's write is refused with budget_spent and nothing lands; the lead is told once, the person is never refused")
    @MainActor
    func budgetRefuses() async throws {
        let r = try await run(versions: 3)
        var n = 2
        while try r.versions() < 3 { try await r.write(as: r.team.eng1, "v\(n)"); n += 1 }
        let told = try r.w.state.db.chatEntries(chat: r.w.state.resolvePortRef(r.udid)!.key!, after: 0, limit: 50)
            .filter { $0.fromName == "port42" }
        #expect(told.count == 1 && told[0].text.hasPrefix("@\(r.team.lead) that was version 3 of 3"),
                "the lead is told when the budget is reached: \(told.map(\.text))")
        let before = try r.versions()
        let tokenBefore = r.w.state.portInput.token(for: r.udid)
        do {
            try await r.write(as: r.team.eng2, "one more")
            Issue.record("a write past the budget landed")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.budgetSpent.wire, "refused with \(e.code)")
            #expect(e.message.contains("@\(r.team.lead)"))
        }
        #expect(try r.versions() == before, "a refused write made a version")
        #expect(r.w.state.portInput.token(for: r.udid) == tokenBefore, "a refused write moved the token")
        _ = try await r.person("port.update", ["id": r.udid, "html": "<title>x</title>mine",
                                               "token": r.w.state.portInput.token(for: r.udid)])
        #expect(try r.versions() == before + 1, "the person is not bound by the team's budget")
    }

    @Test("imagine.budget raises a spent budget; /imagine --versions sets it")
    @MainActor
    func budgetRaised() async throws {
        let r = try await run(versions: 1)
        try await r.write(as: r.team.eng1, "v1")                       // the placeholder is not counted
        #expect(try r.versions() == 1)
        await #expect(throws: BridgeError.self) { try await r.write(as: r.team.lead, "v2") }
        _ = try await r.person("imagine.budget", ["space": r.team.spaceId, "versions": 2])
        try await r.write(as: r.team.lead, "v2")
        #expect(try r.versions() == 2)
        #expect(try r.w.state.db.imagineTeam(spaceId: r.team.spaceId)?.versions == 2)
    }

    @Test("a bootstrap: nothing in /imagine closes a terminal or removes a companion, and there is no stop")
    @MainActor
    func bootstrapOnly() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib/Services/Imagine.swift"), encoding: .utf8)
        for banned in ["portWindows.close", "deleteAgent", "deleteCompanion", "removeAgentFromSpace",
                       "removeAllSpacesForAgent", "leaveCompanionFromSpace", "removeCompanionFromSpace"] {
            #expect(!src.contains(banned), "/imagine must never \(banned) (GM: terminals are never shut)")
        }
        let w = try makeParityWorld()
        #expect(w.registry["imagine.stop"] == nil)
    }

    // MARK: - ⌘I and the slash command (I.4)

    @Test("⌘I is a shell-global chord for the box; ⇧⌘I is not")
    func chord() {
        #expect(ShellState.shellGlobalChord(keyCode: 34, characters: "i", command: true, shift: false, option: false, control: false) == .imagine)
        #expect(ShellState.shellGlobalChord(keyCode: 34, characters: "i", command: true, shift: true, option: false, control: false) == nil)
        // ⌘G: the galaxy (GM, 2026-09-27).
        #expect(ShellState.shellGlobalChord(keyCode: 5, characters: "g", command: true, shift: false, option: false, control: false) == .galaxy)
        #expect(ShellState.shellGlobalChord(keyCode: 5, characters: "g", command: false, shift: false, option: false, control: false) == nil)
    }

    @Test("the box reads a bare line or a whole /imagine command with the chat's parser")
    func boxCommand() {
        #expect(ImagineBox.command(for: "a tide clock") == .start(line: "a tide clock", versions: Imagine.defaultVersions))
        #expect(ImagineBox.command(for: " --versions 3 a tide clock") == .start(line: "a tide clock", versions: 3))
        #expect(ImagineBox.command(for: "/imagine stop") == nil)
        #expect(ImagineBox.command(for: "   ") == nil)
    }

    @Test("in a chat, /imagine runs and posts nothing as the person; any other line posts")
    @MainActor
    func slashInChat() async throws {
        let r = try await run(versions: 2)
        let s = r.w.state
        let personPosts = { (key: String) in try s.db.chatEntries(chat: key, after: 0, limit: 100).filter { $0.fromName == s.currentUser!.displayName } }
        let before = try personPosts(r.team.spaceId).count

        try await s.submitChatInput(key: r.udid, text: "/imagine --versions 7", testCommand: "true")
        #expect(try s.db.imagineTeam(spaceId: r.team.spaceId)?.versions == 7, "the budget, from the port's chat, reaches its space's team")
        #expect(try personPosts(r.udid).isEmpty && personPosts(r.team.spaceId).count == before)

        try await s.submitChatInput(key: r.team.spaceId, text: "/imagined worlds", testCommand: "true")
        #expect(try personPosts(r.team.spaceId).last?.text == "/imagined worlds", "not the command: posted as text")

        let spacesBefore = Set(try s.db.getAllSpaces().map(\.id))
        try await s.submitChatInput(key: r.team.spaceId, text: "/imagine a tide clock", testCommand: "true")
        let made = Set(try s.db.getAllSpaces().map(\.id)).subtracting(spacesBefore)
        #expect(made.count == 1, "a chat's /imagine starts a team in a new space")
        #expect(try !personPosts(r.team.spaceId).contains { $0.text.hasPrefix("/imagine a tide") })

        // No stop: typed, it is only text, and the team is untouched.
        try await s.submitChatInput(key: r.team.spaceId, text: "/imagine stop", testCommand: "true")
        #expect(try personPosts(r.team.spaceId).last?.text == "/imagine stop")
        #expect(Set(try s.db.getAgentsForSpace(spaceId: r.team.spaceId).map(\.displayName)) == Set(r.team.members))
    }

    @Test("an imagine team runs on the agent the person chose, even with both installed")
    func teamRunsOnTheChoice() {
        #expect(Imagine.teamCLI(chosen: "codex", installed: ["claude", "codex"]) == "codex")
        #expect(Imagine.teamCLI(chosen: "claude", installed: ["claude", "codex"]) == "claude")
        #expect(Imagine.teamCLI(chosen: "codex", installed: ["claude"]) == "claude", "the choice was uninstalled")
        #expect(Imagine.teamCLI(chosen: nil, installed: ["codex"]) == "codex")
        #expect(Imagine.teamCLI(chosen: "codex", installed: []) == "codex")
    }

    @Test("first run records the agent the person picked")
    @MainActor
    func setupRecordsTheChoice() throws {
        let before = UserDefaults.standard.string(forKey: "preferredAgentCLI")
        defer { UserDefaults.standard.set(before, forKey: "preferredAgentCLI") }
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Brother")
        try db.saveUser(user)
        state.currentUser = user
        state.completeSetup(displayName: "Brother", cli: "codex")
        #expect(state.preferredCLI == "codex")
    }

    @Test("the space pill and ⌘G go straight to the galaxy from any rung, and back to the space")
    @MainActor
    func toggleGalaxy() throws {
        let shell = ShellState(appState: AppState(db: try DatabaseService(inMemory: true)))
        shell.zoom = .focus("p")
        shell.toggleGalaxy()
        #expect(shell.zoom == .galaxy, "from a focused port it only stepped up to the space")
        shell.toggleGalaxy()
        #expect(shell.zoom == .space)
        shell.toggleGalaxy()
        #expect(shell.zoom == .galaxy)
    }

    @Test("a short space name from the line: the asking and the filler dropped, a few words kept")
    func shortSpaceName() {
        #expect(Imagine.spaceName(from: "a starfield you can steer with the mouse") == "starfield steer mouse")
        #expect(Imagine.spaceName(from: "I want you to run a full security audit on main branch, we") == "run full security")
        #expect(Imagine.spaceName(from: "make me a shader that reacts to music") == "shader reacts music")
        #expect(Imagine.spaceName(from: "create a mini crm for managing contacts") == "mini crm managing")
        #expect(Imagine.spaceName(from: "   ") == Imagine.title(from: "   "))
    }

    @Test("the team is named by role after the space, and a taken name gets a number")
    func roleNames() {
        let t = Imagine.teamNames(for: "starfield steer mouse", taken: [])
        #expect(t.lead == "starfield-lead" && t.eng1 == "starfield-eng-1" && t.eng2 == "starfield-eng-2")
        let again = Imagine.teamNames(for: "starfield steer mouse", taken: ["starfield-lead", "starfield-eng-1", "starfield-eng-2"])
        #expect(again.lead == "starfield-lead-2" && again.eng2 == "starfield-eng-2-2")
    }
}
