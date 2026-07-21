import Foundation

// MARK: - Port-Owned Resource (backlog 0.5, the exhaustive port teardown)

/// A device bridge that holds an ongoing resource on behalf of a port: a live mic capture, a camera
/// or screen stream, a speaking synthesizer, an audio player, a browser session. Closing the port
/// must release every such resource it acquired, and a new capability must not be addable without a
/// teardown seam.
///
/// Teardown is keyed on the port's STABLE id (`PortBridge.messageId`), not the bridge instance. The
/// id survives instance re-creation (a port re-made on restart is a new bridge for the same logical
/// port) and cannot be reused the way a freed object address can, so a "stop everything port X holds"
/// is reachable from the app (and, later, the gateway). The weak owner reference the bridges keep is
/// only for event delivery; the match key is the id.
@MainActor
public protocol PortOwnedResource {
    /// Release every resource this bridge holds for `id`, and nothing owned by any other port.
    /// A no-op when this port owns nothing here, so it is safe to call from both the close path and
    /// the `deinit` backstop.
    func releaseIfOwned(byPortId id: String)
}
