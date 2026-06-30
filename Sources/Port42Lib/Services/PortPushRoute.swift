import Foundation

/// Where a `port.push` / `port_push` call should be routed, based on what the target id resolves to.
public enum PortPushTarget: Equatable {
    case terminal   // raw, non-arming inject into a native Ghostty surface
    case web        // port42:data CustomEvent into a WKWebView
    case notFound   // neither — no live port with that id
}

/// The one type-dispatch rule for `port.push`, factored out as a pure function so both the JS bridge
/// and the tool route identically and the precedence is unit-tested. Terminal wins over web: an id is
/// at most one of the two in practice, but stating the precedence makes the contract explicit.
public enum PortPushRoute {
    public static func classify(isTerminal: Bool, isWeb: Bool) -> PortPushTarget {
        if isTerminal { return .terminal }
        if isWeb { return .web }
        return .notFound
    }
}
