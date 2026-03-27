import Foundation

// MARK: - Port Permission

/// Permissions that ports can request. Each permission gates a category of bridge methods.
public enum PortPermission: String, Hashable {
    case ai          // ai.complete, ai.cancel, companions.invoke
    case terminal    // terminal.spawn, terminal.send, terminal.resize, terminal.kill
    case microphone  // audio.capture, audio.stopCapture
    case camera      // camera.capture, camera.stream, camera.stopStream
    case screen      // screen.capture
    case browser     // browser.open, browser.navigate, browser.capture, browser.text, browser.html, browser.execute, browser.close
    case clipboard     // clipboard.read, clipboard.write
    case filesystem    // fs.pick, fs.read, fs.write
    case notification  // notify.send
    case automation    // automation.runAppleScript, automation.runJXA
    case rest          // rest.call — HTTP requests to external APIs

    /// Map a bridge method name to the permission it requires, or nil if no permission needed.
    public static func permissionForMethod(_ method: String) -> PortPermission? {
        switch method {
        case "ai.complete", "ai.cancel", "companions.invoke":
            return .ai
        case "terminal.spawn":
            return .terminal
        case "terminal.send", "terminal.resize", "terminal.kill":
            return nil // operations on already-permitted sessions
        case "audio.capture", "audio.stopCapture":
            return .microphone
        case "audio.speak", "audio.play", "audio.stop":
            return nil // audio output doesn't need mic permission
        case "camera.capture", "camera.stream":
            return .camera
        case "camera.stopStream":
            return nil // stopping already-permitted stream
        case "screen.capture", "screen.windows", "screen.stream":
            return .screen
        case "screen.stopStream":
            return nil // stopping already-permitted stream
        case "browser.open", "browser.navigate", "browser.capture", "browser.text", "browser.html", "browser.execute", "browser.close":
            return .browser
        case "clipboard.read", "clipboard.write":
            return .clipboard
        case "fs.pick", "fs.read", "fs.write", "fs.drop":
            return .filesystem
        case "notify.send":
            return .notification
        case "automation.runAppleScript", "automation.runJXA":
            return .automation
        case "rest.call":
            return .rest
        default:
            return nil
        }
    }

    /// SF Symbol icon name for the permission type.
    public var iconName: String {
        switch self {
        case .ai: return "brain"
        case .terminal: return "terminal"
        case .microphone: return "mic"
        case .camera: return "camera"
        case .screen: return "rectangle.on.rectangle"
        case .browser: return "globe"
        case .clipboard: return "doc.on.clipboard"
        case .filesystem: return "folder"
        case .notification: return "bell"
        case .automation: return "gearshape.2"
        case .rest: return "network"
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
        case .browser:
            return (
                title: "Web Browsing",
                message: "This port wants to browse the web. It can load pages, extract content, and take screenshots. Allow?"
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
        case .notification:
            return (
                title: "Notification Access",
                message: "This port wants to send you system notifications. Allow?"
            )
        case .automation:
            return (
                title: "Automation Access",
                message: "This port wants to control other apps on your Mac using automation scripts. It can send commands to Finder, Mail, and other scriptable applications. Allow?"
            )
        case .rest:
            return (
                title: "HTTP Access",
                message: "This companion wants to make HTTP requests to external APIs. Allow?"
            )
        }
    }
}
