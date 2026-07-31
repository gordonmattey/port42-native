import Foundation

/// Puts the bundled `port42` command line on the user's PATH, and keeps it there.
///
/// Installed as a SYMLINK into the app bundle rather than a copy, so an app upgrade needs no
/// version logic at all: replacing the app replaces what the link resolves to. The boot pass
/// re-points a link that has gone stale, which is what happens when the user drags the app to
/// /Applications after first running it from Downloads.
///
/// Each instance owns its OWN command name, derived from the bundle id. The daily driver owns
/// `port42`; a dev build installs `port42-dev3` and friends. Without that, every dev instance
/// would re-point the same link at itself on each boot and the name would mean whichever app
/// booted last.
@MainActor
public final class CLIInstallService: ObservableObject {
    public static let shared = CLIInstallService()

    /// Where the link goes. `~/.local/bin` is the conventional user-level bin directory and
    /// needs no sudo, unlike /usr/local/bin.
    public static let installDirRelativeToHome = ".local/bin"

    /// Name of the CLI binary inside `Contents/MacOS/`.
    ///
    /// **It is NOT `port42`, and the reason is load-bearing.** A release bundle's own executable is
    /// `Contents/MacOS/Port42`, and macOS ships a case-INSENSITIVE filesystem, so a helper named
    /// `port42` is the same path as the app binary and overwrites it. The bundle then carries a
    /// valid Developer ID signature over an app whose main executable is the command line, and the
    /// only symptom is that launching prints CLI usage. No dev instance can reproduce it, because
    /// their executables are `Port42Dev3` and friends, which do not collide.
    ///
    /// So this follows the convention the other two bundled helpers already use
    /// (`port42-gateway`, `port42-claude-shim`). The name the USER types is separate; see
    /// `commandBaseName`.
    public static let bundledExecutableName = "port42-cli"

    /// The base of the command name installed on PATH. Deliberately distinct from
    /// `bundledExecutableName`: what the user types is `port42`, and what sits in the bundle cannot
    /// be, for the reason above.
    public static let commandBaseName = "port42"

    @Published public var installedPath: String?
    /// True when the link is in place but `~/.local/bin` is not on PATH, so the user has a
    /// working install they cannot invoke. Surfaced in Settings rather than failed silently.
    @Published public var notOnPath = false

    private let home: String

    init(homeDirectory: String = NSHomeDirectory()) {
        self.home = homeDirectory
    }

    // MARK: - Naming

    /// The command name this instance installs. Prod is `port42`; every dev bundle gets a
    /// suffixed name so several installed instances coexist.
    public static func commandName(bundleID: String?) -> String {
        guard let bundleID, bundleID != "com.port42.app" else { return commandBaseName }
        // com.port42.dev3 -> port42-dev3
        if let suffix = bundleID.split(separator: ".").last, suffix != "app", suffix != "port42" {
            return "\(commandBaseName)-\(suffix)"
        }
        return commandBaseName
    }

    // MARK: - Paths

    private var installDir: String {
        (home as NSString).appendingPathComponent(Self.installDirRelativeToHome)
    }

    private func linkPath(bundleID: String?) -> String {
        (installDir as NSString).appendingPathComponent(Self.commandName(bundleID: bundleID))
    }

    /// The bundled CLI, resolved the same way as the gateway and the shim.
    public static func bundledCLIPath() -> String? {
        if let path = Bundle.main.url(forAuxiliaryExecutable: bundledExecutableName)?.path {
            return path
        }
        if let exec = Bundle.main.executableURL {
            let sibling = exec.deletingLastPathComponent().appendingPathComponent(bundledExecutableName)
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
        }
        return nil
    }

    // MARK: - Decide

    /// What to do about whatever currently occupies the link path. Pure, so the interesting
    /// cases are testable without touching a real home directory.
    public enum Action: Equatable {
        case create                 // nothing there
        case repoint(from: String)  // our link, pointing somewhere else or nowhere
        case alreadyCorrect
        case leaveForeignAlone(String) // something we did not put there
    }

    /// A link is OURS if it resolves into a Port42 app bundle. Anything else at that path is a
    /// binary the user chose to put on their own PATH, and clobbering it would be rude at best.
    public static func plan(existing: String?, existingIsSymlink: Bool, destination: String?, want: String) -> Action {
        guard existing != nil else { return .create }
        guard existingIsSymlink, let destination else {
            return .leaveForeignAlone(existing!)
        }
        if destination == want { return .alreadyCorrect }
        if destination.contains(".app/Contents/MacOS/") {
            return .repoint(from: destination)
        }
        return .leaveForeignAlone(destination)
    }

    // MARK: - Install

    /// The CLI's client id and label. FIXED, not derived: the CLI must be able to compute the path to
    /// its own token file without asking anything, which is the same reason a client id is a slug
    /// rather than a UUID.
    public static let clientID = "port42-cli"
    public static let clientName = "port42 CLI"

