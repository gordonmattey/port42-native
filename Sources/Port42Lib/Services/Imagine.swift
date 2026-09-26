import Foundation

/// `/imagine` (docs/plan-imagine.md): one line from a person becomes a small team (a lead and two
/// engineers) that builds a port in its chat until the lead reports DONE.
///
/// Port42 runs no model (D9), so nothing here interprets the line. These are fixed texts with
/// variables: the agents' generated codenames, the person's name, their line verbatim, a title taken
/// from it, and the version budget. Turning the line into a vision is the lead's first job.
public enum Imagine {

    public static let defaultVersions = 5
    public static let maxVersions = 20

    /// What a person typed, understood.
    public enum Command: Equatable {
        case start(line: String, versions: Int)
        case stop
    }

    /// `/imagine <line>`, `/imagine --versions N <line>` or `/imagine stop`. Nil for anything else,
    /// which is posted as text.
    public static func parse(_ input: String) -> Command? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased() == "/imagine" || t.lowercased().hasPrefix("/imagine ") else { return nil }
        var rest = String(t.dropFirst("/imagine".count)).trimmingCharacters(in: .whitespaces)
        if rest.lowercased() == "stop" { return .stop }
        var versions = defaultVersions
        if rest.hasPrefix("--versions") {
            let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let n = Int(parts[1]), n >= 1 else { return nil }
            versions = min(n, maxVersions)
            rest = parts.count == 3 ? String(parts[2]) : ""
        }
        let line = rest.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : .start(line: line, versions: versions)
    }

    /// The port's title, from the line: whitespace collapsed, at most 60 characters, cut at a word.
    public static func title(from line: String) -> String {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + " " + w
            if next.count > 60 { break }
            out = next
        }
        return out.isEmpty ? String(line.prefix(60)) : out
    }

    /// The lead's role, its system prompt for the whole session.
    public static func leadRole() -> String {
        """
        You lead an imagine team. You own the vision and the version budget. You do not build: you set \
        the vision, split the work between your engineers so they never edit the same part, check each \
        version works (its console and DOM), and decide the next step. Work in the port's chat; answer \
        the person in the space's chat in one line. Stop at DONE.
        """
    }

    /// An engineer's role, its system prompt for the whole session.
    public static func engineerRole(lead: String) -> String {
        """
        You are an engineer on an imagine team led by @\(lead). Build what the lead gives you in the \
        port, only your part. Check it works before you say so, then report in the port's chat to \
        @\(lead): what you changed and what you checked.
        """
    }

    /// The first message, to the lead. The person's line goes in verbatim.
    public static func brief(line: String, person: String, lead: String, eng1: String, eng2: String,
                             title: String, versions: Int) -> String {
        """
        @\(lead) /imagine from \(person): "\(line)"
        You lead @\(eng1) and @\(eng2). Make one web port titled '\(title)' that realizes this, in at \
        most \(versions) versions.
        1. Reply here in one line saying what you are going for, then write the vision in 3 to 5 lines \
        in the port's chat.
        2. Have @\(eng1) make v1. For each later version, give both engineers concrete, non-overlapping \
        next steps toward the vision, check the result, and push further.
        3. When the vision is met or the budget is spent, post in the port's chat a message that starts \
        with DONE and says what the port now is, and one line here.
        """
    }
}
