import Foundation

// MARK: - PublishedDocs — facts rendered from code, never restated in prose
//
// **THE RULE: anything a document states about a code structure is RENDERED from that structure.**
// If a fact is typed into prose, it is already drifting; the only question is when someone notices.
//
// The evidence for the rule, all from this repo:
//
//   • Error codes were listed by hand in two documents. They fell out of step, and the fix
//     (2026-07-28) was to render them from `BridgeErrorCode` so drift stopped being expressible.
//   • The Notify envelope gained a `token` field on 2026-07-30 and BOTH documents kept describing
//     it as `{ topic, kind, payload }` — including the one that is GENERATED, because the staleness
//     was in the registry's own description string.
//   • The system event kinds were listed by hand as four of them. There are sixteen.
//
// **Why the existing llms.txt gate could not catch any of this.** `BridgeDocsExportTests` asserts
// `llms.txt == what the registry generates`. That is a CONSISTENCY gate: it proves the artifact was
// regenerated. It cannot know the registry's own prose is wrong, so generated-from-wrong passes it
// byte-for-byte. Consistency and correctness are different properties, and only one of them had a
// gate.
//
// **Adding a renderer is one line here**, and `PublishedDocsTests` fails if any marker survives into
// served text — which is what catches a marker added to a document and never wired up.

public enum PublishedDocs {

    /// Every renderer, applied in order. A new one is a new entry and nothing else.
    ///
    /// `indent` is passed through because the two documents nest their blocks differently
    /// (`llms-preamble.txt` at two spaces, `ports-context.txt` at six).
    public static func render(_ text: String, indent: String = "  ") -> String {
        var out = text
        out = BridgeErrorCode.publish(into: out, indent: indent)
        out = PortNotify.publish(into: out, indent: indent)
        out = PortEventKind.publish(into: out, indent: indent)
        return out
    }

    /// Every marker this module knows how to substitute. The gate uses it to tell an UNWIRED marker
    /// (someone wrote `{{FOO}}` and no renderer handles it) from an unsubstituted known one.
    public static let knownMarkers: [String] = [
        BridgeErrorCode.docsMarker,
        PortNotify.docsMarker,
        PortEventKind.docsMarker,
    ]

    /// Any `{{...}}` left in a rendered document. Non-empty means a document promises a block that
    /// nothing fills, which reaches an agent as literal braces where the facts should be.
    ///
    /// `{{TOOL_NAME}}` and `{{USER}}` are substituted by their own callers at a different stage
    /// (per-tool instruction blocks, the companion prompt), so they are not this module's business.
    public static func unsubstitutedMarkers(in text: String) -> [String] {
        let ignored = ["{{TOOL_NAME}}", "{{USER}}"]
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            let marker = String(rest[open.lowerBound..<close.upperBound])
            if !ignored.contains(marker) { found.append(marker) }
            rest = rest[close.upperBound...]
        }
        return found
    }
}
