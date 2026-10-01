import Foundation

// MARK: - Port Permission

/// Permissions that ports can request. Each permission gates a category of bridge methods.
public enum PortPermission: String, Hashable {
    case ai          // ai.complete, ai.cancel, companions.invoke
    case terminal    // terminal_exec (tool) / terminal.exec (bridge) — the only gated terminal method
    case microphone  // audio.capture, audio.stopCapture
    case camera      // camera.capture, camera.stream, camera.stopStream
    case screen      // screen.capture
    case browser     // browser.open, browser.navigate, browser.capture, browser.text, browser.html, browser.execute, browser.close
    case clipboard     // clipboard.read, clipboard.write
    case filesystem    // fs.pick/read/write (canonical) + files.pick/read/write (aliases)
    case notification  // notify.send
    case automation    // automation.runAppleScript, automation.runJXA
    case rest          // rest.call — HTTP requests to external APIs
    case share         // invite.create: share one port with someone on another machine (nautilus Phase 4)
    case deleteSpace   // space.delete by anyone but the person: asked every time, never kept (APP-11)
    case deleteCompanion   // companions.delete by anyone but the person: asked every time, never kept
    case editCompanion     // companions.update of another companion by anyone but the person: asked every time, never kept

    // The method-to-permission mapping lives on each method's registry declaration
    // (`BridgeMethod.permission`) — the registry is the ONLY permission table. The per-method
    // switch that used to live here was the last parallel copy; it died in the Phase 3 sweep
    // (its sole production caller gated fs.drop, which maps to no permission — a drop is an
    // explicit user gesture scoped to the dropped file; reading contents still goes through
    // fs.read, which the registry gates with .filesystem).

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
        case .share: return "person.2.wave.2"
        case .deleteSpace: return "trash"
        case .deleteCompanion: return "person.fill.xmark"
        case .editCompanion: return "person.crop.circle.badge.pencil"
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
        case .share:
            return (
                title: "Share a Port",
                message: "This wants to make invite links that let someone on another machine open one of your ports. Allow?"
            )
        case .deleteSpace:
            return (
                title: "Delete a Space",
                message: "This wants to delete a space: its ports and terminals close, and the space and its chat are gone. This cannot be undone. Allow?"
            )
        case .editCompanion:
            return (
                title: "Change a Companion",
                message: "This wants to change another companion's settings: its prompt, name, folder or how it runs. It changes how that companion behaves. Allow?"
            )
        case .deleteCompanion:
            return (
                title: "Delete a Companion",
                message: "This wants to delete a companion: it leaves every space, its watches and ports close, and it is gone. This cannot be undone. Allow?"
            )
        }
    }
}
