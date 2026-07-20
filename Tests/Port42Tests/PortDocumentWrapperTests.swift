import Testing
import Foundation
@testable import Port42Lib

// ONE port-document wrapper (Phase 4 closeout). The CSP + theme + module-script wrapper used to be
// duplicated in PortView (inline ports) and PortWebViewFactory (desktop tiles), differing only in
// the deliberate overflow choice — so a CSP or theme edit in one silently missed the other.
@Suite("Port document wrapper")
struct PortDocumentWrapperTests {

    @Test("the CSP is declared in exactly one source file — the wrapper cannot drift")
    func oneWrapperSource() throws {
        let offenders = try BridgePrincipalTests.libSources()
            .filter { $0.source.contains("Content-Security-Policy") }
            .map(\.file)
        #expect(offenders == ["PortWindowManager.swift"],
                "the port document wrapper must live only in PortWebViewFactory: \(offenders)")
    }

    @Test("the wrapper carries CSP, module conversion, and the caller's overflow choice")
    func wrapperShape() {
        let tile = PortWebViewFactory.wrapHTML("<script>1</script><div>x</div>")
        #expect(tile.contains("Content-Security-Policy"))
        #expect(tile.contains("<script type=\"module\">1</script>"))
        #expect(tile.contains("overflow: auto"))

        let inline = PortWebViewFactory.wrapHTML("<div>x</div>", overflow: "hidden")
        #expect(inline.contains("overflow: hidden"))
        // The overflow choice is the ONLY difference between the two call sites' documents.
        #expect(tile.replacingOccurrences(of: "overflow: auto", with: "overflow: hidden") ==
                PortWebViewFactory.wrapHTML("<script>1</script><div>x</div>", overflow: "hidden"))
    }
}
