import Testing
import Foundation
@testable import Port42Lib

/// The output seam's namespace (2026-07-28).
///
/// Input has one door. Output has two mechanisms and seventeen emission points, and until now every
/// one of them named its event with a bare string — including three that took the name from the
/// CALLER. So nothing distinguished what Port42 said from what a port said, on the same topic.
@Suite("Port event kinds — the output namespace")
struct PortEventKindTests {

    // MARK: - a port cannot impersonate Port42

    @Test("a port's own kind is namespaced, so it cannot emit a system event")
    func portKindsAreNamespaced() {
        #expect(PortEventKind.fromPort("state") == "port.state")
        // The whole point: these are the names Port42 itself uses.
        for impersonation in ["driver", "browser.load", "terminal.output", "console", "push"] {
            let emitted = PortEventKind.fromPort(impersonation)
            #expect(emitted != impersonation, "a port emitted the system kind \(impersonation) verbatim")
            #expect(PortEventKind.isSystem(emitted) == false)
        }
    }

    @Test("namespacing is idempotent — a caller reading its own names back does not stack prefixes")
    func idempotent() {
        #expect(PortEventKind.fromPort("port.state") == "port.state")
        #expect(PortEventKind.fromPort(PortEventKind.fromPort("state")) == "port.state")
    }

    @Test("an unnamed event still gets a name a subscriber can match")
    func emptyKind() {
        // A bare `port.` is a name nobody can deliberately match, and an empty kind still has to be
        // addressable, so it becomes something sayable.
        #expect(PortEventKind.fromPort("") == "port.event")
        #expect(PortEventKind.fromPort("   ") == "port.event")
    }

    @Test("isSystem answers the question a subscriber previously could not ask")
    func systemRecognition() {
        #expect(PortEventKind.isSystem("driver"))
        #expect(PortEventKind.isSystem("browser.load"))
        #expect(PortEventKind.isSystem("port.state") == false)
        #expect(PortEventKind.isSystem("something-invented") == false)
    }

    // MARK: - the system side cannot grow a name in the wild

    @Test("every wire name is unique — two cases sharing one string would be indistinguishable")
    func wireNamesAreUnique() {
        let names = PortEventKind.allCases.map(\.wire)
        #expect(Set(names).count == names.count, "duplicate wire name in PortEventKind: \(names)")
    }

    @Test("no publish site names its kind with a bare string literal")
    func noLiteralKinds() throws {
        // THE GATE. Typing `pushEvent` covers the eleven callers that go through the bridge, but the
        // bus can also be published to directly, and that is where a stray literal would land. A new
        // system event must be a case in the enum, or it is a name nobody can enumerate — which is
        // how the seam got seventeen emission points and no namespace in the first place.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard url.lastPathComponent != "PortEventKind.swift" else { continue }   // the definitions
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in src.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                // `kind: "…"` anywhere is a raw name; the typed forms read `kind: PortEventKind.x.wire`
                // or `kind: kind` (a value already namespaced by `fromPort`).
                if t.contains("kind: \"") { offenders.append("\(url.lastPathComponent): \(t.prefix(70))") }
            }
        }
        #expect(offenders.isEmpty, """
            These name an event with a bare string: \(offenders).
            A system kind must be a case in PortEventKind, so the set stays enumerable and a port \
            cannot collide with it.
            """)
    }

    @Test("the enum covers every name the code actually emits")
    func coversWhatIsEmitted() throws {
        // Calibration in the other direction: the gate above stops NEW literals, and this catches a
        // case being deleted from the enum while a caller still names it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var used = Set<String>()
        for case let url as URL in walker where url.pathExtension == "swift" {
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for m in src.ranges(of: "PortEventKind.") {
                let rest = src[m.upperBound...].prefix(40)
                let name = rest.prefix { $0.isLetter || $0.isNumber }
                if !name.isEmpty { used.insert(String(name)) }
            }
        }
        // The non-case members are DERIVED from the type's own source, not listed here.
        //
        // They used to be a hand-written array, and it rotted the first time the enum grew a member
        // (`publish` and `docsMarker`, added when the event kinds started rendering into the docs):
        // a gate that fails because the TYPE gained legitimate API is a gate people learn to edit
        // rather than read. Same rule as everywhere else in this suite — a hand-maintained list of
        // exceptions is a to-do list.
        let enumSource = try String(
            contentsOf: root.appendingPathComponent("Port42Lib/Services/PortEventKind.swift"),
            encoding: .utf8)
        var members = Set(["self", "RawValue", "rawValue", "allCases", "init"])
        for decl in ["static let ", "static var ", "static func ", "var ", "func "] {
            for m in enumSource.ranges(of: decl) {
                let name = enumSource[m.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { members.insert(String(name)) }
            }
        }

        let cases = Set(PortEventKind.allCases.map { "\($0)" })
        let unknown = used.subtracting(cases).subtracting(members)
        #expect(unknown.isEmpty, """
            referenced but not a case: \(unknown)
            Either it is an event kind and belongs in the enum, or it is API and belongs in \
            PortEventKind.swift where this gate derives its member list from.
            """)
    }
}
