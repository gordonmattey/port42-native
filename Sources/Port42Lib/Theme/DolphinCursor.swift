import AppKit

/// Custom dolphin cursor for the swim button hover state.
public final class DolphinCursor {
    public static let shared = DolphinCursor()

    private let cursor: NSCursor

    private init() {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { rect in
            let str = NSAttributedString(
                string: "\u{1F42C}",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 24),
                ]
            )
            let strSize = str.size()
            let origin = NSPoint(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2
            )
            str.draw(at: origin)
            return true
        }
        // Hotspot at center-left of the dolphin (nose area)
        cursor = NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 16))
    }

    public func push() {
        cursor.push()
    }

    public func pop() {
        NSCursor.pop()
    }
}
