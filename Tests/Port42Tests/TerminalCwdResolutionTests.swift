import Testing
import Foundation
@testable import Port42Lib

// Step 2 of the command-companion cwd fix (docs/plan-companion-cwd.md): a command companion's
// cwd resolves to the explicit per-port/per-companion override, else the space working
// directory, else home. Pure helper so the precedence is testable without spawning a terminal.

@Suite("TerminalCwdResolution — override ?? spaceDir ?? home")
struct TerminalCwdResolutionTests {

    private let home = "/Users/tester"

    @Test("An explicit override wins over everything")
    func overrideWins() {
        let cwd = TerminalCwd.resolve(override: "/explicit/here",
                                      spaceDir: "/space/dir", home: home)
        #expect(cwd == "/explicit/here")
    }

    @Test("No override falls back to the space working directory")
    func elseSpaceDir() {
        let cwd = TerminalCwd.resolve(override: nil, spaceDir: "/space/dir", home: home)
        #expect(cwd == "/space/dir")
    }

    @Test("No override and no space dir falls back to home")
    func elseHome() {
        let cwd = TerminalCwd.resolve(override: nil, spaceDir: nil, home: home)
        #expect(cwd == home)
    }

    @Test("Empty strings are treated as unset, not as a valid directory")
    func emptyIsUnset() {
        #expect(TerminalCwd.resolve(override: "", spaceDir: "/space/dir", home: home) == "/space/dir")
        #expect(TerminalCwd.resolve(override: nil, spaceDir: "", home: home) == home)
    }
}
