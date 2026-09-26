import Testing
import Foundation
@testable import Port42Lib

// /imagine (docs/plan-imagine.md): fixed texts with variables, and the command's parser.
@Suite("Imagine: texts and parser")
struct ImagineTests {

    @Test("the parser: a line, a budget, stop; anything else is text")
    func parse() {
        #expect(Imagine.parse("/imagine a shader that reacts to music") == .start(line: "a shader that reacts to music", versions: 5))
        #expect(Imagine.parse("  /imagine --versions 3 a clock  ") == .start(line: "a clock", versions: 3))
        #expect(Imagine.parse("/imagine --versions 99 x") == .start(line: "x", versions: Imagine.maxVersions))
        #expect(Imagine.parse("/imagine stop") == .stop)
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
                              eng2: "merry-koi", title: "a shader that reacts to music", versions: 5)
        #expect(b.hasPrefix("@swift-pika /imagine from gordon: \"\(line)\""))
        #expect(b.contains("You lead two engineers, merry-wren and merry-koi"))
        #expect(MentionParser.extractMentions(from: b).map { $0.lowercased() } == ["@swift-pika"],
                "the brief must @mention only the lead, or it reaches the engineers too")
        #expect(b.contains("titled 'a shader that reacts to music'"))
        #expect(b.contains("in at most 5 versions"))
        #expect(b.contains("Have merry-wren make v1"))
        #expect(b.contains("starts with DONE"))
        #expect(!b.contains("{"), "an unfilled variable")
    }

    @Test("roles: the lead does not build; an engineer reports to its lead by name")
    func roles() {
        #expect(Imagine.leadRole().contains("You do not build"))
        #expect(Imagine.leadRole().contains("Stop at DONE"))
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
        #expect(space.name == "a-clock-made-of-light")
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
    }

    @Test("the budget binds only a running team's own writes, once the port has that many versions")
    func overBudget() {
        var t = ImagineTeam(spaceId: "s", lead: "Lead-A", eng1: "eng-b", eng2: "eng-c", title: "t", versions: 3,
                            startedAt: Date(), stoppedAt: nil)
        #expect(!Imagine.overBudget(team: t, writer: "eng-b", versionsSoFar: 2))
        #expect(Imagine.overBudget(team: t, writer: "eng-b", versionsSoFar: 3))
        #expect(Imagine.overBudget(team: t, writer: "lead-a", versionsSoFar: 3), "names match as the gateway spells them")
        #expect(!Imagine.overBudget(team: t, writer: "gordon", versionsSoFar: 9), "not the team's write")
        t.stoppedAt = Date()
        #expect(!Imagine.overBudget(team: t, writer: "eng-b", versionsSoFar: 9), "a stopped team has no budget")
    }

    // MARK: - Stop and the budget, through the dispatcher

    @MainActor
    struct Run {
        let w: ParityWorld
        let team: ImagineTeam
        let udid: String
        func versions() throws -> Int { try w.state.db.fetchPortVersions(portUdid: udid).count }
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
        w.state.portWindows.registerTiledPort(id: "p", html: "<title>\(team.title)</title>v1", spaceId: team.spaceId,
                                              createdBy: team.eng1, title: team.title, position: CGPoint(x: 40, y: 40))
        let udid = w.state.portWindows.panels.first { $0.id == "p" }!.udid
        return Run(w: w, team: team, udid: udid)
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
        await #expect(throws: BridgeError.self) { try await r.write(as: r.team.lead, "v2") }
        _ = try await r.person("imagine.budget", ["space": r.team.spaceId, "versions": 2])
        try await r.write(as: r.team.lead, "v2")
        #expect(try r.versions() == 2)
        #expect(try r.w.state.db.imagineTeam(spaceId: r.team.spaceId)?.versions == 2)
    }

    @Test("stop: the team is gone and its terminals close; a later mention brings no one back; the port and the chats stay")
    @MainActor
    func stop() async throws {
        let r = try await run(versions: 1)
        // Headless, the team's terminals are not spawned; stand one in for each member.
        for name in r.team.members {
            let config = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
                                            spaceId: r.team.spaceId, spaceName: r.team.title, companionName: name,
                                            companionId: "", createdBy: "", companionPrompt: "", env: [:], initialInput: "")
            var panel = PortPanel(id: "t-\(name)", udid: "t-\(name)", html: String(decoding: try JSONEncoder().encode(config), as: UTF8.self),
                                  bridge: PortBridge(appState: r.w.state, spaceId: r.team.spaceId, messageId: "t-\(name)"),
                                  spaceId: r.team.spaceId, createdBy: nil, messageId: "t-\(name)", size: CGSize(width: 400, height: 300))
            panel.portType = "terminal"
            r.w.state.portWindows.panels.append(panel)
        }
        let key = r.w.state.resolvePortRef(r.udid)!.key!
        _ = try r.w.state.postToChat(key: key, text: "working", from: .peer(id: "x", displayName: r.team.eng1, spaceId: r.team.spaceId))
        let v = try await r.person("imagine.stop", ["space": r.team.spaceId])
        guard case .object(let o) = v, case .array(let gone)? = o["stopped"] else { Issue.record("no stopped list"); return }
        #expect(gone.count == 3)
        #expect(try r.w.state.db.getAgentsForSpace(spaceId: r.team.spaceId).isEmpty, "the team is still in its space")
        #expect(!r.w.state.companions.contains { r.team.isMember($0.displayName) }, "a stopped team's companion still exists")
        // A late reply from one member mentioning another used to bring the team back (Dev4).
        _ = try r.w.state.postToChat(key: r.team.spaceId, text: "@\(r.team.eng1) done, over to you",
                                     from: .peer(id: "x", displayName: r.team.eng2, spaceId: r.team.spaceId))
        #expect(try r.w.state.db.getAgentsForSpace(spaceId: r.team.spaceId).isEmpty, "a mention brought a stopped member back")
        let terminals = r.w.state.portWindows.panels.filter { p in
            r.team.members.contains { $0.caseInsensitiveCompare(p.terminalConfig?.companionName ?? "") == .orderedSame }
        }
        #expect(terminals.isEmpty, "a team terminal is still open")
        #expect(r.w.state.portWindows.panels.contains { $0.udid == r.udid }, "stop closed the port")
        #expect(try r.w.state.db.chatEntries(chat: key, after: 0, limit: 10).contains { $0.text == "working" })
        let last = try #require(try r.w.state.db.chatEntries(chat: r.team.spaceId, after: 0, limit: 50).last { $0.fromName == "port42" })
        #expect(last.text == Imagine.stopped(try #require(try r.w.state.db.imagineTeam(spaceId: r.team.spaceId))))
        #expect(!last.text.contains("@"), "the stop notice must not wake the team")
        try await r.write(as: r.team.eng1, "after stop")
        #expect(try r.versions() == 2, "a stopped team is not bound by its budget")
        let notices = try r.w.state.db.chatEntries(chat: r.team.spaceId, after: 0, limit: 50).filter { $0.fromName == "port42" }.count
        _ = try await r.person("imagine.stop", ["space": r.team.spaceId])
        #expect(try r.w.state.db.chatEntries(chat: r.team.spaceId, after: 0, limit: 50).filter { $0.fromName == "port42" }.count == notices,
                "stopping again posted again")
    }

    // MARK: - ⌘I and the slash command (I.4)

    @Test("⌘I is a shell-global chord for the box; ⇧⌘I is not")
    func chord() {
        #expect(ShellState.shellGlobalChord(keyCode: 34, characters: "i", command: true, shift: false, option: false, control: false) == .imagine)
        #expect(ShellState.shellGlobalChord(keyCode: 34, characters: "i", command: true, shift: true, option: false, control: false) == nil)
    }

    @Test("the box reads a bare line or a whole /imagine command with the chat's parser")
    func boxCommand() {
        #expect(ImagineBox.command(for: "a tide clock") == .start(line: "a tide clock", versions: Imagine.defaultVersions))
        #expect(ImagineBox.command(for: " --versions 3 a tide clock") == .start(line: "a tide clock", versions: 3))
        #expect(ImagineBox.command(for: "/imagine stop") == .stop)
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

        try await s.submitChatInput(key: r.team.spaceId, text: "/imagine stop", testCommand: "true")
        #expect(try s.db.imagineTeam(spaceId: r.team.spaceId)?.stoppedAt != nil)
        #expect(try !personPosts(r.team.spaceId).contains { $0.text == "/imagine stop" })
    }
}
