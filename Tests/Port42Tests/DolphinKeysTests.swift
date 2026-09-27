import Testing
@testable import Port42Lib

/// The boot cinematic's keys (GM, 2026-09-26, release hit list): any key moves one scene on, `s`
/// skips to the end once past the first screen, Esc exits, and a held key does nothing more.
@Suite("Boot cinematic keys")
struct DolphinKeysTests {

    func act(_ code: UInt16, _ chars: String?, repeat r: Bool = false, first: Bool = false, complete: Bool = false) -> DolphinKeys.Action {
        DolphinKeys.action(keyCode: code, characters: chars, isRepeat: r, cinematic: true, onFirstScreen: first, complete: complete)
    }

    @Test("any key moves one scene on, space included")
    func next() {
        #expect(act(49, " ") == .next)
        #expect(act(0, "a") == .next)
        #expect(act(36, "\r") == .next)
        #expect(act(49, " ", first: true) == .next)
    }

    @Test("a held key's repeats do nothing, so holding one cannot run through the scenes")
    func repeats() {
        #expect(act(49, " ", repeat: true) == .ignore)
    }

    @Test("s skips to the end, but not from the first screen, where it is just a key")
    func skip() {
        #expect(act(1, "s") == .skipToEnd)
        #expect(act(1, "s", first: true) == .next)
        #expect(act(1, "s", complete: true) == .next)
    }

    @Test("Esc exits")
    func exit() {
        #expect(act(53, "\u{1b}") == .exit)
    }
}
