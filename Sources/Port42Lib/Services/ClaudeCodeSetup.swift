import Foundation
import SwiftUI

/// State machine that guides users through installing Node, Claude Code,
/// and authenticating so that Keychain auto-detect works.
@MainActor
public final class ClaudeCodeSetup: ObservableObject {

    public enum State: Equatable {
        case idle
        case checking
        case noNode
        case claudeNotInstalled
        case claudeNeedsAuth
        case multipleTokens([ClaudeKeychainEntry])  // user must pick one
        case running(String)   // status message
        case failed(String)    // error message
        case success
    }

    @Published public var state: State = .idle
    @Published public var output: String = ""

    private var process: Process?

    // MARK: - Public API

    /// Diagnose what is installed and set the initial state.
    public func diagnose() {
        state = .checking
        output = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasNode = Self.findBinary("node") != nil
            let hasClaude = Self.findBinary("claude") != nil
            let resolver = AgentAuthResolver.shared

            // Check for existing tokens
            var hasToken = false
            var entries: [ClaudeKeychainEntry] = []
            if hasClaude {
                hasToken = resolver.autoDetect() != nil
                if !hasToken {
                    // Check for multiple entries that need user selection
                    entries = resolver.listKeychainEntries()
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if hasToken {
                    self.state = .success
                } else if entries.count > 1 {
                    self.state = .multipleTokens(entries)
                } else if entries.count == 1 {
                    // Single suffixed entry found, select it automatically
                    resolver.selectEntry(entries[0])
                    self.state = .success
                } else if !hasNode {
                    self.state = .noNode
                } else if !hasClaude {
                    self.state = .claudeNotInstalled
                } else {
                    self.state = .claudeNeedsAuth
                }
            }
        }
    }

    /// Select a specific Keychain entry from the picker.
    public func selectKeychainEntry(_ entry: ClaudeKeychainEntry) {
        AgentAuthResolver.shared.selectEntry(entry)
        state = .success
    }

    /// Cancel the currently running process.
    public func cancel() {
        process?.terminate()
        process = nil
        if case .running = state {
            state = .failed("Cancelled")
        }
    }

