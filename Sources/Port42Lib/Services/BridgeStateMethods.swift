import Foundation

// MARK: - A port's state (docs/plan-port-state-v1.md, Phase A)
//
// `state.set` lets a port, or an agent working on it, say what it is doing in a few short lines;
// `state.get` reads back everything Port42 would show on the port's card: those lines, then what Port42
// knows (a terminal's reports, a companion's presence, a browser's page, console errors).

@MainActor
extension AppState {

    /// Everything a card for this port shows. The one place its inputs are gathered.
    func portCard(_ panel: PortPanel) -> PortCard {
        let controller = terminalControllers[panel.id]
        var companion: PortCard.Companion?
        if let controller {
            let name = controller.config.companionName
            let presence = name.isEmpty ? nil
                : presence.byChat.values.lazy.flatMap { $0 }.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            companion = PortCard.Companion(presence: presence, waitingMessages: controller.hasWaitingMessages)
        }
        let consoleKey = PortConsole.key(udid: panel.udid, id: panel.id, messageId: panel.messageId)
        // The activity Port42 sees around the port: its chat, its writes, its sharing.
        var activity = PortCard.Activity()
        if let chat = chatKey(for: panel.udid) {
            activity.working = presence.entries(chat)
            activity.unread = chats.unread(chat, me: currentUser?.id, db: db)
        }
        if controller == nil, let key = portKey(for: panel.udid) {
            activity.lastChange = portInput.lastChange(of: key)   // a web port's code or content, not keystrokes
        }
        activity.sharedWith = sharing[panel.udid]?.people.count ?? 0
        return PortCard.build(title: panel.title,
                              declared: portStates.declared[panel.id] ?? [],
                              terminal: portStates.terminals[panel.id],
                              companion: companion,
                              browser: portStates.browsers[panel.id],
                              activity: activity,
                              errors: PortConsole.shared.errorCounts[consoleKey] ?? 0)
    }

    /// The first line of a port's card, for one-line listings (the rail, ⌘K).
    public func portSummary(_ panel: PortPanel) -> String? { portCard(panel).summary }

    /// May this caller say what `panel` is doing? The port itself, its author, the person, or a companion
    /// working in its space: the people who build it (the same set that may change its code, APP-07).
    func maySetState(of panel: PortPanel, by p: Principal) -> Bool {
        if p.kind == .human { return true }
        if p.id == panel.udid || p.id == panel.messageId { return true }
        if let own = p.portId, own == panel.udid || own == panel.id || own == panel.messageId { return true }
        if p.id == panel.bridge.portPrincipal.id { return true }
        if let space = panel.spaceId, companionInSpace(p) == space { return true }
        return false
    }
}

private let linesSchema: [String: Any] = [
    "type": "array",
    "description": "Up to 5 lines, first the most important, each {label, value}: e.g. [{\"label\":\"doing\",\"value\":\"building the join card\"},{\"label\":\"progress\",\"value\":\"3 of 5\"}]. Values are cut at 80 characters. An empty list clears it.",
    "items": ["type": "object",
              "properties": ["label": ["type": "string"], "value": ["type": "string"]],
              "required": ["label", "value"]],
]

@MainActor
func registerStateMethods(into r: inout BridgeRegistry, appState: AppState) {

    /// The port a state call is about: `port` when given, else the calling port itself.
    func target(_ p: Principal, _ args: BridgeArgs) throws -> PortPanel {
        if let raw = args.string("port") {
            guard let panel = appState.portWindows.findPort(by: appState.resolvePortRef(raw)?.udid ?? raw),
                  appState.canRead(portInSpace: panel.spaceId, by: p) else {
                throw BridgeError.notFound("port '\(raw)'")
            }
            return panel
        }
        // A port's own page. Its principal's id is the port's only when the port authorizes as itself;
        // a port a companion made runs as that companion (P-260), and `portId` names the port (found on
        // the operator dash, 2026-09-29: its state.set was refused as naming no port).
        let own = p.portId ?? p.id
        guard let panel = appState.portWindows.panels.first(where: { $0.udid == own || $0.id == own || $0.messageId == own }) else {
            throw BridgeError.badArg("name the port: port=<id>")
        }
        return panel
    }

    r["state.set"] = BridgeMethod(permission: nil, paramNames: ["lines", "port"],
        description: "Say what a port is doing, in a few short lines, shown on its card when it is small (a peek), on its card under Running in the rail and in ⌘K, before what Port42 knows about it. From a port's page: port42.state.set([{label, value}, …]) for itself. From an agent: name the port. Only the port, its author, the person or a companion in its space may set it. Kept until the port sets it again or closes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "lines": linesSchema,
                "port": ["type": "string", "description": "The port's id; omit from a port's own page."],
            ],
            "required": ["lines"],
        ]) { p, args in
        guard let raw = args.array("lines") else { throw BridgeError.badArg("state.set requires lines: [{label, value}]") }
        let lines = try raw.map { item -> StateLine in
            guard let o = item as? [String: Any], let label = o["label"] as? String else {
                throw BridgeError.badArg("each line is {label, value}")
            }
            let value = (o["value"] as? String) ?? (o["value"].map { "\($0)" } ?? "")
            return StateLine(label: label, value: value)
        }
        let panel = try target(p, args)
        guard appState.maySetState(of: panel, by: p) else {
            throw BridgeError(code: .permissionDenied,
                              message: "only the port, its author, the person or a companion in its space can say what it is doing")
        }
        appState.portStates.declare(lines, port: panel.id)
        return .object(["ok": .bool(true)])
    }

    r["state.get"] = BridgeMethod(permission: nil, paramNames: ["port"],
        description: "What a port's card shows: its title, then its lines, declared first (known: false), then what Port42 knows (known: true): a terminal's running command, last exit code, directory and bell, a companion working or waiting, a browser's page, console errors. progress is 0 to 1 when there is a bar.",
        inputSchema: [
            "type": "object",
            "properties": ["port": ["type": "string", "description": "The port's id; omit from a port's own page."]],
        ]) { p, args in
        let panel = try target(p, args)
        let card = appState.portCard(panel)
        var o: [String: BridgeValue] = [
            "title": .string(card.title),
            "lines": .array(card.lines.map {
                .object(["label": .string($0.label), "value": .string($0.value), "known": .bool($0.known)])
            }),
        ]
        if let progress = card.progress { o["progress"] = .double(progress) }
        return .object(o)
    }
}
