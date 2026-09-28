import Foundation

/// What the removed ngrok tunnel left on a Mac (SEC-02). The tunnel code is gone, but a build that had
/// it saved the ngrok auth token in UserDefaults (readable by any process running as the user) and
/// downloaded the ngrok binary into Application Support. Nothing reads either any more, so both are
/// removed at launch. Idempotent.
enum NgrokLeftovers {
    static let defaultsKeys = ["ngrokAuthToken", "ngrokDomain"]

    /// Where the old tunnel downloaded ngrok: ~/Library/Application Support/Port42/bin/ngrok.
    static var defaultBinary: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Port42/bin/ngrok")
    }

    /// Removes the saved token and domain, and the downloaded binary. Returns what it removed, by name
    /// only, never a value.
    @discardableResult
    static func remove(defaults: UserDefaults = .standard, binary: URL? = defaultBinary) -> [String] {
        var removed: [String] = []
        for key in defaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        if let binary, FileManager.default.fileExists(atPath: binary.path),
           (try? FileManager.default.removeItem(at: binary)) != nil {
            removed.append(binary.lastPathComponent)
        }
        return removed
    }
}
