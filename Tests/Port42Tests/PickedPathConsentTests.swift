import Testing
import Foundation
@testable import Port42Lib

/// **A pick is the consent for that file, and it lasts** (APP-19).
///
/// fs.pick asked for the broad `.filesystem` grant before showing the panel, and fs.read of the
/// picked file asked for it again, so the user consented to far more than the one file they chose.
/// And the pick lived in memory, so a restart silently took it back.
@Suite("Picked paths: the pick is the consent", .serialized)
@MainActor
struct PickedPathConsentTests {

    func makeTempFile(_ content: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("p42-app19-\(UUID().uuidString).txt")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func caller() -> Principal {
        Principal.port(id: "port-\(UUID().uuidString)", displayName: "a port", spaceId: "space-1")
    }

    @Test("a picked absolute path is read with no .filesystem grant and no card")
    func pickedPathNeedsNoGrant() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        // No card can be shown, so any ask would come back `locked`: success proves nothing was asked.
        appState.permissions.canPrompt = { false }
        let p = caller()
        let path = try makeTempFile("chosen")
        defer { try? FileManager.default.removeItem(atPath: path) }
        appState.grantPickedPath(path, to: p.id)

        var read: BridgeValue?
        var refused: String?
        do { read = try await appState.runBridgeMethod("fs.read", principal: p, args: BridgeArgs(["path": path])) }
        catch let e as BridgeError { refused = e.code }
        #expect(refused == nil, "the pick is the consent: nothing may be asked for this path")
        guard case let .object(o)? = read, case let .string(data)? = o["data"] else { return }
        #expect(data == "chosen")
        #expect(appState.grants(grantee: p.id, on: .machine, zone: p.zone).isEmpty)
    }

    @Test("an unpicked absolute path and a data-dir path still go through the .filesystem gate")
    func otherPathsStillGated() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { false }
        let p = caller()
        for path in ["/etc/hosts", "notes/x.md"] {
            do {
                _ = try await appState.runBridgeMethod("fs.read", principal: p, args: BridgeArgs(["path": path]))
                Issue.record("\(path) was read without consent")
            } catch let e as BridgeError {
                #expect(e.code == BridgeErrorCode.locked.wire, "\(path) should have reached the gate")
            }
        }
    }

    @Test("a pick survives a restart, and revoking everything takes it back")
    func picksPersistAndRevoke() throws {
        let db = try DatabaseService(inMemory: true)
        let p = caller()
        let path = "/Users/someone/Documents/./chosen.txt"
        AppState(db: db).grantPickedPath(path, to: p.id)

        let restarted = AppState(db: db)
        #expect(restarted.principalHasPickedPath("/Users/someone/Documents/chosen.txt", principalId: p.id))
        #expect(!restarted.principalHasPickedPath(path, principalId: "someone-else"))

        restarted.revokeAllGrants(grantee: p.id)
        #expect(!restarted.principalHasPickedPath(path, principalId: p.id))
        #expect(!AppState(db: db).principalHasPickedPath(path, principalId: p.id))
    }

    @Test("fs.pick is refused while locked: no panel over the lock screen")
    func pickRefusedWhileLocked() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { false }
        do {
            _ = try await appState.runBridgeMethod("fs.pick", principal: caller(), args: BridgeArgs([:]))
            Issue.record("a panel was shown while locked")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.locked.wire)
        }
    }
}
