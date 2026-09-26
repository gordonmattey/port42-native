import Testing
import Foundation
import GRDB
@testable import Port42Lib

// With the disk busy, synchronous writes on the main thread (a log line, a SQLite commit) held it
// for seconds and gateway calls timed out behind them (Dev4, 2026-09-26). Log lines are written off
// the main thread, and the database commits cheaply (WAL).
@Suite("Main thread does no slow I/O")
struct MainThreadIOTests {

    @Test("the database is in WAL mode with synchronous NORMAL")
    func walMode() throws {
        let path = NSTemporaryDirectory() + "p42-wal-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let db = try DatabaseService(path: path)
        let mode = try db.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        let sync = try db.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA synchronous") }
        #expect(mode == "wal")
        #expect(sync == 1, "synchronous should be NORMAL (1), got \(String(describing: sync))")
    }

    @Test("a slow log sink does not hold the caller, and lines keep their order")
    func logOffCaller() {
        let original = P42Log.sink
        defer { P42Log.sink = original }
        final class Box: @unchecked Sendable { var lines: [String] = []; let lock = NSLock() }
        let box = Box()
        P42Log.sink = { line in
            Thread.sleep(forTimeInterval: 0.2)                      // a disk that is busy
            box.lock.lock(); box.lines.append(line); box.lock.unlock()
        }
        let start = Date()
        for i in 0..<5 { p42log("line %d", i) }
        #expect(Date().timeIntervalSince(start) < 0.1, "logging waited for the write")
        P42Log.drain()
        #expect(box.lines == (0..<5).map { "line \($0)" })
    }

    @Test("no NSLog is left in the app library: it writes on the caller's thread")
    func noNSLog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib")
        var uses: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && url.lastPathComponent != "P42Log.swift" {
            for (i, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains("NSLog(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                uses.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(uses.isEmpty, "use p42log, which writes off the main thread: \(uses)")
    }
}
