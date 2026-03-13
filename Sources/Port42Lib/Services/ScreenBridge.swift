import Foundation
import ScreenCaptureKit
import AppKit

// MARK: - Screen Bridge (P-504)

/// Captures screenshots via ScreenCaptureKit for ports.
/// Stateless: each capture call is self-contained.
@MainActor
public final class ScreenBridge {

    /// List visible windows with metadata.
    func windows() async -> [String: Any] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            return handleTCCError(error, method: "screen.windows")
        }

        let list: [[String: Any]] = content.windows.compactMap { win in
            // Skip windows with no title or tiny size (menu bar items, etc)
            guard let title = win.title, !title.isEmpty,
                  win.frame.width > 50, win.frame.height > 50 else { return nil }

            let appName = win.owningApplication?.applicationName ?? ""
            let bundleId = win.owningApplication?.bundleIdentifier ?? ""

            return [
                "id": win.windowID,
                "title": title,
                "app": appName,
                "bundleId": bundleId,
                "bounds": [
                    "x": win.frame.origin.x,
                    "y": win.frame.origin.y,
                    "width": win.frame.width,
                    "height": win.frame.height
                ]
            ] as [String: Any]
        }

        NSLog("[Port42] screen.windows: found %d windows", list.count)
        return ["windows": list]
    }

    /// Capture a screenshot. Returns base64 PNG with dimensions.
    func capture(opts: [String: Any]) async -> [String: Any] {
        let scale = min(2.0, max(0.1, opts["scale"] as? Double ?? 1.0))
        let includeSelf = opts["includeSelf"] as? Bool ?? false
        let region = opts["region"] as? [String: Any]
        let displayIdOpt = opts["displayId"] as? UInt32
        let windowIdOpt = opts["windowId"] as? UInt32

        // Fetch available content (triggers TCC prompt on first call)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return handleTCCError(error, method: "screen.capture")
        }

        // Window capture path
        if let windowId = windowIdOpt {
            return await captureWindow(windowId: windowId, scale: scale, content: content)
        }

        // Display capture path
        guard !content.displays.isEmpty else {
            NSLog("[Port42] screen.capture: no displays available")
            return ["error": "no displays available"]
        }

        let display: SCDisplay
        if let targetId = displayIdOpt,
           let found = content.displays.first(where: { $0.displayID == targetId }) {
            display = found
        } else {
            display = content.displays.first!
        }

        // Build content filter
        let filter: SCContentFilter
        if includeSelf {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        } else {
            let excludedApps = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        }

        // Configure capture dimensions
        let config = SCStreamConfiguration()
        let captureWidth: Int
        let captureHeight: Int

        if let r = region {
            let rx = r["x"] as? Double ?? 0
            let ry = r["y"] as? Double ?? 0
            let rw = r["width"] as? Double ?? Double(display.width)
            let rh = r["height"] as? Double ?? Double(display.height)
            config.sourceRect = CGRect(x: rx, y: ry, width: rw, height: rh)
            captureWidth = Int(rw * scale)
            captureHeight = Int(rh * scale)
        } else {
            captureWidth = Int(Double(display.width) * scale)
            captureHeight = Int(Double(display.height) * scale)
        }

        config.width = captureWidth
        config.height = captureHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        return await takeScreenshot(filter: filter, config: config, scale: scale, label: "display")
    }

    // MARK: - Private

    private func captureWindow(windowId: UInt32, scale: Double, content: SCShareableContent) async -> [String: Any] {
        guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
            NSLog("[Port42] screen.capture: window %u not found", windowId)
            return ["error": "window not found"]
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.captureResolution = .best
        // Transparent background for window-only capture
        config.backgroundColor = .clear

        NSLog("[Port42] screen.capture: window '%@' (%u) %.0fx%.0f",
              window.title ?? "untitled", windowId, window.frame.width, window.frame.height)

        return await takeScreenshot(filter: filter, config: config, scale: scale, label: "window '\(window.title ?? "untitled")'")
    }

    private func takeScreenshot(filter: SCContentFilter, config: SCStreamConfiguration, scale: Double, label: String) async -> [String: Any] {
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("[Port42] screen.capture: capture failed: %@", error.localizedDescription)
            return ["error": "screen capture failed: \(error.localizedDescription)"]
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            NSLog("[Port42] screen.capture: PNG conversion failed")
            return ["error": "failed to encode screenshot as PNG"]
        }

        let sizeMB = Double(pngData.count) / 1_048_576.0
        if sizeMB > 10.0 {
            NSLog("[Port42] screen.capture: large image warning (%.1f MB)", sizeMB)
        }

        NSLog("[Port42] screen.capture: %@ %dx%d (%.1f MB, scale=%.1f)",
              label, cgImage.width, cgImage.height, sizeMB, scale)

        return [
            "image": pngData.base64EncodedString(),
            "width": cgImage.width,
            "height": cgImage.height
        ]
    }

    private func handleTCCError(_ error: Error, method: String) -> [String: Any] {
        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamError" ||
           nsError.localizedDescription.lowercased().contains("permission") ||
           nsError.localizedDescription.lowercased().contains("denied") {
            NSLog("[Port42] %@: TCC permission denied: %@", method, error.localizedDescription)
            return ["error": "screen recording permission denied. Check System Settings > Privacy & Security > Screen Recording"]
        }
        NSLog("[Port42] %@: failed to get shareable content: %@", method, error.localizedDescription)
        return ["error": "screen capture failed: \(error.localizedDescription)"]
    }
}
