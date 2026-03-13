import Foundation
import AppKit

// MARK: - Clipboard Bridge (P-505)

/// Bridges port42.clipboard.* calls to NSPasteboard.
/// Supports text and image (base64 PNG) clipboard operations.
@MainActor
public final class ClipboardBridge {

    /// Read the current clipboard contents.
    /// Returns text if text is available, or base64 PNG if an image is on the clipboard.
    func read() -> [String: Any] {
        let pb = NSPasteboard.general

        // Try text first
        if let text = pb.string(forType: .string) {
            return ["type": "text", "data": text]
        }

        // Try image (PNG, TIFF, etc)
        if let imgData = pb.data(forType: .png) {
            return ["type": "image", "format": "png", "data": imgData.base64EncodedString()]
        }
        if let imgData = pb.data(forType: .tiff),
           let bitmapRep = NSBitmapImageRep(data: imgData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return ["type": "image", "format": "png", "data": pngData.base64EncodedString()]
        }

        return ["type": "empty"]
    }

    /// Write data to the clipboard.
    /// - text string: sets as plain text
    /// - dict with type "image" and base64 data: sets as PNG image
    func write(_ args: [Any]) -> [String: Any] {
        let pb = NSPasteboard.general

        // Simple text string
        if let text = args.first as? String {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return ["ok": true]
        }

        // Object with type and data
        if let opts = args.first as? [String: Any] {
            let type = opts["type"] as? String ?? "text"
            let data = opts["data"] as? String ?? ""

            if type == "text" {
                pb.clearContents()
                pb.setString(data, forType: .string)
                return ["ok": true]
            }

            if type == "image", let imageData = Data(base64Encoded: data) {
                pb.clearContents()
                pb.setData(imageData, forType: .png)
                return ["ok": true]
            }

            return ["error": "unsupported clipboard type: \(type)"]
        }

        return ["error": "clipboard.write requires a string or {type, data} object"]
    }
}
