import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - File Bridge (P-506)

/// Bridges port42.fs.* calls to native file picker and scoped file I/O.
/// Security: Only paths chosen by the user via NSOpenPanel/NSSavePanel are accessible.
/// Arbitrary file system traversal is not permitted.
@MainActor
public final class FileBridge {

    /// Paths the user has explicitly chosen via a picker. Only these can be read/written.
    private var allowedPaths: Set<String> = []

    /// Number of allowed paths (for diagnostics)
    var allowedPathCount: Int { allowedPaths.count }

    /// Paths from drag-and-drop operations.
    private var droppedPaths: Set<String> = []

    /// Show a native file picker and return the chosen path(s).
    /// opts: { mode: 'open'|'save', types?: ['txt','json',...], multiple?: false, directory?: false, suggestedName?: 'file.txt' }
    func pick(opts: [String: Any]) async -> [String: Any] {
        let mode = opts["mode"] as? String ?? "open"

        if mode == "save" {
            return await pickSave(opts: opts)
        } else {
            return await pickOpen(opts: opts)
        }
    }

    private func pickOpen(opts: [String: Any]) async -> [String: Any] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !(opts["directory"] as? Bool ?? false)
        panel.canChooseDirectories = opts["directory"] as? Bool ?? false
        panel.allowsMultipleSelection = opts["multiple"] as? Bool ?? false
        panel.title = "Select File"

        if let types = opts["types"] as? [String] {
            panel.allowedContentTypes = types.compactMap { ext in
                UTType(filenameExtension: ext)
            }
        }

        // Use begin() with continuation instead of runModal() to avoid
        // blocking the Swift concurrency runtime. runModal() creates a
        // nested run loop that conflicts with async/await on MainActor,
        // causing the panel to silently cancel.
        NSLog("[Port42] pickOpen: presenting panel, keyWindow=%@, mainWindow=%@",
              NSApp.keyWindow?.description ?? "nil", NSApp.mainWindow?.description ?? "nil")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { response in
                NSLog("[Port42] pickOpen: panel completed with response=%d (OK=%d, cancel=%d)",
                      response.rawValue, NSApplication.ModalResponse.OK.rawValue, NSApplication.ModalResponse.cancel.rawValue)
                continuation.resume(returning: response)
            }
        }

        guard response == .OK else {
            NSLog("[Port42] pickOpen: cancelled/failed")
            return ["cancelled": true]
        }

        let paths = panel.urls.map { $0.path }
        for path in paths {
            allowedPaths.insert(path)
        }

        if paths.count == 1 {
            return ["path": paths[0]]
        }
        return ["paths": paths]
    }

    private func pickSave(opts: [String: Any]) async -> [String: Any] {
        let panel = NSSavePanel()
        panel.title = "Save File"
        panel.canCreateDirectories = true

        if let name = opts["suggestedName"] as? String {
            panel.nameFieldStringValue = name
        }

        if let types = opts["types"] as? [String], let first = types.first {
            if let utType = UTType(filenameExtension: first) {
                panel.allowedContentTypes = [utType]
            }
        }

        NSLog("[Port42] pickSave: presenting panel, keyWindow=%@", NSApp.keyWindow?.description ?? "nil")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { response in
                NSLog("[Port42] pickSave: panel completed with response=%d", response.rawValue)
                continuation.resume(returning: response)
            }
        }

        guard response == .OK, let url = panel.url else {
            NSLog("[Port42] pickSave: cancelled/failed")
            return ["cancelled": true]
        }

        let path = url.path
        allowedPaths.insert(path)
        return ["path": path]
    }

    /// Read a file at a previously-picked path.
    /// Returns text content by default, or base64 for binary files.
    func read(path: String, opts: [String: Any]?) -> [String: Any] {
        guard allowedPaths.contains(path) || droppedPaths.contains(path) else {
            // H7: Log path mismatch
            NSLog("[Port42] fs.read ACCESS DENIED: requested='%@', allowed=%@", path, allowedPaths.map { $0 }.joined(separator: ", "))
            return ["error": "access denied: path was not chosen by user"]
        }

        let url = URL(fileURLWithPath: path)
        let encoding = opts?["encoding"] as? String ?? "utf8"

        do {
            if encoding == "base64" {
                let data = try Data(contentsOf: url)
                return ["data": data.base64EncodedString(), "encoding": "base64", "size": data.count]
            } else {
                let text = try String(contentsOf: url, encoding: .utf8)
                return ["data": text, "encoding": "utf8", "size": text.utf8.count]
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Write data to a previously-picked path.
    func write(path: String, data: String, opts: [String: Any]?) -> [String: Any] {
        guard allowedPaths.contains(path) else {
            return ["error": "access denied: path was not chosen by user"]
        }

        let url = URL(fileURLWithPath: path)
        let encoding = opts?["encoding"] as? String ?? "utf8"

        do {
            if encoding == "base64" {
                guard let binaryData = Data(base64Encoded: data) else {
                    return ["error": "invalid base64 data"]
                }
                try binaryData.write(to: url)
                return ["ok": true, "size": binaryData.count]
            } else {
                try data.write(to: url, atomically: true, encoding: .utf8)
                return ["ok": true, "size": data.utf8.count]
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Register a path from drag-and-drop as allowed for reading.
    func registerDroppedPath(_ path: String) {
        droppedPaths.insert(path)
    }
}
