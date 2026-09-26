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
        #expect(b.contains("You lead @merry-wren and @merry-koi."))
        #expect(b.contains("titled 'a shader that reacts to music'"))
        #expect(b.contains("in at most 5 versions"))
        #expect(b.contains("Have @merry-wren make v1"))
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
}
