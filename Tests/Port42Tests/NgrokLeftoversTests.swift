import Testing
import Foundation
@testable import Port42Lib

/// The ngrok tunnel is gone, but its saved token (UserDefaults, readable by any process running as the
/// user) and its downloaded binary stayed on every Mac that had it (SEC-02).
@Suite("ngrok leftovers")
struct NgrokLeftoversTests {
    @Test("the saved token, domain and binary are removed, and a second run finds nothing")
    func removesLeftovers() throws {
        let suite = "ngrok-leftovers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("2abc_token", forKey: "ngrokAuthToken")
        defaults.set("me.ngrok.app", forKey: "ngrokDomain")
        defaults.set("keep", forKey: "unrelated")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ngrok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("ngrok")
        try Data("binary".utf8).write(to: binary)

        let removed = NgrokLeftovers.remove(defaults: defaults, binary: binary)
        #expect(Set(removed) == ["ngrokAuthToken", "ngrokDomain", "ngrok"])
        #expect(defaults.object(forKey: "ngrokAuthToken") == nil)
        #expect(defaults.object(forKey: "ngrokDomain") == nil)
        #expect(defaults.string(forKey: "unrelated") == "keep")
        #expect(!FileManager.default.fileExists(atPath: binary.path))
        #expect(NgrokLeftovers.remove(defaults: defaults, binary: binary).isEmpty)
    }
}
