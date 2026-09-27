import Testing
import Foundation
import Security
@testable import Port42Lib

/// An instance's key and its gateway secret outlive launches. A Keychain read that FAILED used to look
/// like "none yet", so a new key was made and saved over the old one: Dev2's identity changed on
/// 2026-09-27 and every tile and invite keyed on it went dead, and its gateway secret changed with it,
/// invalidating every client token. Only a missing item may be made; an unreadable one is never replaced.
@Suite("Kept secrets")
struct KeptSecretTests {

    @Test("found is kept, missing is made and saved, unreadable is neither made nor saved")
    func onlyMissingIsMade() {
        var saved: [String] = []
        let make = { "fresh" }
        #expect(KeptSecret.resolve(.found("old"), make: make, save: { saved.append($0) }) == .kept("old"))
        #expect(saved.isEmpty, "a key that was there was saved over")
        #expect(KeptSecret.resolve(.missing, make: make, save: { saved.append($0) }) == .made("fresh"))
        #expect(saved == ["fresh"])
        saved = []
        let r = KeptSecret.resolve(.unreadable(errSecInteractionNotAllowed), make: make, save: { saved.append($0) })
        #expect(r == .unreadable(errSecInteractionNotAllowed))
        #expect(saved.isEmpty, "a key that could not be read was replaced")
    }
}
