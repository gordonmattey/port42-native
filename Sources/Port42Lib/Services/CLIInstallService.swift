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
    public static let bundledExecutableName = "port42"

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
        guard let bundleID, bundleID != "com.port42.app" else { return bundledExecutableName }
        // com.port42.dev3 -> port42-dev3
        if let suffix = bundleID.split(separator: ".").last, suffix != "app", suffix != "port42" {
            return "\(bundledExecutableName)-\(suffix)"
        }
        return bundledExecutableName
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

    /// Idempotent. Safe to call on every boot, which is exactly how it is wired.
    @discardableResult
    public func install(bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
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
