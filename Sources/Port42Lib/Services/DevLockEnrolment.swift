import Foundation

/// The dev-lock holder's own client (#222, docs/dev-instances.md).
///
/// `scripts/dev-lock.sh devN <name> "why"` leaves a request in `~/.port42/<instance>/enrol/<name>`; this
/// enrols a client named after the holder on that instance and writes its token to the usual
/// `~/.port42/<instance>/tokens/<name>`. `--release` leaves `<name>.revoke`, which revokes it. So every
/// call on a dev instance is attributed to whoever made it, and nobody mints a token by hand or
/// borrows another tool's.
///
/// Dev instances only: the daily driver (`Port42`) never reads the directory, so nothing dropped there
/// can mint a credential on it. A request file grants no more than the user's own account already
/// holds: the token files themselves sit in the same directory tree, readable by the same user.
@MainActor
final class DevLockEnrolment {
    let registry: ClientRegistry
    let restore: (String) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(registry: ClientRegistry, restore: @escaping (String) -> Void) {
        self.registry = registry
        self.restore = restore
    }

    /// Whether an instance takes lock requests: every dev instance, never the daily driver.
    nonisolated static func applies(to instance: String) -> Bool {
        instance.lowercased() != "port42" && instance.lowercased().hasPrefix("port42dev")
    }

    /// `~/.port42/<instance>/enrol`, beside the instance's `tokens`.
    var requestDirectory: URL {
        registry.tokenDirectory().deletingLastPathComponent().appendingPathComponent("enrol", isDirectory: true)
    }

    /// Handle every waiting request, oldest first. Returns what it did, for the log.
    @discardableResult
    func process() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: requestDirectory.path) else { return [] }
        var done: [String] = []
        let files = names.filter { !$0.hasPrefix(".") }.map { requestDirectory.appendingPathComponent($0) }
            .sorted { (mtime($0) ?? .distantPast) < (mtime($1) ?? .distantPast) }
        for file in files {
            let name = file.lastPathComponent
            if name.hasSuffix(".revoke") {
                let holder = String(name.dropLast(".revoke".count))
                let id = ClientRegistry.slug(holder)
                if registry.client(id: id) != nil { registry.revoke(id: id); done.append("revoked \(id)") }
            } else {
                let id = ClientRegistry.slug(name)
                // Taking the lock is the holder asking for their client, so a revoked one comes back.
                if registry.client(id: id)?.isActive == false { restore(id) }
                if registry.register(id: id, name: name, kind: .manual) != nil { done.append("enrolled \(id)") }
            }
            try? fm.removeItem(at: file)
        }
        return done
    }

    /// Process what is waiting, then again whenever the lock script leaves a request.
    func start() {
        let dir = requestDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        report(process())
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.report(self?.process() ?? []) } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func report(_ done: [String]) {
        if !done.isEmpty { p42log("[dev-lock] %@", done.joined(separator: ", ")) }   // names only, never a token
    }

    private func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