    /// Idempotent. Safe to call on every boot, which is exactly how it is wired.
    @discardableResult
    public func install(bundleID: String? = Bundle.main.bundleIdentifier,
                        registry: ClientRegistry? = nil) -> Bool {
        guard let bundled = Self.bundledCLIPath() else {
            NSLog("[cli-install] no bundled \(Self.bundledExecutableName) in this build; skipping")
            return false
        }

        let fm = FileManager.default
        let link = linkPath(bundleID: bundleID)

        do {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[cli-install] cannot create \(installDir): \(error)")
            return false
        }

        // `fileExists` follows symlinks, so a DANGLING link (the app moved) reads as absent and
        // the create below would fail with EEXIST. Ask about the link itself.
        let attrs = try? fm.attributesOfItem(atPath: link)
        let existing: String? = attrs == nil ? nil : link
        let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
        let destination = try? fm.destinationOfSymbolicLink(atPath: link)

        switch Self.plan(existing: existing, existingIsSymlink: isSymlink, destination: destination, want: bundled) {
        case .alreadyCorrect:
            break
        case .leaveForeignAlone(let what):
            NSLog("[cli-install] \(link) is not ours (\(what)); leaving it alone")
            installedPath = nil
            return false
        case .create:
            guard createLink(at: link, to: bundled) else { return false }
        case .repoint(let from):
            NSLog("[cli-install] re-pointing \(link) from \(from)")
            try? fm.removeItem(atPath: link)
            guard createLink(at: link, to: bundled) else { return false }
        }

        installedPath = link

        // ENROL THE CLI AT INSTALL TIME (GM, 2026-07-29).
        //
        // The CLI posts to `/call` and, until now, carried the comment "No credential is involved:
        // /call is loopback-only and authenticates nobody". It is not a child, so step 6's spawn-time
        // enrolment does not reach it, and CR3's stated remedy — pairing — was dropped. Without this
        // there is no way for it to ever hold a token, and enforcement (5b) would lock the door with
        // nobody able to knock.
        //
        // **Installing is the named act.** The user is present and is deliberately putting this tool
        // on their machine, which is the same consent argument that lets a spawned child enrol with no
        // prompt. That also answers D14's objection to minting inside `InstructionService`: this fires
        // on the install, not on a documentation refresh, and the doc writer keeps one job.
        //
        // Runs on EVERY install, including a re-point after the app moves, because minting is
        // idempotent: the id is fixed, so it re-issues onto the same row and the same token file, and
        // a CLI that lost its file gets it back.
        if let registry {
            if registry.register(id: Self.clientID, name: Self.clientName, kind: .installed) != nil {
                NSLog("[cli-install] enrolled as '\(Self.clientID)'")   // never the token (NFR2)
                // WHICH INSTANCE IS ON WHICH PORT. The CLI targets a PORT (it probes 4242, 4243,
                // 4245…), but a token lives under an INSTANCE directory, and nothing connected the
                // two — a dev machine runs several instances at once and a token minted by one fails
                // another's verification by design (NFR4). So the app, which knows both, writes the
                // mapping down. Without it the CLI would have to guess, and guessing here means
                // presenting one instance's credential to another.
                let portFile = registry.tokenDirectory().deletingLastPathComponent()
                    .appendingPathComponent("gateway-port")
                try? Data("\(GatewayProcess.shared.port)".utf8).write(to: portFile, options: .atomic)
            } else {
                // Not fatal: the CLI still works, it is simply unnamed, exactly as it is today.
                NSLog("[cli-install] WARNING: could not enrol \(Self.clientID); it will call unnamed")
            }
        }

        notOnPath = !Self.pathContains(installDir, path: ProcessInfo.processInfo.environment["PATH"])
        if notOnPath {
            NSLog("[cli-install] installed at \(link) but \(installDir) is not on PATH")
        }
        return true
    }

    private func createLink(at link: String, to destination: String) -> Bool {
        do {
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: destination)
            NSLog("[cli-install] linked \(link) -> \(destination)")
            return true
        } catch {
            NSLog("[cli-install] failed to link \(link): \(error)")
            return false
        }
    }

    /// PATH membership, tolerant of a trailing slash and of `~` not being expanded.
    public static func pathContains(_ dir: String, path: String?) -> Bool {
        guard let path else { return false }
        let normalized = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return path.split(separator: ":").contains { entry in
            let e = entry.hasSuffix("/") ? String(entry.dropLast()) : String(entry)
            return e == normalized
        }
    }

    /// The line a user needs if `~/.local/bin` is not on their PATH.
    public var pathHint: String {
        "export PATH=\"$HOME/\(Self.installDirRelativeToHome):$PATH\""
    }
}
