import Foundation

// MARK: - Port Permission

/// Permissions that ports can request. Each permission gates a category of bridge methods.
public enum PortPermission: String, Hashable {
    case ai          // ai.complete, ai.cancel, companions.invoke
    case terminal    // terminal.spawn, terminal.send, terminal.resize, terminal.kill
    case microphone  // audio.capture, audio.stopCapture
    case camera      // camera.capture, camera.stream, camera.stopStream
    case screen      // screen.capture
    case clipboard   // clipboard.read, clipboard.write
    case filesystem  // fs.pick, fs.read, fs.write

    /// Map a bridge method name to the permission it requires, or nil if no permission needed.
    public static func permissionForMethod(_ method: String) -> PortPermission? {
        switch method {
        case "ai.complete", "ai.cancel", "companions.invoke":
            return .ai
        case "terminal.spawn", "terminal.send", "terminal.resize", "terminal.kill":
            return .terminal
        case "audio.capture", "audio.stopCapture":
            return .microphone
        case "audio.speak", "audio.play", "audio.stop":
            return nil // audio output doesn't need mic permission
        case "camera.capture", "camera.stream", "camera.stopStream":
            return .camera
        case "screen.capture":
            return .screen
        case "clipboard.read", "clipboard.write":
            return .clipboard
        case "fs.pick", "fs.read", "fs.write", "fs.drop":
            return .filesystem
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
                message: "This port wants to use AI capabilities. This will use your AI subscription tokens. Allow?"
            )
        case .terminal:
            return (
                title: "Terminal Access",
                message: "This port wants to run terminal commands on your computer. Allow?"
            )
        case .microphone:
            return (
                title: "Microphone Access",
                message: "This port wants to access your microphone. Allow?"
            )
        case .camera:
            return (
                title: "Camera Access",
                message: "This port wants to use your camera. Allow?"
            )
        case .screen:
            return (
                title: "Screen Capture",
                message: "This port wants to capture your screen. Allow?"
            )
        case .clipboard:
            return (
                title: "Clipboard Access",
                message: "This port wants to access your clipboard. Allow?"
            )
        case .filesystem:
            return (
                title: "File Access",
                message: "This port wants to access files on your computer. Allow?"
            )
        }
    }
}
