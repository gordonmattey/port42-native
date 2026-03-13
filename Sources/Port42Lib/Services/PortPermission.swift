import Foundation

// MARK: - Port Permission

/// Permissions that ports can request. Each permission gates a category of bridge methods.
public enum PortPermission: String, Hashable {
    case ai          // ai.complete, companions.invoke
    // Future:
    // case terminal
    // case microphone
    // case camera
    // case clipboard
    // case filesystem

    /// Map a bridge method name to the permission it requires, or nil if no permission needed.
    public static func permissionForMethod(_ method: String) -> PortPermission? {
        switch method {
        case "ai.complete", "ai.cancel", "companions.invoke":
            return .ai
        default:
            return nil
        }
    }

    /// Human-readable title and message for the permission prompt.
    public var permissionDescription: (title: String, message: String) {
        switch self {
        case .ai:
            return (
                title: "AI Access",
                message: "This port wants to use AI capabilities. This will use your API credits. Allow?"
            )
        }
    }
}
