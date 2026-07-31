import Testing
import Foundation
@testable import Port42Lib

// Phase L1 (docs/plan-port42-protocol-local-bus.md): the NotifyBus is the 1:N fan-out under
// port.subscribe. These cover the core: one publish reaches many subscribers, topics are isolated,
// unsubscribe stops delivery, and publishing to an empty topic is a cheap no-op.
//
// Plus the slice-02 OUTPUT seam: the payload is a BridgeValue and the envelope carries the emitting
// port's token, so what leaves a port has ONE definition that a remote subscriber can decode.
@Suite("NotifyBus")
@MainActor
struct NotifyBusTests {

    @Test("one publish reaches every subscriber of the topic (1:N)")
    func fanOut() {
        let bus = NotifyBus()
        var a: [String] = []
        var b: [String] = []
        _ = bus.subscribe(topic: "port:X") { a.append($0) }
        _ = bus.subscribe(topic: "port:X") { b.append($0) }
        bus.publish(topic: "port:X", kind: "push", payload: .object(["n": .int(1)]))
        #expect(a.count == 1)
        #expect(b.count == 1)
        // The envelope shape: { topic, kind, payload }.
        #expect(a[0].contains("\"topic\":\"port:X\""))
        #expect(a[0].contains("\"kind\":\"push\""))
    }

    @Test("a subscriber only hears its own topic")
    func topicIsolation() {
        let bus = NotifyBus()
        var got: [String] = []
        _ = bus.subscribe(topic: "port:X") { got.append($0) }
        bus.publish(topic: "port:Y", kind: "push", payload: .int(1))
        #expect(got.isEmpty)
    }

    @Test("unsubscribe stops delivery and clears the topic")
    func unsubscribeStops() {
        let bus = NotifyBus()
        var got: [String] = []
        let id = bus.subscribe(topic: "port:X") { got.append($0) }
        bus.publish(topic: "port:X", kind: "a", payload: .int(1))
        bus.unsubscribe(id: id, topic: "port:X")
        bus.publish(topic: "port:X", kind: "b", payload: .int(2))
        #expect(got.count == 1)
        #expect(!bus.hasSubscribers("port:X"))
    }

    @Test("publishing to a topic with no subscribers is a cheap no-op")
    func noSubscribersNoOp() {
        let bus = NotifyBus()
        bus.publish(topic: "port:none", kind: "x", payload: .int(1))   // must not crash
        #expect(!bus.hasSubscribers("port:none"))
    }

    // MARK: - The OUTPUT seam (slice-02 Part 0)

    @Test("the envelope carries the port's token, resolved by the BUS not the caller")
    func envelopeCarriesToken() throws {
        let bus = NotifyBus()
        // The resolver is the whole point: no publish site passes a token, and one arrives anyway.
        bus.tokenForTopic = { topic in PortNotify.portKey(fromTopic: topic).map { "ep:\($0)" } }
        var got: [String] = []
        _ = bus.subscribe(topic: "port:X") { got.append($0) }
        bus.publish(topic: "port:X", kind: "push", payload: .object(["n": .int(1)]))
        #expect(got.count == 1)
        #expect(got[0].contains("\"token\":\"ep:X\""))
    }

    @Test("a topic with no resolvable token omits the field rather than sending null")
    func tokenOmittedWhenAbsent() {
        let bus = NotifyBus()   // no resolver wired
        var got: [String] = []
        _ = bus.subscribe(topic: "port:X") { got.append($0) }
        bus.publish(topic: "port:X", kind: "push", payload: .int(1))
        #expect(got.count == 1)
        #expect(!got[0].contains("\"token\""))
    }

    @Test("a non-port topic has no port key, so it carries no token")
    func nonPortTopicHasNoKey() {
        #expect(PortNotify.portKey(fromTopic: "chat") == nil)
        #expect(PortNotify.portKey(fromTopic: "ports") == nil)
        #expect(PortNotify.portKey(fromTopic: "port:") == nil)
        #expect(PortNotify.portKey(fromTopic: "port:abc") == "abc")
    }

    // CALIBRATION: this is the defect that typing the payload exposed at HEAD. `PortBridge` built its
    // topic by interpolating an OPTIONAL messageId, so it published to `port:Optional("abc")` while
    // every subscriber listens on `port:abc`. Round-tripping through the two helpers is what makes
    // the two ends unable to disagree — a hand-built string is what let them.
    @Test("topic(forPortKey:) and portKey(fromTopic:) round-trip, so the two ends cannot drift")
    func topicRoundTrips() {
        for key in ["abc", "A1B2-C3", "0", "peer/0"] {
            #expect(PortNotify.portKey(fromTopic: PortNotify.topic(forPortKey: key)) == key)
        }
        // The shape the broken interpolation produced is NOT the shape a subscriber listens on.
        #expect(PortNotify.topic(forPortKey: "abc") != "port:Optional(\"abc\")")
    }

    // MARK: - The gate
    //
    // THE GUARANTEE IS STRUCTURAL, because the alternative already failed. A hand-interpolated topic
    // is what let the emitter and the subscriber disagree for as long as they did, and no unit test
    // of either end alone would have noticed: each was internally consistent. So the property is "a
    // topic is never built by hand", which is greppable, in the same shape as the terminal write
    // funnel and the grant-key scan.

