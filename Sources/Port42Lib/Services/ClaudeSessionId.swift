import Foundation
import CryptoKit

/// Deterministic claude session ids for command-companion terminals (docs/plan-companion-cwd.md,
/// step 3). A `.command` companion pins `claude --session-id <id>` so companions that SHARE a
/// space working directory land on DISTINCT transcripts (claude keys the transcript file on the
/// session id: `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`), and a respawn `--resume`s the
/// same id instead of a fresh empty session.
///
/// Key: `"<spaceId>:<companionId>"` for a saved companion; `"<spaceId>:<panelId>"` for an ad-hoc
/// `port.create` terminal that has no companion. Derived via UUIDv5 so the result is a valid UUID
/// (accepted by `--session-id`) and recomputable at every spawn with no storage.
enum ClaudeSessionId {

    /// Fixed Port42 namespace (the last group spells "PORT42" in ASCII: 50 4F 52 54 34 32).
    static let namespace = UUID(uuidString: "A9E4C1F0-42B4-4F42-9E42-504F52543432")!

    /// The session id for a command port. `companionId` present → key on the companion (stable
    /// across relaunch/respawn); nil/empty → key on the panel id (ad-hoc terminals).
    static func derive(spaceId: String, companionId: String?, panelId: String) -> String {
        let entity = (companionId?.isEmpty == false) ? companionId! : panelId
        return uuidV5(namespace: namespace, name: "\(spaceId):\(entity)")
    }

    /// RFC 4122 version-5 (SHA-1) name-based UUID, lowercase canonical form.
    static func uuidV5(namespace: UUID, name: String) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(16 + name.utf8.count)
        let ns = namespace.uuid
        bytes.append(contentsOf: [ns.0, ns.1, ns.2, ns.3, ns.4, ns.5, ns.6, ns.7,
                                  ns.8, ns.9, ns.10, ns.11, ns.12, ns.13, ns.14, ns.15])
        bytes.append(contentsOf: Array(name.utf8))

        var hash = Array(Insecure.SHA1.hash(data: Data(bytes)))   // 20 bytes
        hash[6] = (hash[6] & 0x0F) | 0x50   // version 5
        hash[8] = (hash[8] & 0x3F) | 0x80   // RFC 4122 variant

        let h = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        let s = Array(h)
        func slice(_ a: Int, _ b: Int) -> String { String(s[a..<b]) }
        return "\(slice(0,8))-\(slice(8,12))-\(slice(12,16))-\(slice(16,20))-\(slice(20,32))"
    }
}
