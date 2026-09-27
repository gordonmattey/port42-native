import Testing
import Foundation
@testable import Port42Lib

/// Chats are sized by dragging (GM, 2026-09-26, release hit list): a port's chat down to covering the
/// whole port, the space chat to any size the window has room for.
@Suite("Chat resize")
struct ChatResizeTests {

    @Test("a port's chat: the default until dragged, then the share dragged to, up to the whole port")
    func portChat() {
        #expect(ShellState.portChatHeight(share: nil, body: 600) == 270, "the default is 45% of the body")
        #expect(ShellState.portChatHeight(share: 1, body: 600) == 600, "all the way over the port")
        #expect(ShellState.portChatHeight(share: 0.5, body: 600) == 300)
        #expect(ShellState.portChatHeight(share: 0.01, body: 600) == 100, "never smaller than the minimum")
        #expect(ShellState.portChatHeight(share: 1, body: 0) == 0)
    }

    @Test("a drag past the port's bottom covers it; a drag up to nothing keeps the minimum")
    func dragShare() {
        #expect(ShellState.portChatShare(height: 900, body: 600) == 1)
        #expect(ShellState.portChatShare(height: 300, body: 600) == 0.5)
        #expect(ShellState.portChatShare(height: -50, body: 600) * 600 == 100)
        // A port shorter than the minimum: its chat covers it, no more.
        #expect(ShellState.portChatHeight(share: ShellState.portChatShare(height: 10, body: 80), body: 80) == 80)
    }

    @Test("the space chat: the default, the size dragged to, kept within its minimum and the room")
    func spaceChat() {
        let room = CGSize(width: 1200, height: 700)
        #expect(ShellState.spaceChatSize(nil, room: room) == CGSize(width: 440, height: 360))
        #expect(ShellState.spaceChatSize(CGSize(width: 800, height: 500), room: room) == CGSize(width: 800, height: 500))
        #expect(ShellState.spaceChatSize(CGSize(width: 5000, height: 5000), room: room) == room)
        #expect(ShellState.spaceChatSize(CGSize(width: 10, height: 10), room: room) == CGSize(width: 320, height: 220))
    }
}
