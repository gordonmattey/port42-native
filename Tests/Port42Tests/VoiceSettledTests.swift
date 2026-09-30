import Testing
@testable import Port42Lib

/// A terminal gets only the words the recognizer has settled on, and only ever more of them, so a TUI's
/// input box never shrinks and regrows while you talk (the flash in a narrow terminal, GM 2026-09-29).
@Suite("Voice streams only settled words into a terminal")
struct VoiceSettledTests {

    @Test("whole words both guesses agree on are settled; the word still being said waits")
    func agreedWords() {
        let s = VoiceInserter.settled(streamed: "", previousGuess: "one thing on vo", guess: "one thing on voice")
        #expect(s == "one thing on ")
    }

    @Test("new words keep coming after the recognizer revises an early one (it used to stall to release)")
    func revisionDoesNotStall() {
        var typed = VoiceInserter.settled(streamed: "", previousGuess: "one thing on voice", guess: "one thing on voice mode")
        #expect(typed == "one thing on voice ")
        // The recognizer capitalizes and punctuates the start; the new words still arrive.
        typed = VoiceInserter.settled(streamed: typed, previousGuess: "One thing, on voice mode is", guess: "One thing, on voice mode is that if")
        #expect(typed.hasPrefix("one thing on voice ") && typed.contains("is"), "stalled: \(typed)")
    }

    @Test("a revision never takes back what is already typed")
    func neverShrinks() {
        let typed = "one thing on "
        let s = VoiceInserter.settled(streamed: typed, previousGuess: "one thing on voice", guess: "won thing on voice mode")
        #expect(s.hasPrefix(typed), "the recognizer changed its mind about an early word; what is typed stays")
    }

    @Test("it grows as more words settle, and a steady guess settles fully")
    func grows() {
        var typed = ""
        let guesses = ["if I", "if I talk a", "if I talk a long", "if I talk a long time", "if I talk a long time"]
        var last = ""
        var history: [String] = []
        for g in guesses {
            typed = VoiceInserter.settled(streamed: typed, previousGuess: last, guess: g)
            last = g
            history.append(typed)
        }
        #expect(zip(history, history.dropFirst()).allSatisfy { $1.hasPrefix($0) }, "it only ever grew: \(history)")
        #expect(typed == "if I talk a long time", "a guess that holds steady is settled whole")
    }
}

/// The hold's sounds are the ones Gordon picked, and never the system's alert sound.
@Suite("Hold-to-talk sounds")
struct VoiceCueTests {
    @Test("Bottle to start and to end, and never Tink (macOS's default alert)")
    func sounds() {
        #expect(VoiceCue.sound(for: .start).name == "Bottle")
        #expect(VoiceCue.sound(for: .end).name == "Bottle")
        #expect(VoiceCue.sound(for: .start).name != "Tink" && VoiceCue.sound(for: .end).name != "Tink")
    }
}
