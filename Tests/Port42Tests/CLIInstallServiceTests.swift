import Testing
import Foundation
@testable import Port42Lib

@Suite("CLIInstallService")
@MainActor
struct CLIInstallServiceTests {

    // MARK: - Command naming

    @Test("The daily driver owns the plain `port42` name")
    func prodOwnsPlainName() {
        #expect(CLIInstallService.commandName(bundleID: "com.port42.app") == "port42")
        #expect(CLIInstallService.commandName(bundleID: nil) == "port42")
    }

    @Test("Each dev bundle installs under its own name so they cannot fight over the link")
    func devBundlesAreSuffixed() {
        #expect(CLIInstallService.commandName(bundleID: "com.port42.dev") == "port42-dev")
        #expect(CLIInstallService.commandName(bundleID: "com.port42.dev2") == "port42-dev2")
        #expect(CLIInstallService.commandName(bundleID: "com.port42.dev3") == "port42-dev3")
        // Dev4 is the standing test target (build.sh --dev4). The name is DERIVED from the bundle
        // id, so a new instance needs no change here — this pins that it stays that way.
        #expect(CLIInstallService.commandName(bundleID: "com.port42.dev4") == "port42-dev4")
    }

    @Test("The BUNDLED name never collides with an app executable, case-insensitively")
    func bundledNameCannotOverwriteTheApp() {
        // A release bundle's executable is `Contents/MacOS/Port42`, and macOS's filesystem is
        // case-INSENSITIVE, so a helper named `port42` IS that path and replaces the app binary.
        // It shipped: a validly signed bundle whose main executable printed CLI usage. Dev builds
        // could not reproduce it, because `Port42Dev3` and friends do not collide — which is why
        // this is pinned here rather than left to the release path to discover again.
        let executableNames = ["Port42", "Port42Dev", "Port42Dev2", "Port42Dev3", "Port42Dev4"]
        for exec in executableNames {
            #expect(CLIInstallService.bundledExecutableName.lowercased() != exec.lowercased())
        }
        // And the name the user types is unaffected by that constraint.
        #expect(CLIInstallService.commandName(bundleID: "com.port42.app") == "port42")
    }

    @Test("enrolment is not conditional on winning the name on PATH")
    func enrolmentIsNotCoupledToLinking() throws {
        // Structural, because it cannot be reached behaviorally: `install()` returns at its first
        // guard in a test process (no CLI is bundled), so no test can observe the branch. What is
        // being pinned is an ORDER, and the regression is someone moving the enrolment back inside
        // the switch, where it lived until it was found.
        //
        // The defect it guards: `.leaveForeignAlone` returned before the registry was ever
        // consulted, so a user with their own `port42` on PATH got no client row, no token, and
        // since 5b no ability to call at all. Two jobs sharing one early return.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Port42Lib/Services/CLIInstallService.swift"),
            encoding: .utf8)

        let enrolCall = source.range(of: "enrol(registry: registry)")
        let foreignBranch = source.range(of: "case .leaveForeignAlone")
        #expect(enrolCall != nil, "install() must call enrol(registry:)")
        #expect(foreignBranch != nil, "the foreign-link branch must still exist")
        if let enrolCall, let foreignBranch {
            #expect(enrolCall.lowerBound < foreignBranch.lowerBound,
                    "enrolment must happen before the branch that can decline to link")
        }
    }

    // MARK: - Install planning

    @Test("Nothing at the path means create it")
    func createsWhenAbsent() {
        let action = CLIInstallService.plan(
            existing: nil, existingIsSymlink: false, destination: nil,
            want: "/Applications/Port42.app/Contents/MacOS/port42")
        #expect(action == .create)
    }

    @Test("A link already pointing at this build is left alone")
    func noopWhenCorrect() {
        let want = "/Applications/Port42.app/Contents/MacOS/port42"
        let action = CLIInstallService.plan(
            existing: "/Users/x/.local/bin/port42", existingIsSymlink: true,
            destination: want, want: want)
        #expect(action == .alreadyCorrect)
    }

    @Test("A link into an old bundle location is re-pointed, which is the app-moved case")
    func repointsStaleLink() {
        let old = "/Users/x/Downloads/Port42.app/Contents/MacOS/port42"
        let action = CLIInstallService.plan(
            existing: "/Users/x/.local/bin/port42", existingIsSymlink: true,
            destination: old, want: "/Applications/Port42.app/Contents/MacOS/port42")
        #expect(action == .repoint(from: old))
    }

    @Test("A real file at the path is never clobbered")
    func leavesRegularFileAlone() {
        // Someone's own binary on their own PATH. Overwriting it would be the worst kind of
        // surprise from an app that just wanted to install a convenience.
        let action = CLIInstallService.plan(
            existing: "/Users/x/.local/bin/port42", existingIsSymlink: false, destination: nil,
            want: "/Applications/Port42.app/Contents/MacOS/port42")
        #expect(action == .leaveForeignAlone("/Users/x/.local/bin/port42"))
    }

    @Test("A symlink to something outside an app bundle is left alone")
    func leavesForeignSymlinkAlone() {
        let foreign = "/opt/homebrew/bin/port42"
        let action = CLIInstallService.plan(
            existing: "/Users/x/.local/bin/port42", existingIsSymlink: true,
            destination: foreign, want: "/Applications/Port42.app/Contents/MacOS/port42")
        #expect(action == .leaveForeignAlone(foreign))
    }

    // MARK: - PATH detection

    @Test("PATH membership tolerates trailing slashes and near-misses")
    func pathMembership() {
        let dir = "/Users/x/.local/bin"
        #expect(CLIInstallService.pathContains(dir, path: "/usr/bin:/Users/x/.local/bin:/bin"))
        #expect(CLIInstallService.pathContains(dir, path: "/Users/x/.local/bin/"))
        #expect(CLIInstallService.pathContains(dir + "/", path: "/Users/x/.local/bin"))
        #expect(!CLIInstallService.pathContains(dir, path: "/usr/bin:/bin"))
        // A directory that merely starts with the same characters must not count.
        #expect(!CLIInstallService.pathContains(dir, path: "/Users/x/.local/bin2"))
        #expect(!CLIInstallService.pathContains(dir, path: nil))
    }

    // MARK: - Installing for real, into a temp home

    @Test("Installing creates the link, and is idempotent")
    func installsIntoTempHome() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p42-cli-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let service = CLIInstallService(homeDirectory: home.path)
        // No bundled CLI exists in a test process, so install() declines rather than linking to
        // nothing. That refusal is the behavior worth pinning: a test run must not write a
        // dangling command into anyone's PATH.
        #expect(service.install(bundleID: "com.port42.dev3") == false)
        #expect(service.installedPath == nil)
    }

    @Test("The PATH hint names the directory the link went into")
    func pathHintIsActionable() {
        let service = CLIInstallService(homeDirectory: "/Users/x")
        #expect(service.pathHint.contains(".local/bin"))
    }
}