    @Test("NO source file builds a port topic by hand — every one goes through PortNotify")
    func portTopicsAreNeverHandBuilt() throws {
        var offenders: [String] = []
        for (name, text) in try sourceFiles() {
            // `PortNotify` defines the prefix, so it is the one file allowed to spell it.
            guard name != "NotifyBus.swift" else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                // Scoped to lines that name a topic. `BridgeServiceAI` uses a `port:` prefix for an
                // AI token-tracking LABEL, which is a different string that happens to share a
                // spelling — catching it would make this gate a nuisance that gets exempted, and an
                // exempted gate stops being read. Every real emitter and subscriber names its
                // `topic`, including the line this gate exists because of.
                guard t.contains("topic") else { continue }
                if t.contains("\"port:\\(") || t.contains("\"port:\" +") {
                    offenders.append("\(name):\(i + 1) \(t)")
                }
            }
        }
        let found = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty, """
            a port topic is being built by hand:
            \(found)
            Use PortNotify.topic(forPortKey:) / PortNotify.portKey(fromTopic:). Interpolating is how \
            `port:Optional("abc")` shipped past every test both ends had.
            """)
    }

    func sourceFiles() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    @Test("binary survives the envelope, which is why the payload is BridgeValue and not a new type")
    func binaryPayloadSurvives() {
        let notify = PortNotify(topic: "port:X", kind: PortEventKind.screenFrame.wire,
                                payload: .object(["image": .data(base64: "QUJD", mime: "image/jpeg")]),
                                token: "ep:3")
        let json = notify.jsonString()
        #expect(json?.contains("QUJD") == true)
        #expect(json?.contains("\"token\":\"ep:3\"") == true)
    }
}

// MARK: - The exit
//
// The bus fanned out correctly and had no way OUT of the process. `RemoteToolExecutor` served every
// streaming method with `yield: { _ in }`, discarding each event, and the gateway had no frame that
// could have carried one. Measured live before the fix: a WS client subscribed to a real port
// received zero events in ten seconds while that port was updated twice.
//
// These cover the rule that made the fix safe on a request/response door.
@Suite("Notify — the exit")
@MainActor
struct NotifyExitTests {

    @Test("port.subscribe declares itself endless, because it only returns when cancelled")
    func subscribeIsEndless() async throws {
        let w = try makeParityWorld()
        #expect(w.state.bridgeStreamHandles("port.subscribe"))
        #expect(w.state.bridgeStreamIsEndless("port.subscribe"),
                "a method that never returns must say so, or a one-shot door hangs on it")
    }

    @Test("a FINITE stream method is not endless, so HTTP still serves it collect-into-final")
    func completionIsNotEndless() async throws {
        let w = try makeParityWorld()
        #expect(w.state.bridgeStreamHandles("ai.complete"))
        #expect(!w.state.bridgeStreamIsEndless("ai.complete"),
                "ai.complete finishes, so its final value IS the answer on a one-shot transport")
    }

    // CALIBRATION, and the trap it walked into is worth keeping. Removing `endless: true` from
    // `port.subscribe` did NOT fail this test: it HUNG it, because the un-refused method runs until
    // cancelled and that is the exact behavior being replaced. A gate that hangs on a regression is
    // worse than one that fails, since a hung suite reads as an environment problem rather than a
    // defect. This is the third time in this thread that breaking a gate found the TEST wrong.
    //
    // So the wait is BOUNDED and losing the race is the assertion. Re-break `endless` and this
    // reports "never returned", by name, in a second.
    @Test("an endless method over a door that cannot stream is REFUSED, not left to hang")
    func endlessRefusedWithoutAnEmitter() async throws {
        let w = try makeParityWorld()
        let exec = RemoteToolExecutor(appState: w.state, senderId: "probe", senderName: "probe")

        // emit: nil is the HTTP door — no live peer to route mid-call frames to. The wait is BOUNDED
        // and losing the race is the assertion, for the reason in the note above.
        let result: Any? = await withTaskGroup(of: (Any?).self) { group in
            group.addTask { @MainActor in
                await exec.execute(method: "port.subscribe", input: ["id": "anything"], emit: nil)
            }
            group.addTask {
                // GENEROUS on purpose, and it costs nothing when the test passes: the group returns
                // the moment `execute` does, and this task is cancelled with it. It only spends the
                // time when it is catching the regression, and it is bounded so a regression FAILS
                // rather than wedging the suite.
                //
                // 3s was the first value and it flaked under full-suite load: this test passes alone
                // in 0.18s and lost the race at 18.8s in a full run, because the MainActor is
                // contended and `execute` could not even be scheduled. Same load-sensitivity the
                // streaming-cancel test hit at §10a3. A bound this wide still turns an infinite hang
                // into a named failure, which is the whole job.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let dict = result as? [String: Any] else {
            Issue.record("port.subscribe hung on a door that cannot stream instead of refusing. That is the pre-fix behavior; check `endless: true` is still declared.")
            return
        }
        #expect(dict["code"] as? String == BridgeErrorCode.unsupported.wire)
        let msg = (dict["error"] as? String) ?? ""
        // FR10: a refusal names the fix. The caller has a door that works and must be told which.
        #expect(msg.contains("/ws"), "the refusal must name the door that does work")
    }
}
