import Testing
import Foundation
@testable import Port42Lib

/// **A revoke retires the token** (APP-13).
///
/// A client token was HMAC(secret, id), a pure function of the id, so it could never be retired: a
/// token that leaked stayed valid for as long as the client existed, and revoking then restoring the
/// client handed back the same string. The generation in the MAC, bumped on every revoke, is what
/// lets a revoke retire a token for good.
@Suite("A revoke retires the token (APP-13)")
@MainActor
struct ClientTokenGenerationTests {

    let secret = "dGVzdC1zZWNyZXQtbm90LWEtcmVhbC1vbmU="

    /// Reactivate a revoked client the way the person does in Settings, written as SQL so the test
    /// does not depend on which restore path is in the tree.
    func reactivate(_ appState: AppState, _ id: String) throws {
        try appState.db.dbQueue.write {
            try $0.execute(sql: "UPDATE clients SET revokedAt = NULL WHERE id = ?", arguments: [id])
        }
    }

    func refusal(_ appState: AppState, _ token: String) -> BridgeError? {
        do { _ = try appState.resolveGatewayCaller(credential: token, senderId: "x"); return nil }
        catch { return error as? BridgeError }
    }

    @Test("a token from before a revoke stays dead after the client comes back")
    func revokeRetiresTheToken() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let reg = appState.clientRegistry
        let leaked = try #require(reg.register(id: "leaky-job", name: "Leaky", kind: .manual))
        #expect(refusal(appState, leaked) == nil, "a fresh token must work")

        appState.revokeClient(id: "leaky-job")
        try reactivate(appState, "leaky-job")
        let reissued = try #require(reg.register(id: "leaky-job", name: "Leaky", kind: .manual))

        #expect(reissued != leaked, "coming back handed out the token that was revoked")
        #expect(refusal(appState, reissued) == nil, "the re-issued token must work")
        let e = refusal(appState, leaked)
        #expect(e?.code == BridgeErrorCode.authRevoked.rawValue, "the leaked token still works: \(String(describing: e))")
        #expect(e?.message.contains("retired") == true, "say it was retired, not 'another instance'")
        reg.revoke(id: "leaky-job")
    }

    @Test("generation 0 is the old format, so tokens minted before APP-13 still verify")
    func generationZeroIsBackwardCompatible() {
        #expect(ClientRegistry.mac(id: "claude-code", secret: secret, generation: 0)
                == ClientRegistry.mac(id: "claude-code", secret: secret))
        let g1 = ClientRegistry.token(id: "claude-code", secret: secret, generation: 1)
        #expect(g1 != ClientRegistry.token(id: "claude-code", secret: secret))
        #expect(ClientRegistry.verify(token: g1, secret: secret, generation: 1) == "claude-code")
        #expect(ClientRegistry.verify(token: g1, secret: secret, generation: 0) == nil)
        #expect(ClientRegistry.verify(token: g1, secret: secret, generation: 2) == nil)
    }

    @Test("the generation survives a read of the client row")
    func generationIsStored() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.clientRegistry.register(id: "gen-job", name: "Gen", kind: .manual)
        #expect(appState.clientRegistry.client(id: "gen-job")?.generation == 0)
        appState.revokeClient(id: "gen-job")
        #expect(appState.clientRegistry.client(id: "gen-job")?.generation == 1)
    }
}
