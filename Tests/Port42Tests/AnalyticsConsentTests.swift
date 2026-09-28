import Testing
import Foundation
@testable import Port42Lib

/// Events from before PostHog starts (the whole first run) are held, not dropped, and discarded when
/// the person says no (2026-09-27: every setup step used to be dropped, so the funnel was never
/// recorded). Nothing is sent without consent: sending needs PostHog, which starts only after opt-in.
@Suite("Analytics holds events until consent")
@MainActor
struct AnalyticsConsentTests {
    @Test("before PostHog starts, events are held, capped, and a no discards them")
    func heldThenDiscarded() {
        let key = "analyticsOptIn"
        let before = UserDefaults.standard.object(forKey: key)
        defer { if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let a = Analytics()
        a.setupStep("name_entered")
        a.setupStep("agent_claude")
        #expect(a.pending.map(\.event) == ["setup_step", "setup_step"])
        for _ in 0..<100 { a.setupStep("x") }
        #expect(a.pending.count == Analytics.maxPending)
        a.setOptIn(false)
        #expect(a.pending.isEmpty, "a no must discard what was held")
    }
}
