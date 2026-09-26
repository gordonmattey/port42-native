import Testing
import Foundation
@testable import Port42Lib

@Suite("Dev auto-unlock")
struct DevAutoUnlockTests {
    @Test("a debug build skips the lock screen only when the instance's defaults ask for it")
    func onlyWhenAsked() throws {
        let d = try #require(UserDefaults(suiteName: "port42-dev-auto-unlock-test"))
        d.removeObject(forKey: "PORT42_DEV_AUTO_UNLOCK")
        #expect(!AppState.devAutoUnlock(d), "unset must keep the lock screen")
        d.set(true, forKey: "PORT42_DEV_AUTO_UNLOCK")
        #expect(AppState.devAutoUnlock(d))
        d.removePersistentDomain(forName: "port42-dev-auto-unlock-test")
    }

    @Test("release builds compile the switch out")
    func releaseIgnoresIt() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib/Services/AppState.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        let body = try #require(text.range(of: "nonisolated static func devAutoUnlock").map { String(text[$0.lowerBound...].prefix(300)) })
        #expect(body.contains("#if RELEASE\n        return false"), "the switch must be off in release builds")
    }
}
