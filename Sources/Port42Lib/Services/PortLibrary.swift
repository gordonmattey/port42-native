import Foundation

// MARK: - Port Library
//
// Loads named port HTML from bundled resources (Resources/ports/*.html).
// Supports {{VARIABLE}} slot substitution for runtime values.
//
// This is the foundation for port sharing: a port is a named HTML file that
// any part of the system can load and instantiate with different slot values.

public struct PortLibrary {

    /// Load a named port, filling in slot values.
    /// - Parameters:
    ///   - name: filename without extension (e.g. "cli-terminal")
    ///   - slots: dictionary of {{KEY}} → replacement value
    /// - Returns: rendered HTML, or nil if the port file is not found
    public static func load(_ name: String, slots: [String: String] = [:]) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return slots.reduce(html) { result, slot in
            result.replacingOccurrences(of: "{{\(slot.key)}}", with: slot.value)
        }
    }

    /// Returns the names of all available bundled ports.
    public static var available: [String] {
        // SPM flattens Resources subdirectories into the bundle root.
        // Enumerate all .html files in the bundle to discover available ports.
        guard let bundlePath = Bundle.module.resourcePath else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: bundlePath)) ?? []
        return files
            .filter { $0.hasSuffix(".html") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }
}
