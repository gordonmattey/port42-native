import Testing
import Foundation
@testable import Port42Lib

@Suite("TerminalPortConfig")
struct TerminalPortConfigTests {

    // Regression: Swift's synthesized Decodable throws keyNotFound on a missing key even when
    // the property has a default, so adding a new field would silently break decoding of every
    // already-stored panel (→ blank terminal). The tolerant init(from:) must apply defaults.
    @Test("decodes legacy JSON missing startupCommand, companionPrompt, and env")
    func tolerantDecodeOfLegacyJSON() throws {
        let json = #"{"command":"/bin/zsh","args":[],"cwd":"/Users/x","spaceId":"s","spaceName":"n","companionName":"c","createdBy":"u"}"#
        let cfg = try JSONDecoder().decode(TerminalPortConfig.self, from: Data(json.utf8))
        #expect(cfg.command == "/bin/zsh")
        #expect(cfg.startupCommand == "")
        #expect(cfg.companionPrompt == "")
        #expect(cfg.env.isEmpty)
        #expect(cfg.companionName == "c")
    }

    @Test("round-trips all fields (incl. env) through encode/decode")
    func roundTrip() throws {
        let original = TerminalPortConfig(
            command: "/bin/zsh", args: ["-l"], startupCommand: "claude", cwd: "/tmp",
            spaceId: "sid", spaceName: "Demo", companionName: "claude5", createdBy: "u1",
            companionPrompt: "You are claude5.", env: ["FOO": "bar", "BAZ": "1"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalPortConfig.self, from: data)
        #expect(decoded.startupCommand == "claude")
        #expect(decoded.companionPrompt == "You are claude5.")
        #expect(decoded.args == ["-l"])
        #expect(decoded.cwd == "/tmp")
        #expect(decoded.env == ["FOO": "bar", "BAZ": "1"])
    }
}
