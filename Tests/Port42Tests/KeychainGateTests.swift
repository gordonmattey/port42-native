import Testing
import Foundation
import Security
@testable import Port42Lib

/// `swift test` never reaches the user's Keychain unless asked to (#47). It used to read the real
/// Claude Code credentials and Anthropic key, and write and delete real items.
@Suite("Keychain gate")
struct KeychainGateTests {
    @Test("a test run uses the in-memory store unless PORT42_TESTS_USE_KEYCHAIN=1")
    func testsDoNotUseRealKeychain() {
        let optedIn = ProcessInfo.processInfo.environment[KeychainGate.optInVariable] == "1"
        #expect(AppState.isTestProcess)
        #expect(KeychainGate.usesRealKeychain == optedIn)
    }

    @Test("save, load, list and delete work against the in-memory store")
    func inMemoryRoundTrip() {
        let service = "keychain-gate-test-\(UUID().uuidString)"
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "a",
            kSecValueData as String: Data("secret".utf8),
        ]
        let store = InMemoryKeychain()
        #expect(store.add(item as NSDictionary) == errSecSuccess)
        #expect(store.add(item as NSDictionary) == errSecDuplicateItem)

        var one: CFTypeRef?
        let q: [String: Any] = [kSecAttrService as String: service, kSecAttrAccount as String: "a",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        #expect(store.copyMatching(q as NSDictionary, &one) == errSecSuccess)
        #expect((one as? Data) == Data("secret".utf8))

        var all: CFTypeRef?
        let list: [String: Any] = [kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        #expect(store.copyMatching(list as NSDictionary, &all) == errSecSuccess)
        #expect((all as? [[String: Any]])?.first?[kSecAttrService as String] as? String == service)

        #expect(store.delete([kSecAttrService as String: service] as NSDictionary) == errSecSuccess)
        #expect(store.copyMatching(q as NSDictionary, &one) == errSecItemNotFound)
    }

    @Test("no source file calls Security's SecItem functions except the gate")
    func everyCallGoesThroughTheGate() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files where file.lastPathComponent != "KeychainGate.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in ["SecItemCopyMatching(", "SecItemAdd(", "SecItemDelete(", "SecItemUpdate("] {
                let callsDirectly = text.contains(call)  // a Bool, so a failure names the file, not its text
                #expect(!callsDirectly, "\(file.lastPathComponent) calls \(call) directly")
            }
        }
    }
}
