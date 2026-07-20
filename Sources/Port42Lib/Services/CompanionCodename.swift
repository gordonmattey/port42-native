import Foundation

/// Deterministic, friendly codenames for auto-registered CLI companions
/// (docs/summer2026-todo.md). Seeded by the terminal's panel id so the name is STABLE across
/// respawn (a random-per-launch name would churn the roster) and distinct per panel. Shape is
/// `adjective-animal` (lowercase, mention-safe). Uses a fixed FNV-1a hash, never `String.hashValue`
/// (which is salted per process and would give a different name each run).
enum CompanionCodename {

    private static let adjectives = [
        "quiet", "brave", "clever", "swift", "lucky", "wise", "bold", "calm",
        "keen", "merry", "nimble", "sunny", "witty", "zesty", "cosmic", "amber"
    ]
    private static let animals = [
        "otter", "heron", "lynx", "raven", "fox", "moth", "wren", "seal",
        "hare", "ibis", "koi", "newt", "owl", "pika", "quail", "tern"
    ]

    static func generate(seed: String) -> String {
        let h = fnv1a(seed)
        let adj = adjectives[Int(h & 0xF)]                 // low nibble
        let animal = animals[Int((h >> 4) & 0xF)]          // next nibble
        return "\(adj)-\(animal)"
    }

    /// 64-bit FNV-1a over the seed's UTF-8 bytes. Stable across processes and platforms.
    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
