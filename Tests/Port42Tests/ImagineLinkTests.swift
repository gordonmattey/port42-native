import Testing
import Foundation
@testable import Port42Lib

/// `port42://imagine?line=…&from=…` opens the imagine box filled in, and never starts a team: any web
/// page can fire the link (asked by growth for port42.ai, 2026-09-27).
@Suite("Imagine links")
@MainActor
struct ImagineLinkTests {
    func url(_ s: String) -> URL { URL(string: s)! }

    @Test("the idea and where it came from are read; anything else is not an imagine link")
    func parse() {
        let r = ImagineLinkRequest.parse(url("port42://imagine?line=a%20shader%20that%20reacts%20to%20music&from=port42.ai&x=1"))
        #expect(r == ImagineLinkRequest(line: "a shader that reacts to music", from: "port42.ai"))
        #expect(ImagineLinkRequest.parse(url("port42://imagine?line=%20%20")) == nil, "no idea, no link")
        #expect(ImagineLinkRequest.parse(url("port42://invite?line=x")) == nil)
        #expect(ImagineLinkRequest.parse(url("https://imagine?line=x")) == nil)
        #expect(ImagineLinkRequest.parse(url("port42://imagine?line=x"))?.from == nil)
    }

    @Test("control characters become spaces and the idea is cut to 300 characters")
    func cleaned() throws {
        let r = try #require(ImagineLinkRequest.parse(url("port42://imagine?line=one%0Atwo%09three%07")))
        #expect(r.line == "one two three")
        let long = String(repeating: "a", count: 500)
        #expect(ImagineLinkRequest.parse(url("port42://imagine?line=\(long)"))?.line.count == 300)
    }

    @Test("a link opens the box filled in and starts nothing; during a first run it waits for the landing")
    func opens() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let shell = ShellState(appState: state)
        state.shell = shell
        let req = ImagineLinkRequest(line: "a starfield you can steer", from: "port42.ai")
        // During the first run: held, nothing opens.
        state.enterShellFromSetup()
        let spacesBefore = try state.db.getRegularSpaces().count
        state.openImagineLink(req)
        #expect(!shell.showImagine && state.heldImagineLink == req)
        // Landed: it opens.
        state.endOnboarding()
        state.openHeldImagineLink()
        #expect(shell.showImagine && shell.imagineLink == req && state.heldImagineLink == nil)
        #expect(try state.db.getRegularSpaces().count == spacesBefore, "a link started a team")
    }

    @Test("a held idea survives a quit, and echo leads with it instead of the shader")
    func heldAcrossLaunchesAndInEcho() throws {
        defer { UserDefaults.standard.removeObject(forKey: "heldImagineLink") }
        let first = AppState(db: try DatabaseService(inMemory: true))
        first.heldImagineLink = ImagineLinkRequest(line: "a synth I play with my hands", from: "port42.ai/start")
        let db = try DatabaseService(inMemory: true)
        let second = AppState(db: db)                        // the app, reopened
        #expect(second.heldImagineLink?.line == "a synth I play with my hands")
        let user = AppUser.createForTesting(displayName: "Gordon")
        try db.saveUser(user)
        second.currentUser = user
        second.completeSetup(displayName: "Gordon", cli: "claude")
        let echo = try #require(second.companions.first { $0.displayName == "echo" })
        let prompt = echo.systemPrompt ?? ""
        #expect(prompt.contains("\"a synth I play with my hands\"") && prompt.contains("do not suggest the shader"))
        #expect(!prompt.contains("{{CAME_FOR}}"))
        second.heldImagineLink = nil
        #expect(AppState.echoCameForNote(nil) == "")
    }
}
