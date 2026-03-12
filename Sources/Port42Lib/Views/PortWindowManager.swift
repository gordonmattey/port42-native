import SwiftUI

// MARK: - Port Panel

/// A port that has been popped out of the inline message stream.
public struct PortPanel: Identifiable {
    public let id: String
    public let html: String
    public let bridge: PortBridge
    public let channelId: String?
    public let createdBy: String?
    public let messageId: String?
    public let title: String
    public var position: CGPoint
    public var size: CGSize
    public var isDocked: Bool = false

    /// Extract title from HTML <title> tag, fallback to "port"
    static func extractTitle(from html: String) -> String {
        if let start = html.range(of: "<title>"),
           let end = html.range(of: "</title>"),
           start.upperBound < end.lowerBound {
            let title = String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return "port"
    }
}

// MARK: - Port Window Manager

/// Manages popped-out and docked port panels.
@MainActor
public final class PortWindowManager: ObservableObject {

    @Published public var panels: [PortPanel] = []

    /// The single docked panel (right side), if any.
    public var dockedPanel: PortPanel? {
        panels.first(where: { $0.isDocked })
    }

    /// All floating (non-docked) panels.
    public var floatingPanels: [PortPanel] {
        panels.filter { !$0.isDocked }
    }

    /// Pop a port out from inline into a floating panel.
    public func popOut(html: String, bridge: PortBridge, channelId: String?, createdBy: String?, messageId: String?, in bounds: CGSize) {
        // Check for existing panel from same companion in same channel and update it
        if let idx = panels.firstIndex(where: { $0.createdBy == createdBy && $0.channelId == channelId && createdBy != nil }) {
            panels[idx] = PortPanel(
                id: panels[idx].id,
                html: html,
                bridge: bridge,
                channelId: channelId,
                createdBy: createdBy,
                messageId: messageId,
                title: PortPanel.extractTitle(from: html),
                position: panels[idx].position,
                size: panels[idx].size,
                isDocked: panels[idx].isDocked
            )
            return
        }

        let title = PortPanel.extractTitle(from: html)
        let w: CGFloat = min(400, bounds.width * 0.45)
        let h: CGFloat = min(350, bounds.height * 0.5)
        // Offset each new panel slightly so they don't stack exactly
        let offset = CGFloat(panels.count % 5) * 24
        let x = (bounds.width - w) / 2 + offset
        let y = (bounds.height - h) / 2 + offset

        let panel = PortPanel(
            id: UUID().uuidString,
            html: html,
            bridge: bridge,
            channelId: channelId,
            createdBy: createdBy,
            messageId: messageId,
            title: title,
            position: CGPoint(x: x, y: y),
            size: CGSize(width: w, height: h)
        )
        panels.append(panel)
    }

    /// Close a panel by ID.
    public func close(_ id: String) {
        panels.removeAll { $0.id == id }
    }

    /// Dock a panel (undocks any previously docked panel).
    public func dock(_ id: String) {
        for i in panels.indices {
            panels[i].isDocked = (panels[i].id == id)
        }
    }

    /// Undock a panel back to floating.
    public func undock(_ id: String) {
        if let idx = panels.firstIndex(where: { $0.id == id }) {
            panels[idx].isDocked = false
        }
    }

    /// Move a panel to a new position.
    public func move(_ id: String, to position: CGPoint) {
        if let idx = panels.firstIndex(where: { $0.id == id }) {
            panels[idx].position = position
        }
    }

    /// Resize a panel.
    public func resize(_ id: String, to size: CGSize) {
        if let idx = panels.firstIndex(where: { $0.id == id }) {
            panels[idx].size = CGSize(
                width: max(200, size.width),
                height: max(150, size.height)
            )
        }
    }

    /// Bring a panel to front (move to end of array for z-ordering).
    public func bringToFront(_ id: String) {
        if let idx = panels.firstIndex(where: { $0.id == id }), idx != panels.count - 1 {
            let panel = panels.remove(at: idx)
            panels.append(panel)
        }
    }

    /// Check if a given message's port has been popped out.
    public func isPoppedOut(messageId: String?) -> Bool {
        guard let mid = messageId else { return false }
        return panels.contains { $0.messageId == mid }
    }
}
