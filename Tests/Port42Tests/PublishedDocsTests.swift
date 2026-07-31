import Testing
import Foundation
@testable import Port42Lib

// The rule `PublishedDocs` exists to enforce: a fact about a code structure is RENDERED from that
// structure, never typed into prose.
//
// This suite is the gate the docs did not have. `BridgeDocsExportTests` proves llms.txt matches what
// the registry GENERATES, which is consistency; it passed happily while the registry itself described
// a Notify envelope that had gained a field. These tests check the other property.
@Suite("Published docs")
struct PublishedDocsTests {

    // THE GATE. A marker left in served text reaches an agent as literal braces where the facts
    // should be, and it is the exact failure of adding `{{FOO}}` to a document and forgetting to
    // wire a renderer. Both served surfaces are checked, because they load through different code.
    @Test("no marker survives into anything an agent reads")
    @MainActor
    func noMarkerSurvivesRendering() throws {
        let reference = generateAPIReference(try makeParityWorld().state,
                                             gatewayPort: GatewayProcess.defaultPort)
        let manual = AppState.portsContext

        for (name, text) in [("llms.txt / help", reference), ("help(topic: ports)", manual)] {
            let left = PublishedDocs.unsubstitutedMarkers(in: text)
            #expect(left.isEmpty, "\(name) still contains \(left.joined(separator: ", ")) — add a renderer to PublishedDocs.render")
        }
    }

    @Test("every renderer actually fires: its marker is gone and its content is present")
    @MainActor
    func everyRendererProducesContent() throws {
        let reference = generateAPIReference(try makeParityWorld().state,
                                             gatewayPort: GatewayProcess.defaultPort)
        let manual = AppState.portsContext
        let both = reference + "\n" + manual

        for marker in PublishedDocs.knownMarkers {
            #expect(!both.contains(marker), "\(marker) was not substituted")
        }
        // Content, not just absence: a renderer returning "" would pass the check above.
        #expect(both.contains("stale_write"), "the error codes did not render")
        #expect(both.contains("no re-read"), "the Notify envelope did not render")
        #expect(both.contains("terminal.output"), "the event kinds did not render")
    }

    // The specific staleness that started this. The envelope description must come from the type, so
    // a field added to `PortNotify` reaches both documents by existing rather than by being noticed.
    @Test("the envelope block names every field of PortNotify, token included")
    func envelopeBlockIsCompleteFromTheType() {
        let shape = PortNotify.publishedShape()
        for field in ["topic", "kind", "payload", PortActivity.tokenKey] {
            #expect(shape.contains(field), "the published envelope omits \(field)")
        }
    }

    // The hand-typed list said four. There are sixteen.
    @Test("the event-kind block lists EVERY system kind, not the four someone remembered")
    func everyEventKindIsPublished() {
        let block = PortEventKind.publishedKinds()
        for kind in PortEventKind.allCases {
            #expect(block.contains(kind.wire), "the published kinds omit \(kind.wire)")
        }
        #expect(PortEventKind.allCases.count > 4,
                "precondition: the hand-written list named four, which is why this is rendered")
    }
}
