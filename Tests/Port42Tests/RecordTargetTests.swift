import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

// RecordTarget.parse — the pure target-shape parsing for screen.record (Step 3). Headless.
@Suite("RecordTarget parse")
struct RecordTargetTests {

    private func ok(_ opts: [String: Any]) -> RecordTarget? {
        if case .success(let t) = RecordTarget.parse(opts) { return t }
        return nil
    }
    private func err(_ opts: [String: Any]) -> String? {
        if case .failure(let e) = RecordTarget.parse(opts) { return e.message }
        return nil
    }

    @Test("missing target defaults to self")
    func defaultSelf() {
        if case .selfWindow = ok([:])! {} else { Issue.record("expected selfWindow") }
    }

    @Test("window:self parses to selfWindow")
    func windowSelf() {
        if case .selfWindow = ok(["target": ["window": "self"]])! {} else { Issue.record("expected selfWindow") }
    }

    @Test("port:<udid> parses to .port")
    func port() {
        guard case .port(let id) = ok(["target": ["port": "ABC-123"]]) else { Issue.record("expected .port"); return }
        #expect(id == "ABC-123")
    }

    @Test("ports:[...] parses to .ports")
    func ports() {
        guard case .ports(let ids) = ok(["target": ["ports": ["A", "B"]]]) else { Issue.record("expected .ports"); return }
        #expect(ids == ["A", "B"])
    }

    @Test("empty ports array is an error")
    func emptyPorts() {
        #expect(err(["target": ["ports": [Any]()]]) != nil)
    }

    @Test("window:<id> parses to .window")
    func windowId() {
        guard case .window(let id) = ok(["target": ["window": 12345]]) else { Issue.record("expected .window"); return }
        #expect(id == 12345)
    }

    @Test("region parses to .region (x/y/w/h)")
    func region() {
        let opts: [String: Any] = ["target": ["region": ["x": 10, "y": 20, "w": 300, "h": 200]]]
        guard case .region(let r) = ok(opts) else { Issue.record("expected .region"); return }
        #expect(r == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test("region also accepts width/height keys")
    func regionWidthHeight() {
        let opts: [String: Any] = ["target": ["region": ["x": 0, "y": 0, "width": 640, "height": 480]]]
        guard case .region(let r) = ok(opts) else { Issue.record("expected .region"); return }
        #expect(r == CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    @Test("region without positive w/h is an error")
    func regionInvalid() {
        #expect(err(["target": ["region": ["x": 0, "y": 0]]]) != nil)
    }

    @Test("display parses to .display")
    func display() {
        guard case .display(let id) = ok(["target": ["display": 1]]) else { Issue.record("expected .display"); return }
        #expect(id == 1)
    }

    // supportsCursor — the cursor is a display-compositor overlay, capturable only on display/region.
    @Test("display and region support the cursor")
    func cursorSupportedTargets() {
        #expect(RecordTarget.display(0).supportsCursor)
        #expect(RecordTarget.region(CGRect(x: 0, y: 0, width: 10, height: 10)).supportsCursor)
    }

    @Test("window/self/port targets cannot capture the cursor")
    func cursorUnsupportedTargets() {
        #expect(!RecordTarget.selfWindow.supportsCursor)
        #expect(!RecordTarget.window(1).supportsCursor)
        #expect(!RecordTarget.port("A").supportsCursor)
        #expect(!RecordTarget.ports(["A", "B"]).supportsCursor)
    }
}
