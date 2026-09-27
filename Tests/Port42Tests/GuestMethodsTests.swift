import Testing
import Foundation
@testable import Port42Lib

/// The browser guest (4.7) calls the host's methods by name with named arguments, but a port's page
/// calls them positionally (`port42.port.push(id, data, token)`). `guest/src/methods.json` is the
/// parameter names of every method another machine can reach, generated from the one registry so the
/// page and the app cannot drift.
///
///   PORT42_REGEN_GUEST=1 swift test --filter GuestMethodsTests
@Suite("Guest methods table")
@MainActor
struct GuestMethodsTests {

    static func url() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("guest/src/methods.json")
    }

    static func generated() throws -> String {
        let state = AppState(db: try DatabaseService(inMemory: true))
        var table: [String: [String]] = [:]
        for (method, reach) in RemoteAccess.table {
            if case .never = reach { continue }
            let names = state.bridgeRegistry[method]?.paramNames ?? state.bridgeStreamRegistry[method]?.paramNames
            if let names { table[method] = names }
        }
        let data = try JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    @Test("the committed table is the registry's, for every method another machine can reach")
    func current() throws {
        let fresh = try Self.generated()
        if ProcessInfo.processInfo.environment["PORT42_REGEN_GUEST"] == "1" {
            try fresh.write(to: Self.url(), atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: Self.url(), encoding: .utf8)
        #expect(committed == fresh, "guest/src/methods.json is stale: PORT42_REGEN_GUEST=1 swift test --filter GuestMethodsTests")
        #expect(fresh.contains("\"port.push\""), "port.push is missing from what a guest can call")
        #expect(!fresh.contains("\"terminal.exec\""), "a method no other machine may call is in the guest's table")
    }
}
