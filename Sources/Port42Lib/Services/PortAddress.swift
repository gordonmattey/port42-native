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
    /// The space segment. nil = "current / any space" — what a bare-id local alias means.
    public let spaceId: String?
    /// The port segment: a canonical udid, or a short local alias (terminal name / port title).
    public let portId: String

    public init(spaceId: String?, portId: String) {
        self.spaceId = spaceId
        self.portId = portId
    }

    /// Parse the canonical `port42://space/<spaceId>/<portId>` form. Returns nil for anything else —
    /// including a bare id (not an address) and a `port42://space?…` space *invite* (that form carries
    /// query items and no path; a port address carries exactly two path segments and is disjoint from it).
    public static func parse(_ s: String) -> PortAddress? {
        guard let comps = URLComponents(string: s),
              comps.scheme == "port42",
              comps.host == "space" else { return nil }
        // path is "/<spaceId>/<portId>"; split and drop the empty leading component.
        let segments = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2 else { return nil }
        let rawSpace = segments[0]
        let portId = segments[1]
        guard !rawSpace.isEmpty, !portId.isEmpty else { return nil }
        // `_` is the reserved nil-space placeholder, so canonical ∘ parse is identity for a nil-space
        // alias too (a bare id round-trips through its canonical form).
        let spaceId: String? = (rawSpace == "_") ? nil : rawSpace
        return PortAddress(spaceId: spaceId, portId: portId)
    }

    /// The canonical string form. A nil space renders as the reserved `_` placeholder, which `parse`
    /// maps back to nil — so the round-trip is stable for both a real address and a bare-id alias.
    public var canonical: String {
        "port42://space/\(spaceId ?? "_")/\(portId)"
    }
}
