import Foundation

// MARK: - BridgeReference (close-out step 4c)
//
// The API reference is GENERATED from the registry's self-describing metadata. The hand-written
// llms.txt used to drift with every API change; now the conceptual prose lives in
// llms-preamble.txt (ports, calling conventions, examples) and the method inventory is rendered
// from the live registries, so a method that exists is documented and one that does not is not.
// Served by the `help` bridge method and by InstructionService (the CLI instruction docs).

@MainActor
public func generateAPIReference(_ state: AppState) -> String {
    var out = ""
    if let url = Bundle.port42.url(forResource: "llms-preamble", withExtension: "txt"),
       let preamble = try? String(contentsOf: url, encoding: .utf8) {
        // The preamble's curl examples hardcode :4242; rewrite to the LIVE gateway port so a dev
        // instance (or any non-default port) documents the port callers must actually hit.
        let live = preamble.replacingOccurrences(of: "127.0.0.1:4242",
                                                 with: "127.0.0.1:\(GatewayProcess.shared.port)")
        out += live.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
    }

    struct Entry {
        let name: String
        let params: [String]
        let permission: PortPermission?
        let description: String
        let streaming: Bool
    }

    var entries: [Entry] = []
    for (name, m) in state.bridgeRegistry {
        entries.append(Entry(name: name, params: m.paramNames, permission: m.permission,
                             description: m.description, streaming: false))
    }
    for (name, m) in state.bridgeStreamRegistry {
        entries.append(Entry(name: name, params: m.paramNames, permission: m.permission,
                             description: m.description, streaming: true))
    }

    out += "## Available Methods\n\n"
    out += "Generated from the live method registry: every entry below is served exactly as declared.\n"

    let grouped = Dictionary(grouping: entries) { e in
        e.name.contains(".") ? String(e.name.prefix(upTo: e.name.firstIndex(of: ".")!)) : "general"
    }
    for ns in grouped.keys.sorted() {
        out += "\n### \(ns)\n\n"
        for e in grouped[ns]!.sorted(by: { $0.name < $1.name }) {
            var tags: [String] = []
            if let perm = e.permission { tags.append("permission: \(perm.rawValue)") }
            if e.streaming { tags.append("streaming") }
            let tagText = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
            out += "  \(e.name)(\(e.params.joined(separator: ", ")))\(tagText)\n"
            if !e.description.isEmpty {
                out += "      \(e.description)\n"
            }
        }
    }

    let aliases = state.bridgeAliases
    if !aliases.isEmpty {
        out += "\n### Aliases\n\n"
        for (surface, canonical) in aliases.sorted(by: { $0.key < $1.key }) {
            out += "  \(surface) -> \(canonical)\n"
        }
    }

    return out
}
