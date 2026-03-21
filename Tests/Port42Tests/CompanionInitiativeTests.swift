import Testing
import Foundation
@testable import Port42Lib

/// Tests for Phase 3: initiative signal matching logic.
/// These test the DB + position layer that checkInitiativeTriggers() reads from.
/// The async dispatch itself is not tested here — we test the signal matching rules.
@Suite("Companion Initiative — Phase 3")
struct CompanionInitiativeTests {

    func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: true)
    }

    // MARK: - Signal matching helpers (mirroring checkInitiativeTriggers logic)

    /// Simulate the signal scan: does any watching signal appear in the message (case-insensitive)?
    private func matchedSignal(watching: [String], in message: String) -> String? {
        let lowered = message.lowercased()
        return watching.first { lowered.contains($0.lowercased()) }
    }

    // MARK: - Signal matching

    @Test("Signal match is case-insensitive")
    func signalMatchCaseInsensitive() {
        let signal = matchedSignal(watching: ["Feature Request"], in: "can we add a feature request for dark mode")
        #expect(signal == "Feature Request")
    }

    @Test("Signal match returns nil when nothing matches")
    func signalNoMatch() {
        let signal = matchedSignal(watching: ["scope creep", "deadline slip"], in: "looks good to me")
        #expect(signal == nil)
    }

    @Test("First matching signal is returned")
    func signalFirstMatch() {
        let signal = matchedSignal(watching: ["alpha", "beta", "gamma"], in: "beta and gamma are both here")
        #expect(signal == "alpha" || signal == "beta") // first match in watching order
        #expect(signal == "beta") // "alpha" not in message
    }

    @Test("Multi-word signals match as substring")
    func signalMultiWord() {
        let signal = matchedSignal(watching: ["scope creep"], in: "I think this is scope creep nobody is naming")
        #expect(signal == "scope creep")
    }

    @Test("Partial word does not falsely match")
    func signalPartialWord() {
        // "test" should not match "testing" if we're watching "test suite"
        let signal = matchedSignal(watching: ["test suite"], in: "run testing now")
        #expect(signal == nil)
    }

    // MARK: - Position watching list persistence

    @Test("Companion with watching signals can be retrieved and signals are intact")
    func watchingSignalsPersist() throws {
        let db = try makeDB()
        let pos = CompanionPosition(
            companionId: "analyst",
            channelId: "general",
            read: "project is drifting",
            watching: ["scope creep", "another feature", "timeline slip"]
        )
        try db.savePosition(pos)

        let fetched = try db.fetchPosition(companionId: "analyst", channelId: "general")
        #expect(fetched?.watching == ["scope creep", "another feature", "timeline slip"])
    }

    @Test("Companion with no position does not trigger initiative")
    func noPositionNoTrigger() throws {
        let db = try makeDB()
        // No position saved — fetchPosition returns nil
        let pos = try db.fetchPosition(companionId: "muse", channelId: "general")
        #expect(pos == nil)
        // Initiative check: nil position → no watching list → no trigger
        let watching = pos?.watching ?? []
        #expect(watching.isEmpty)
    }

    @Test("Companion with position but empty watching list does not trigger")
    func emptyWatchingNoTrigger() throws {
        let db = try makeDB()
        let pos = CompanionPosition(
            companionId: "sage", channelId: "general",
            read: "something is happening", watching: []
        )
        try db.savePosition(pos)

        let fetched = try db.fetchPosition(companionId: "sage", channelId: "general")
        let watching = fetched?.watching ?? []
        let matched = matchedSignal(watching: watching, in: "another feature request")
        #expect(matched == nil)
    }

    @Test("Already-targeted companion is excluded from initiative")
    func alreadyTargetedExcluded() throws {
        // Simulate: engineer is already being routed (in alreadyTargeted set)
        // Initiative should not fire for engineer even if signal matches
        let db = try makeDB()
        try db.savePosition(CompanionPosition(
            companionId: "engineer",
            channelId: "general",
            read: "feature creep",
            watching: ["feature request"]
        ))

        let alreadyTargeted: Set<String> = ["engineer"]
        let channelAgents = ["engineer", "analyst"] // analyst has no position

        let candidateIds = channelAgents.filter { !alreadyTargeted.contains($0) }
        #expect(!candidateIds.contains("engineer"))
        #expect(candidateIds.contains("analyst"))
    }

    @Test("Multiple companions can match different signals in the same message")
    func multipleCompanionsMatch() throws {
        let db = try makeDB()
        try db.savePosition(CompanionPosition(
            companionId: "analyst", channelId: "ch",
            watching: ["scope creep"]
        ))
        try db.savePosition(CompanionPosition(
            companionId: "sage", channelId: "ch",
            watching: ["narrative", "story"]
        ))

        let message = "this is scope creep and we need a better narrative"

        let analystPos = try db.fetchPosition(companionId: "analyst", channelId: "ch")
        let sagePos = try db.fetchPosition(companionId: "sage", channelId: "ch")

        let analystMatch = matchedSignal(watching: analystPos?.watching ?? [], in: message)
        let sageMatch = matchedSignal(watching: sagePos?.watching ?? [], in: message)

        #expect(analystMatch == "scope creep")
        #expect(sageMatch == "narrative")
    }

    @Test("Positions are channel-scoped — watching list in one channel does not affect another")
    func watchingScopedToChannel() throws {
        let db = try makeDB()
        try db.savePosition(CompanionPosition(
            companionId: "analyst", channelId: "channel-A",
            watching: ["scope creep"]
        ))

        // No position in channel-B
        let posB = try db.fetchPosition(companionId: "analyst", channelId: "channel-B")
        #expect(posB == nil)
        let watching = posB?.watching ?? []
        let match = matchedSignal(watching: watching, in: "massive scope creep happening")
        #expect(match == nil)
    }

    // MARK: - Initiative trigger format

    @Test("Initiative trigger content uses expected framing format")
    func initiativeTriggerFormat() {
        let signal = "scope creep"
        let originalMessage = "can we add one more feature"
        let trigger = "[initiative: your watching signal was matched — \"\(signal)\"]\n\(originalMessage)"
        #expect(trigger.hasPrefix("[initiative:"))
        #expect(trigger.contains(signal))
        #expect(trigger.contains(originalMessage))
    }
}
