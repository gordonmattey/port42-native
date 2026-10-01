import Testing
import AppKit
import SwiftUI
@testable import Port42Lib

// #221: text typed into a port's or a space's chat and not sent was lost when the chat closed or the
// person went somewhere else: it lived in the panel's own state, which went with the panel. It is
// kept per chat in the chat store now, and a panel shows it again when it comes back.

@Suite("A chat keeps what was typed and not sent (#221)")
@MainActor
struct ChatDraftTests {

    @Test("the store keeps each chat's unsent text; empty text drops it")
    func storeKeepsPerChat() {
        let chats = PortChatStore(defaults: nil)
        chats.keepDraft("to the port", for: "port-a")
        chats.keepDraft("to the space", for: "space-1")
        #expect(chats.draft("port-a") == "to the port")
        #expect(chats.draft("space-1") == "to the space")
        chats.keepDraft("", for: "port-a")
        #expect(chats.draft("port-a") == "")
    }

    /// Every string shown in an editable text control under `view`.
    static func typedText(in view: NSView) -> [String] {
        var out: [String] = []
        if let tv = view as? NSTextView, tv.isEditable { out.append(tv.string) }
        if let tf = view as? NSTextField, tf.isEditable { out.append(tf.stringValue) }
        for sub in view.subviews { out += typedText(in: sub) }
        return out
    }

    static func host(_ panel: PortChatPanel) -> (NSWindow, NSHostingView<PortChatPanel>) {
        let hosting = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    static func settle() async {
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 50_000_000); await Task.yield() }
    }

    @Test("a chat opened again shows its unsent text, and a space chat swapped to another space shows that one's")
    func panelShowsKeptText() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.chats.keepDraft("half a thought", for: "space-1")
        state.chats.keepDraft("", for: "space-2")

        let (window, hosting) = Self.host(PortChatPanel(chats: state.chats, appState: state, key: "space-1",
                                                        accent: .green))
        await Self.settle()
        #expect(Self.typedText(in: hosting).contains("half a thought"),
                "the reopened chat's box is empty: \(Self.typedText(in: hosting))")

        // The same panel, now for another space: its box shows that space's text, not this one's.
        hosting.rootView = PortChatPanel(chats: state.chats, appState: state, key: "space-2", accent: .green)
        hosting.layoutSubtreeIfNeeded()
        await Self.settle()
        #expect(!Self.typedText(in: hosting).contains("half a thought"),
                "one space's unsent text followed the person into another space")
        #expect(state.chats.draft("space-1") == "half a thought", "switching away lost the first space's text")
        withExtendedLifetime(window) {}
    }
}
