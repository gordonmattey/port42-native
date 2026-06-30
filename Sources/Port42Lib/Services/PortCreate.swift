import Foundation

/// Validation for the uniform port-creation primitive (`port.create` / `port_create`), factored out
/// as a pure function so it's unit-testable without a live AppState or window. Both the JS bridge
/// case and the tool case validate through here before dispatching to AppState.createPort.
public enum PortCreateKind: Equatable {
    case web(html: String)
    case terminal(command: String)
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
    /// `web` requires non-empty `html`; `terminal` requires non-empty `command`; any other (or
    /// missing) `type` is rejected. Inputs are trimmed; whitespace-only counts as empty.
    public static func validate(type: String?, html: String?, command: String?) -> PortCreateValidationResult {
        switch type {
        case "web":
            let h = (html ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty else { return .error("port.create type:\"web\" requires non-empty 'html'") }
            return .ok(.web(html: h))
        case "terminal":
            let c = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty else { return .error("port.create type:\"terminal\" requires non-empty 'command'") }
            return .ok(.terminal(command: c))
        case let other?:
            return .error("port.create: unknown type \"\(other)\" (expected \"web\" or \"terminal\")")
        case nil:
            return .error("port.create requires 'type' (\"web\" or \"terminal\")")
        }
    }
}