    /// Install Node.js via the official macOS .pkg installer.
    public func installNode() {
        let nodeVersion = "v22.16.0"
        let pkgName = "node-\(nodeVersion).pkg"
        let url = "https://nodejs.org/dist/\(nodeVersion)/\(pkgName)"
        let dest = "/tmp/\(pkgName)"

        state = .running("Downloading Node.js...")
        output = "$ curl -fsSL \(url)\n"

        run(command: "/usr/bin/curl", args: ["-fsSL", "-o", dest, url], status: "Downloading Node.js...") { [weak self] ok in
            guard let self, ok else {
                self?.failIfRunning("Node.js download failed")
                return
            }
            self.output += "\n$ installer -pkg \(dest) -target CurrentUserHomeDirectory\n"
            self.state = .running("Installing Node.js...")

            // Try user-local install first (no sudo)
            self.run(command: "/usr/sbin/installer", args: ["-pkg", dest, "-target", "CurrentUserHomeDirectory"], status: "Installing Node.js...") { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.verifyAfterNodeInstall()
                    return
                }
                // Fallback: prompt for admin via osascript
                self.output += "\nRequesting admin privileges...\n"
                self.run(command: "/usr/bin/osascript", args: [
                    "-e",
                    "do shell script \"installer -pkg \(dest) -target /\" with administrator privileges"
                ], status: "Installing Node.js (admin)...") { [weak self] ok in
                    guard let self else { return }
                    if ok {
                        self.verifyAfterNodeInstall()
                    } else {
                        self.failIfRunning("Node.js installation failed. You can install it manually or switch to another auth method.")
                    }
                }
            }
        }
    }

    /// Install Claude Code via npm.
    public func installClaudeCode() {
        guard let npm = Self.findBinary("npm") else {
            state = .failed("npm not found. Please install Node.js first.")
            return
        }

        state = .running("Installing Claude Code...")
        output = "$ npm install -g @anthropic-ai/claude-code\n"

        run(command: npm, args: ["install", "-g", "@anthropic-ai/claude-code"], status: "Installing Claude Code...") { [weak self] ok in
            guard let self else { return }
            if ok {
                // Verify
                if Self.findBinary("claude") != nil {
                    self.output += "\nClaude Code installed.\n"
                    self.state = .claudeNeedsAuth
                } else {
                    self.failIfRunning("npm install succeeded but 'claude' binary not found on PATH.")
                }
            } else {
                // Maybe permissions issue, try with sudo via osascript
                self.output += "\nRetrying with admin privileges...\n"
                self.run(command: "/usr/bin/osascript", args: [
                    "-e",
                    "do shell script \"\(npm) install -g @anthropic-ai/claude-code\" with administrator privileges"
                ], status: "Installing Claude Code (admin)...") { [weak self] ok in
                    guard let self else { return }
                    if ok && Self.findBinary("claude") != nil {
                        self.output += "\nClaude Code installed.\n"
                        self.state = .claudeNeedsAuth
                    } else {
                        self.failIfRunning("Claude Code installation failed. You can try manually or switch to another auth method.")
                    }
                }
            }
        }
    }

    /// Run `claude setup-token` to authenticate via browser OAuth.
    public func authenticate() {
        guard let claude = Self.findBinary("claude") else {
            state = .failed("Claude Code binary not found.")
            return
        }

        state = .running("Waiting for browser sign-in...")
        output = "$ claude setup-token\n"

        run(command: claude, args: ["setup-token"], status: "Waiting for browser sign-in...") { [weak self] ok in
            guard let self else { return }
            if ok {
                self.retryDetection()
            } else {
                self.failIfRunning("Authentication was cancelled or failed. You can retry or switch to another auth method.")
            }
        }
    }

    /// Re-check Keychain after authentication completes.
    public func retryDetection() {
        AgentAuthResolver.shared.resetAuth()
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AgentAuthResolver.shared.autoDetect() != nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if found {
                    self.state = .success
                } else {
                    self.state = .failed("Authentication completed but token not found in Keychain. Try again or use another auth method.")
                }
            }
        }
    }

    // MARK: - Binary Detection

    /// Search PATH and common locations for a binary.
    public static func findBinary(_ name: String) -> String? {
        let commonPaths = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/bin/\(name)",
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Check nvm installations
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmBase = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            // Sort descending to prefer newest version
            for version in versions.sorted().reversed() {
                let path = "\(nvmBase)/\(version)/bin/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        // Check npm global bin
        let npmGlobal = "\(home)/.npm-global/bin/\(name)"
        if FileManager.default.isExecutableFile(atPath: npmGlobal) {
            return npmGlobal
        }

        // Fallback: `which`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {}

        return nil
    }

    // MARK: - Private

    private func verifyAfterNodeInstall() {
        if Self.findBinary("node") != nil {
            output += "\nNode.js installed.\n"
            // Check if Claude is already installed
            if Self.findBinary("claude") != nil {
                state = .claudeNeedsAuth
            } else {
                state = .claudeNotInstalled
            }
        } else {
            failIfRunning("Node.js installed but 'node' binary not found on PATH.")
        }
    }

    private func failIfRunning(_ message: String) {
        if case .running = state {
            state = .failed(message)
        }
    }

    /// Run a subprocess, streaming stdout/stderr to `output`.
    private func run(
        command: String,
        args: [String],
        status: String,
        onComplete: @escaping (Bool) -> Void
    ) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args

        // Provide a PATH that includes common binary locations
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.nvm/versions/node",
            "\(home)/.npm-global/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.output += text
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.output += text
            }
        }

        proc.terminationHandler = { [weak self] p in
            // Clean up handlers
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let success = p.terminationStatus == 0
            DispatchQueue.main.async {
                self?.process = nil
                onComplete(success)
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            output += "Failed to start: \(error.localizedDescription)\n"
            onComplete(false)
        }
    }

    private static func isAppleSilicon() -> Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine.hasPrefix("arm64")
    }
}
