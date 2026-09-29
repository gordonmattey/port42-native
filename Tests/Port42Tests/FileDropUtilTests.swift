import Testing
import AppKit
import Foundation
@testable import Port42Lib

/// Step 5c: dropped file paths are shell-escaped before being pasted into a terminal or chat draft.
/// `escapeDroppedPaths` is the shared pure helper; pin its quoting here.
@Suite("FileDropUtil")
struct FileDropUtilTests {

    @Test("simple path is left bare (no quotes)")
    func singleSimple() {
        #expect(escapeDroppedPaths(["/Users/gordon/file.txt"]) == "/Users/gordon/file.txt")
    }

    @Test("path with spaces is quoted")
    func spaces() {
        #expect(escapeDroppedPaths(["/Users/gordon/My File.txt"]) == "'/Users/gordon/My File.txt'")
    }

    @Test("embedded single quote is escaped as '\\''")
    func embeddedQuote() {
        #expect(escapeDroppedPaths(["/tmp/it's mine"]) == "'/tmp/it'\\''s mine'")
    }

    @Test("multiple paths: bare unless they need quoting")
    func multiple() {
        let out = escapeDroppedPaths(["/a/one.txt", "/b/two file.txt"])
        #expect(out == "/a/one.txt '/b/two file.txt'")
    }

    @Test("empty list yields empty string")
    func empty() {
        #expect(escapeDroppedPaths([]) == "")
    }
}

/// ⌘V in a terminal pastes files as paths and an image as the path of a PNG (GM, 2026-09-29: pasting
/// an image did nothing).
@Suite("What ⌘V pastes into a terminal")
struct TerminalPasteTests {
    func board() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("port42-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test("text pastes as itself")
    func text() {
        let pb = board()
        pb.setString("hello", forType: .string)
        #expect(terminalPasteText(from: pb) == "hello")
    }

    @Test("an image with no text is saved as a PNG and its path is pasted")
    func image() throws {
        let pb = board()
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        pb.writeObjects([img])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paste-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasted = try #require(terminalPasteText(from: pb, imageDir: dir))
        #expect(pasted.hasPrefix(dir.path) && pasted.hasSuffix(".png"), "pasted \(pasted)")
        let data = try Data(contentsOf: URL(fileURLWithPath: pasted))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "not a PNG")
    }

    @Test("files copied in Finder paste as their paths, quoted when they need it")
    func files() {
        let pb = board()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/a b.png") as NSURL, URL(fileURLWithPath: "/tmp/c.txt") as NSURL])
        #expect(terminalPasteText(from: pb) == "'/tmp/a b.png' /tmp/c.txt")
    }

    @Test("an empty clipboard pastes nothing")
    func empty() {
        #expect(terminalPasteText(from: board()) == nil)
    }
}
