import Foundation

/// Validation for the uniform port-creation primitive (`port.create` / `port_create`), factored out
/// as a pure function so it's unit-testable without a live AppState or window. Both the JS bridge
/// case and the tool case validate through here before dispatching to AppState.createPort.
public enum PortCreateKind: Equatable {
    case web(html: String)
    case terminal(command: String)
    /// An embedded WebKit browser tile with an address bar and real navigation.
    ///
    /// Added 2026-07-27 (GM). `browser` has been a first-class port type for a long time, with its
    /// own `portType`, its own webview configuration, its own navigation delegate and its own tile
    /// chrome, and it was reachable ONLY from the dock. `port.create` rejected it by name.
    ///
    /// That contradicted the unified API's whole claim, that a human and an agent reach the same
    /// surfaces through one bridge: a person could make a browser port with a click and no companion
    /// or agent could make one at all.
    case browser(url: String)
    /// The space's CHAT port, revealed. Idempotent: one chat per space, so this returns the existing
    /// one rather than making a second.
    ///
    /// Added 2026-07-27 (GM). `chat` was excluded on the reasoning that a chat port is created by the
    /// shell per space, not by a caller. That was right about CREATION and wrong about REACH: a chat
    /// can be parked, popped out or closed, and the dock's chat button reopens it (recreating it if
    /// it was deleted outright). A human could do that with a click and no agent could do it at all,
    /// which is the same hole `browser` had.
    ///
    /// A DM is a space (`type == "direct"`), so passing a DM's `space_id` reveals that conversation.
    /// One verb covers both.
    case chat
}

/// Outcome of validating a port.create request: a resolved kind, or a human-readable error message.
/// A purpose-built enum (not `Result`) because the failure payload is a plain `String`, which doesn't
/// conform to `Error`.
public enum PortCreateValidationResult: Equatable {
    case ok(PortCreateKind)
    case error(String)
}

public enum PortCreateValidation {
    /// Resolve a port.create request to a typed kind, or an error.
    /// `web` requires non-empty `html`; `terminal` requires non-empty `command`; `browser` requires
    /// non-empty `url`; any other (or missing) `type` is rejected. Inputs are trimmed; whitespace-only
    /// counts as empty.
    public static func validate(type: String?, html: String?, command: String?,
                                url: String? = nil) -> PortCreateValidationResult {
        switch type {
        case "web":
            let h = (html ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty else { return .error("port.create type:\"web\" requires non-empty 'html'") }
            return .ok(.web(html: h))
        case "terminal":
            let c = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty else { return .error("port.create type:\"terminal\" requires non-empty 'command'") }
            return .ok(.terminal(command: c))
        case "chat":
            // No payload: a space has exactly one chat and `space_id` (handled by the caller) says
            // which. Rejecting stray html/command/url would be pedantry with no upside.
            return .ok(.chat)
        case "browser":
            // `url` is the honest parameter name. `html` is accepted as a fallback because the panel
            // stores a browser's start URL in its `html` field, so a caller reading the stored shape
            // would reasonably reach for it; rejecting that would be a papercut with no upside.
            let u = (url ?? html ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !u.isEmpty else { return .error("port.create type:\"browser\" requires non-empty 'url'") }
            return .ok(.browser(url: u))
        case let other?:
            return .error("port.create: unknown type \"\(other)\" (expected \"web\", \"terminal\", \"browser\" or \"chat\")")
        case nil:
            return .error("port.create requires 'type' (\"web\", \"terminal\", \"browser\" or \"chat\")")
        }
    }
}
