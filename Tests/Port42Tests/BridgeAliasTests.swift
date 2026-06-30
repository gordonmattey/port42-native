import Testing
@testable import Port42Lib

/// Step 6 (D4): fs.* is the canonical file surface; files.* are thin aliases routing to the same
/// handlers. The pure, testable contract is permission parity — both names map to .filesystem.
/// (Same-handler dispatch is structural: the bridge switch matches both names in one case, and is
/// exercised end-to-end via the gateway.)
@Suite("Bridge Alias")
struct BridgeAliasTests {

    @Test("files.* permission matches fs.* (filesystem)")
    func filesAliasesMatchFs() {
        #expect(PortPermission.permissionForMethod("files.read") == PortPermission.permissionForMethod("fs.read"))
        #expect(PortPermission.permissionForMethod("files.write") == PortPermission.permissionForMethod("fs.write"))
        #expect(PortPermission.permissionForMethod("files.pick") == PortPermission.permissionForMethod("fs.pick"))
    }

    @Test("both fs.* and files.* are gated behind .filesystem")
    func bothGatedFilesystem() {
        #expect(PortPermission.permissionForMethod("fs.read") == .filesystem)
        #expect(PortPermission.permissionForMethod("files.read") == .filesystem)
    }
}
