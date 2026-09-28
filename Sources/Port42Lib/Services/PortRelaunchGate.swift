import Foundation

// MARK: - Terminal relaunch gate (NAU-05)
//
// A terminal port keeps its launch configuration, the command it runs at restore and at
// `port.reopen`, where a web port keeps its page. So a verb that replaces a port's "HTML" does not
// change what a terminal shows: it chooses what the terminal launches next. `port.reopen` is gated by
// the port's type in its body, as `port.create` is; this is the other half, for the code writes.

@MainActor
extension AppState {

    /// Refuse a code write to a port whose stored `html` is not a page.
    ///
    /// `port.update`, `patch` and `restore` on a terminal or browser port would rewrite its launch
    /// configuration, and close-then-reopen (or a restart) would run it. Refused for every caller: no
    /// one edits a terminal's configuration through these verbs, and the app rewrites it through its
    /// own path (`rewriteTerminalStartup`). `target` is looked up with `findPort(by:)`, the same match
    /// `updatePort` uses, so the port judged is the port that would be written.
    func requireRewritableCode(_ target: String) throws {
        guard let panel = portWindows.findPort(by: target), panel.portType != "web" else { return }
        throw BridgeError(
            code: .unsupported,
            message: "port '\(target)' is a \(panel.portType) port: what it stores is its launch "
                   + "configuration, not a page, so port.update, patch and restore cannot rewrite it.")
    }
}
