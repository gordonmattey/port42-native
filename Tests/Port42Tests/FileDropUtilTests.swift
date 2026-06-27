import Testing
import Foundation
@testable import Port42Lib

/// Step 5c: dropped file paths are shell-escaped before being pasted into a terminal or chat draft.
/// `escapeDroppedPaths` is the shared pure helper; pin its quoting here.
@Suite("FileDropUtil")
struct FileDropUtilTests {

    @Test("single simple path is single-quoted")
    func singleSimple() {
        #expect(escapeDroppedPaths(["/Users/gordon/file.txt"]) == "'/Users/gordon/file.txt'")
    }

    @Test("path with spaces stays one quoted token")
    func spaces() {
        #expect(escapeDroppedPaths(["/Users/gordon/My File.txt"]) == "'/Users/gordon/My File.txt'")
    }

    @Test("embedded single quote is escaped as '\\''")
    func embeddedQuote() {
        #expect(escapeDroppedPaths(["/tmp/it's mine"]) == "'/tmp/it'\\''s mine'")
    }

    @Test("multiple paths are space-separated, each quoted")
    func multiple() {
        let out = escapeDroppedPaths(["/a/one.txt", "/b/two file.txt"])
        #expect(out == "'/a/one.txt' '/b/two file.txt'")
    }

    @Test("empty list yields empty string")
    func empty() {
        #expect(escapeDroppedPaths([]) == "")
    }
}
