import Testing
@testable import Port42Lib

/// Step 6 (D4): fs.* is the canonical file surface; files.* are thin aliases routing to the same
/// handlers. The pure, testable contract is permission parity — both names map to .filesystem.
/// (Same-handler dispatch is structural: the bridge switch matches both names in one case, and is
/// exercised end-to-end via the gateway.)
@Suite("Bridge Alias")
struct BridgeAliasTests {

    @Test("files.* permission matches fs.* (filesystem)")
    @MainActor func filesAliasesMatchFs() throws {
        let pairs = [("files.read", "fs.read"), ("files.write", "fs.write"), ("files.pick", "fs.pick")]
        for (alias, canonical) in pairs {
            let a = try registryPermission(alias)
            let c = try registryPermission(canonical)
            #expect(a == c, "\(alias) and \(canonical) must share one permission")
        }
    }

    @Test("both fs.* and files.* are gated behind .filesystem")
    @MainActor func bothGatedFilesystem() throws {
        #expect(try registryPermission("fs.read") == .filesystem)
        #expect(try registryPermission("files.read") == .filesystem)
    }
}
