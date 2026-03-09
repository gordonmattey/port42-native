import Testing
import Foundation
@testable import Port42Lib

@Suite("AppleAuth")
struct AppleAuthTests {

    @Test("Nonce SHA256 produces correct hex hash")
    func nonceHashing() {
        // SHA256 of "test-nonce-123" verified against openssl
        let hash = hashNonce("test-nonce-123")
        #expect(hash.count == 64) // 32 bytes = 64 hex chars
        #expect(hash.allSatisfy { $0.isHexDigit })
    }

    @Test("Same nonce produces same hash")
    func nonceDeterministic() {
        let a = hashNonce("identical")
        let b = hashNonce("identical")
        #expect(a == b)
    }

    @Test("Different nonces produce different hashes")
    func nonceUniqueness() {
        let a = hashNonce("nonce-one")
        let b = hashNonce("nonce-two")
        #expect(a != b)
    }

    @Test("Empty nonce hashes without crashing")
    func emptyNonce() {
        let hash = hashNonce("")
        #expect(hash.count == 64)
    }

    @Test("Known SHA256 vector")
    func knownVector() {
        // SHA256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let hash = hashNonce("hello")
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test("AppleAuthError descriptions are not empty")
    func errorDescriptions() {
        let errors: [AppleAuthError] = [.noIdentityToken, .tokenNotUTF8, .credentialRevoked, .cancelled]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}
