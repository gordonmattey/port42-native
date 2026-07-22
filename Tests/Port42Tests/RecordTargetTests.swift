import Testing
import Foundation
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

    @Test("window:<id> is a Step 4 error")
    func windowIdDeferred() {
        #expect(err(["target": ["window": 12345]]) != nil)
    }

    @Test("region and display are Step 4 errors")
    func regionDisplayDeferred() {
        let region: [String: Any] = ["target": ["region": ["x": 0, "y": 0, "w": 100, "h": 100]]]
        let display: [String: Any] = ["target": ["display": 1]]
        #expect(err(region) != nil)
        #expect(err(display) != nil)
    }
}
