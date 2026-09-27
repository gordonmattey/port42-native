import Testing
import Foundation

/// A debug build never starts the updater. A dev instance whose updater could not start put up a
/// modal alert at launch, and every call to it waited on that alert until someone clicked it (Dev6,
/// 2026-09-27). The app target is not importable here, so the gate reads its source.
@Suite("Dev builds do not update themselves")
struct DevUpdaterTests {

    @Test("the updater starts only outside DEBUG")
    func updaterOffInDebug() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Port42/Port42App.swift"), encoding: .utf8)
        let compact = app.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        #expect(compact.contains("#ifDEBUGletstartUpdater=false#elseletstartUpdater=true#endif"),
                "the debug guard on the updater is gone")
        #expect(compact.contains("startingUpdater:startUpdater"), "the updater starts regardless of the build")
    }
}
