import Testing
import Foundation
@testable import Port42Lib

/// **What a spawned session PROMISES its CLI, asserted as a contract** (2026-08-02).
///
/// GM: "seems like we don't have a fundamental test in place to verify the presence of all
/// variables." There wasn't one. Individual tests checked one or two vars each, so a var could go
/// missing — or be added and never delivered — without anything failing.
///
/// This matters more than it looks, because the instruction block and the companion prompt both
/// TELL a CLI these variables exist. A document that promises `$PORT42_TOKEN_FILE` and a session
/// that does not set it is a lie the CLI cannot debug: it reports "no credential" while the
/// credential is right there. That is precisely how the codex sandbox problem presented.
@Suite("Session environment contract")
struct SessionEnvContractTests {

    /// Every variable a Port42-spawned session is promised. Adding one here without setting it in
    /// `make` fails, and removing one from `make` without removing it here fails — which is the
    /// point: the list is the contract, not a description of the code.
    static let promised = [
        "PORT42_HOOKS_SOCKET",   // where the CLI's hooks report
        "PORT42_SPACE_ID",       // which space this companion belongs to (fixed for life)
        "PORT42_SPACE_NAME",
        "PORT42_CLIENT_ID",      // who this child is, as a named grantee
        "PORT42_TOKEN_FILE",     // path to its own token; never the token itself
        "PORT42_CWD_FILE",       // where the shell reports its live cwd
        "ZDOTDIR",               // the injected zsh integration
        "PORT42_REAL_ZDOTDIR",   // the user's true dotfiles, so sourcing does not recurse
        "PATH",
    ]

    func session() -> TerminalHookSession {
        TerminalSessionBootstrap.make(
            sessionId: "ENVCONTR-1111-2222-3333-444444444444",
            spaceId: "space-1", spaceName: "general",
            shimPath: "/tmp/fake-port42-shim",
            claudePath: "/usr/bin/true", oauthToken: "")
    }

    @Test("every promised variable is actually set, and none is empty")
    func allPromisedVarsPresent() {
        let s = session()
        defer { TerminalSessionBootstrap.cleanup(tempDir: s.tempDir) }
        for key in Self.promised {
            #expect(s.env[key] != nil, "promised but never set: \(key)")
            #expect(s.env[key]?.isEmpty == false, "set but empty: \(key)")
        }
    }

    @Test("the companion prompt is set only when there IS a companion")
    func companionPromptIsConditional() {
        let bare = session()
        defer { TerminalSessionBootstrap.cleanup(tempDir: bare.tempDir) }
        #expect(bare.env["PORT42_COMPANION_PROMPT"] == nil,
                "a plain terminal is not a companion and must not be briefed as one")

        let briefed = TerminalSessionBootstrap.make(
            sessionId: "ENVCONTR-5555-6666-7777-888888888888",
            spaceId: "space-1", spaceName: "general", companionPrompt: "You are scout.",
            shimPath: "/tmp/fake-port42-shim", claudePath: "/usr/bin/true", oauthToken: "")
        defer { TerminalSessionBootstrap.cleanup(tempDir: briefed.tempDir) }
        #expect(briefed.env["PORT42_COMPANION_PROMPT"] == "You are scout.")
    }

    /// The token itself must never ride the environment: `ps -E` publishes a subprocess environment
    /// to anything running as this user. The env carries the PATH to a 0600 file, and that is the
    /// whole distinction.
    @Test("the environment carries a token PATH, never a token")
    func envCarriesPathNotSecret() {
        let s = session()
        defer { TerminalSessionBootstrap.cleanup(tempDir: s.tempDir) }
        let path = s.env["PORT42_TOKEN_FILE"] ?? ""
        #expect(path.hasPrefix("/"), "must be a path: \(path)")
        #expect(!path.hasPrefix("p42_"), "that is a token value, not a path")
    }

}
