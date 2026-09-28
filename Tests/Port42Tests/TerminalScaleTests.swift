import Testing
import AppKit
import GhosttyKit
@testable import Port42Lib

/// A terminal moved to a screen of another scale keeps its text the right size (GM, 2026-09-28: on a
/// 1x external display every terminal's text went small, with black gaps right and below). A real
/// Ghostty surface in a window: apply each scale and read back the layer's scale and the image's size.
@Suite("Terminal scale", .serialized)
@MainActor
struct TerminalScaleTests {

    func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @Test("at 1x and back at 2x, the layer and the image Ghostty draws both match the view")
    func scaleFollowsTheScreen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p42-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("idle.sh")
        try "#!/bin/sh\necho scale\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let config = TerminalPortConfig(command: script.path, args: [], cwd: dir.path, spaceId: "s", spaceName: "s",
                                        companionName: "", createdBy: "test")
        let built = GhosttyTerminalView.makeDetached(config: config, env: [:], onTee: { _ in }, onInject: { _ in })
        let view = built.view
        defer { built.coordinator.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window.contentView?.addSubview(view)
        pump(1.0)

        for scale in [1.0, 2.0] as [CGFloat] {
            view.applyScale(scale)
            pump(1.0)
            let layer = try #require(view.layer)
            #expect(layer.contentsScale == scale, "the layer showing the image is at \(layer.contentsScale), not \(scale)")
            let size = ghostty_surface_size(try #require(view.surface))
            #expect(CGFloat(size.width_px) == view.bounds.width * scale && CGFloat(size.height_px) == view.bounds.height * scale,
                    "Ghostty draws \(size.width_px)x\(size.height_px) for a \(view.bounds.size) view at \(scale)x")
            if let contents = layer.contents {
                let io = contents as! IOSurfaceRef
                #expect(CGFloat(IOSurfaceGetWidth(io)) / layer.contentsScale == view.bounds.width,
                        "the image shows \(CGFloat(IOSurfaceGetWidth(io)) / layer.contentsScale) points wide in an \(view.bounds.width) point view")
            }
        }
    }
}
