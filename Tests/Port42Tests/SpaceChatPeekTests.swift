import Testing
import Foundation
@testable import Port42Lib

// #136: the space chat drops down at the desktop's top-left, exactly where the peek rail is, and it
// is hosted above the desktop. A peek raised while the person was in the chat (the companion they
// were talking to asking them to look) landed under it and was missed. While a peek is up the chat
// now sits right of the rail, even in its full view. Headless: the geometry ShellView uses.

@Suite("A peek shows while you are in the space chat (#136)")
struct SpaceChatPeekTests {

    /// The chat's horizontal span in a view `width` wide, as ShellView lays it out: from its leading
    /// edge, as wide as its room allows (the full view fills the room).
    func chatSpan(width: CGFloat, peeks: Int, expanded: Bool) -> ClosedRange<CGFloat> {
        let lead = ShellState.spaceChatLeading(peeks: peeks)
        let room = CGSize(width: ShellState.spaceChatRoomWidth(width, peeks: peeks), height: 800)
        let w = expanded ? ShellState.spaceChatSize(room, room: room).width
                         : ShellState.spaceChatSize(nil, room: room).width
        return lead...(lead + w)
    }

    @Test("with peeks up, no rail slot is under the chat, in the drop-down or the full view")
    func peeksClearOfChat() {
        for width in [1280.0, 1512.0, 2560.0] as [CGFloat] {
            for expanded in [false, true] {
                let chat = chatSpan(width: width, peeks: 3, expanded: expanded)
                for i in 0..<3 {
                    let slot = ShellPlacement.railSlot(i, in: CGSize(width: width, height: 900))
                    #expect(slot.maxX < chat.lowerBound,
                            "peek \(i) (x \(slot.minX)...\(slot.maxX)) is under the space chat (from x \(chat.lowerBound)), width \(width), expanded \(expanded)")
                }
                #expect(chat.upperBound <= width - ShellState.spaceChatInset, "the chat runs off the right edge")
            }
        }
    }

    @Test("with no peeks, the chat drops down where it always did")
    func noPeeksUnchanged() {
        #expect(ShellState.spaceChatLeading(peeks: 0) == 60)
        let expected: CGFloat = 1512 - 120
        #expect(ShellState.spaceChatRoomWidth(1512, peeks: 0) == expected)
    }
}
