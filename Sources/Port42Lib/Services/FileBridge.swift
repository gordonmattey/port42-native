import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - File Bridge (P-506)

/// Presents the native file pickers for fs.pick. Panel presentation ONLY (the close-out slim):
/// which paths a caller may then read/write is decided by the principal-keyed grant store on
/// AppState (pickedFilePaths), not here.
@MainActor
public final class FileBridge {

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

        return ["path": url.path]
    }

}
