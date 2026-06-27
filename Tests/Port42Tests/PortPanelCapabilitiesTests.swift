import Testing
import Foundation
@testable import Port42Lib

/// Step 5a: capabilities for a port are computed by `PortPanel.mergeCapabilities`, which folds the
/// auto-detected "terminal" capability into the stored set. Re-pointing this off the deleted
/// `TerminalBridge` and onto the native `portType == "terminal"` marker fixes the prior
/// `ports.list` vs `terminal.list` mismatch (a terminal port reported `capabilities: []`). These
/// pin the pure merge behaviour without needing a window/controller.
@Suite("PortPanelCapabilities")
struct PortPanelCapabilitiesTests {

    @Test("terminal port advertises the terminal capability, at front")
    func terminalAddsCapability() {
        let caps = PortPanel.mergeCapabilities([], isTerminal: true)
        #expect(caps == ["terminal"])
    }

    @Test("non-terminal port keeps stored capabilities unchanged")
    func nonTerminalUnchanged() {
        let stored = ["browser", "audio"]
        #expect(PortPanel.mergeCapabilities(stored, isTerminal: false) == stored)
    }

    @Test("terminal merges with stored caps without duplicating")
    func terminalNoDuplicate() {
        // Already declared "terminal" → not added twice.
        #expect(PortPanel.mergeCapabilities(["terminal"], isTerminal: true) == ["terminal"])
        // Stored caps preserved, "terminal" prepended once.
        #expect(PortPanel.mergeCapabilities(["audio"], isTerminal: true) == ["terminal", "audio"])
    }

    @Test("empty + non-terminal stays empty")
    func emptyNonTerminal() {
        #expect(PortPanel.mergeCapabilities([], isTerminal: false) == [])
    }
}
