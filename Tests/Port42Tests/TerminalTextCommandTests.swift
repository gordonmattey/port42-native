import Testing
import AppKit
@testable import Port42Lib

/// Voice corrects the words it streams into a terminal with `deleteBackward`, and takes back the space a
/// hold began with the same way. The terminal view had no handler, so AppKit passed the command up the
/// chain and, finding no taker, beeped and deleted nothing: a long dictation came out repeated, a beep per
/// correction (GM, 2026-09-29). The view must take the command itself.
@Suite("A terminal takes text commands itself")
@MainActor
struct TerminalTextCommandTests {

    /// Records any command that escapes the terminal view, which is what AppKit would have beeped at.
    final class Spy: NSResponder {
        var escaped: [Selector] = []
        override func doCommand(by selector: Selector) { escaped.append(selector) }
        override func deleteBackward(_ sender: Any?) { escaped.append(#selector(NSResponder.deleteBackward(_:))) }
    }

    @Test("deleteBackward is a keypress in the terminal, not passed up to beep")
    func backspaceStaysInTheTerminal() {
        let view = GhosttyInputView(frame: .zero)
        let spy = Spy()
        view.nextResponder = spy
        var typed = 0
        view.onKeyboardInput = { typed += 1 }
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(spy.escaped.isEmpty, "the command left the terminal: AppKit would beep and delete nothing")
        #expect(typed == 1, "a Backspace is the person's input, like a typed key")
    }

    @Test("a command that means nothing to a terminal is dropped silently")
    func otherCommandsAreSilent() {
        let view = GhosttyInputView(frame: .zero)
        let spy = Spy()
        view.nextResponder = spy
        view.doCommand(by: #selector(NSResponder.moveWordLeft(_:)))
        #expect(spy.escaped.isEmpty)
    }
}
