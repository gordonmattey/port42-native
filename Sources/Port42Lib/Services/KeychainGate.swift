import Foundation
import Security

/// Every Keychain call in Port42 goes through here, so a test run cannot reach the user's Keychain by
/// default (#47). Port42AuthStore is the only Keychain user, and its guards were per call site: the
/// root secret, the peer seed and invite links were kept out of tests, while the boot cleanup of
/// old engine credentials (`removeEngineCredentials`) still deleted real items from a test run.
///
/// In a test process (AppState.isTestProcess) the calls are served by an in-memory store instead, so
/// tests that save and load a secret still work, and nothing they do is visible outside the process.
/// Set PORT42_TESTS_USE_KEYCHAIN=1 to run tests against the real Keychain on purpose.
/// In the app, the calls go straight to Security.framework, unchanged.
enum KeychainGate {
    static let optInVariable = "PORT42_TESTS_USE_KEYCHAIN"

    /// Whether calls reach the real Keychain.
    nonisolated static var usesRealKeychain: Bool {
        !AppState.isTestProcess || ProcessInfo.processInfo.environment[optInVariable] == "1"
    }

    nonisolated static func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        usesRealKeychain ? SecItemCopyMatching(query, result) : memory.copyMatching(query as NSDictionary, result)
    }

    @discardableResult
    nonisolated static func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        usesRealKeychain ? SecItemAdd(attributes, result) : memory.add(attributes as NSDictionary)
    }

    @discardableResult
    nonisolated static func delete(_ query: CFDictionary) -> OSStatus {
        usesRealKeychain ? SecItemDelete(query) : memory.delete(query as NSDictionary)
    }

    nonisolated static let memory = InMemoryKeychain()
}

/// Generic-password items held in memory, for test processes. Covers the queries Port42 makes:
/// match on service and account, return data or attributes, one match or all.
final class InMemoryKeychain: @unchecked Sendable {
    private struct Item {
        var service: String
        var account: String
        var data: Data
        var created: Date
    }
    private var items: [Item] = []
    private let lock = NSLock()

    private func matches(_ item: Item, _ q: NSDictionary) -> Bool {
        if let s = q[kSecAttrService as String] as? String, s != item.service { return false }
        if let a = q[kSecAttrAccount as String] as? String, a != item.account { return false }
        return true
    }

    func copyMatching(_ q: NSDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let found = items.filter { matches($0, q) }
        guard !found.isEmpty else { return errSecItemNotFound }
        let all = (q[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        let wantData = (q[kSecReturnData as String] as? Bool) == true
        let wantAttributes = (q[kSecReturnAttributes as String] as? Bool) == true
        func value(_ item: Item) -> AnyObject {
            if wantAttributes {
                var attrs: [String: Any] = [
                    kSecAttrService as String: item.service,
                    kSecAttrAccount as String: item.account,
                    kSecAttrCreationDate as String: item.created,
                    kSecAttrModificationDate as String: item.created,
                ]
                if wantData { attrs[kSecValueData as String] = item.data }
                return attrs as NSDictionary
            }
            return item.data as NSData
        }
        if let result, wantData || wantAttributes {
            result.pointee = all ? (found.map(value) as NSArray) : value(found[0])
        }
        return errSecSuccess
    }

    func add(_ q: NSDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let item = Item(service: q[kSecAttrService as String] as? String ?? "",
                        account: q[kSecAttrAccount as String] as? String ?? "",
                        data: q[kSecValueData as String] as? Data ?? Data(),
                        created: Date())
        if items.contains(where: { $0.service == item.service && $0.account == item.account }) {
            return errSecDuplicateItem
        }
        items.append(item)
        return errSecSuccess
    }

    func delete(_ q: NSDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let before = items.count
        items.removeAll { matches($0, q) }
        return items.count == before ? errSecItemNotFound : errSecSuccess
    }
}
