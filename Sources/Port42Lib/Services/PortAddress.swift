import Foundation

// MARK: - PortAddress
//
// The address grammar for a port, the keystone of the local bus (docs/plan-port42-protocol-local-bus.md,
// Phase L0). A port is an addressable actor; this is how you name one. The canonical local form is
//
//     port42://space/<spaceId>/<portId>
//
// which is the UERP `port42://[type]/[id]/[path]` shape (type = space, id = spaceId, path = portId),
// matching `membrane/slice-02-cross-instance.md`. Cross-instance staging later prefixes an instance
// segment (`<peerID>`) WITHOUT changing this local form — that is the whole point of proving it local
// first.
//
// A bare id (UDID / terminal name / port title) stays a valid short local alias: `parse` returns nil for
// it (it is not an address), and the resolver falls back to `PortAddress(spaceId: nil, portId: bareId)`.
// So nothing that passes a bare id today breaks.

public struct PortAddress: Equatable {
    /// The INSTANCE that owns this port. nil = this one.
    ///
    /// Slice-02 milestone B, step 1. Part 0 ticked ADDRESS on the strength of `PortObject`, which is
    /// peer-qualified — but that is the GRANT object, a different type. This grammar had two path
    /// segments and returned nil for a third, so the resolver could not name a port on another
    /// machine at all.
    ///
    /// The local form is untouched, which is what proving it locally first bought.
    public let peerID: String?
    /// The space segment. nil = "current / any space" — what a bare-id local alias means.
    public let spaceId: String?
    /// The port segment: a canonical udid, or a short local alias (terminal name / port title).
    public let portId: String

    public init(peerID: String? = nil, spaceId: String?, portId: String) {
        self.peerID = peerID
        self.spaceId = spaceId
        self.portId = portId
    }

    /// Parse either form. The HOST decides which:
    ///
    ///     port42://space/<spaceId>/<portId>     local, 2 path segments
    ///     port42://<peer>/<portId>              remote, 1 path segment (nautilus Phase 4, 4.2)
    ///
    /// Returns nil for anything else, including a bare id (not an address) and a `port42://space?…`
    /// invite (query items and no path). The remote form carries no space: a port id is unique on its
    /// machine, a space is where a port sits and can change, and naming it would hand a guest the id
    /// of a space it was not given. A host is the `space` marker or a peer id, never both, because a
    /// peer id is 52 base32 characters and `space` is not one.
    public static func parse(_ s: String) -> PortAddress? {
        guard let comps = URLComponents(string: s), comps.scheme == "port42",
              let host = comps.host, !host.isEmpty else { return nil }
        let segments = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if host == "space" {
            guard segments.count == 2, !segments[0].isEmpty, !segments[1].isEmpty else { return nil }
            // `_` is the reserved nil-space placeholder, so canonical ∘ parse is identity for a
            // nil-space alias too (a bare id round-trips through its canonical form).
            let spaceId: String? = (segments[0] == "_") ? nil : segments[0]
            return PortAddress(spaceId: spaceId, portId: segments[1])
        }
        // A peer id is case-blind base32; a linkifier may have uppercased it.
        let peer = host.lowercased()
        guard isPeerID(peer), segments.count == 1, !segments[0].isEmpty else { return nil }
        return PortAddress(peerID: peer, spaceId: nil, portId: segments[0])
    }

    /// A peer id: the lowercase base32 (no padding) of a 32-byte Ed25519 public key, 52 characters.
    /// The gateway derives it (gateway/peer.go); this only recognizes one.
    public static func isPeerID(_ s: String) -> Bool {
        s.count == 52 && s.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }
    }

    /// The canonical string form. A nil space renders as the reserved `_` placeholder, which `parse`
    /// maps back to nil — so the round-trip is stable for both a real address and a bare-id alias.
    /// A nil peer renders the LOCAL form byte for byte, unchanged from before step 1.
    public var canonical: String {
        guard let peerID else { return "port42://space/\(spaceId ?? "_")/\(portId)" }
        return "port42://\(peerID)/\(portId)"
    }
}
