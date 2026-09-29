import Testing
import Foundation
@testable import Port42Lib

/// **A chat's grip is easy to hit** (#127).
///
/// The space chat's only resize grip was an invisible 16 by 16 zone laid over its bottom-right corner:
/// the rounded corner clipped most of it away, and it sat on top of the send button, so a drag often
/// missed and a click on send could start one. A port's chat had a 6-point invisible strip over its
/// input. Now the grip is a visible strip of the panel's own, below the input, the full width of the
/// chat, and VoiceOver can resize it without a drag.
@Suite("Chat grip (#127)")
struct ChatGripTests {

    @Test("the grip is a full-width strip tall enough to hit, clear of the input")
    func size() {
        #expect(ChatResizeZone.height >= 16)
    }

    @Test("VoiceOver can resize the chat in steps: a corner grows both ways, an edge only down")
    func adjustable() {
        let s = CGSize(width: 400, height: 300)
        #expect(ChatResizeZone.adjusted(s, edge: .corner, grow: true) == CGSize(width: 440, height: 340))
        #expect(ChatResizeZone.adjusted(s, edge: .bottom, grow: true) == CGSize(width: 400, height: 340))
        #expect(ChatResizeZone.adjusted(s, edge: .bottom, grow: false) == CGSize(width: 400, height: 260))
    }

    /// The regression this guards: a grip laid OVER the chat (where the rounded corner clips it and
    /// the send button sits under it) instead of drawn below the input as part of the panel.
    @Test("the grip is drawn below the input as part of the panel, never laid over it")
    func gripIsPartOfThePanel() throws {
        func source(_ file: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/Port42Lib/Views/\(file)"), encoding: .utf8)
        }
        let panel = try source("PortChatPanel.swift")
        let send = try #require(panel.range(of: "Button(action: send)"))
        let grip = try #require(panel.range(of: "if let resize { ChatResizeZone(grip: resize) }"))
        #expect(send.lowerBound < grip.lowerBound, "the grip must come after (below) the input row")
        #expect(panel.contains("accessibilityLabel(\"Resize chat\")") && panel.contains("accessibilityAdjustableAction"),
                "the grip lost its VoiceOver name or its adjust action")
        for file in ["ShellView.swift", "ShellDesktop.swift"] {
            let s = try source(file)
            #expect(!s.contains("ChatResizeZone(size:"), "\(file) lays a resize zone over a chat again")
        }
    }
}
