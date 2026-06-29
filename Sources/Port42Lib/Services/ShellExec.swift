import Foundation

/// Headless shell command execution, shared by the tool surface (`terminal_exec`,
/// `ToolExecutor`) and the JS bridge (`terminal.exec`, `PortBridge`). Runs a command via
/// `/bin/zsh -c`, captures stdout/stderr, enforces a timeout, and caps output size.
///
/// This is the *headless run-and-capture* path only — it owns no surface and is unrelated to
/// the native Ghostty terminal ports (those are created via `port.create`/`spawnNativeTerminalPort`).
public enum ShellExec {

    /// Maximum captured output before truncation.
    static let maxOutputBytes = 50_000

    /// Execute a shell command, returning combined stdout plus `[stderr]`/`[exit code]`
    /// annotations when present. Never throws — failures are reported in the returned string.
    public static func run(_ command: String, cwd: String? = nil, timeout: Int = 30) async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                if let cwd = cwd {
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "Error launching command: \(error.localizedDescription)")
                    return
                }

                // Timeout
                let deadline = DispatchTime.now() + .seconds(timeout)
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                let exitCode = process.terminationStatus
                var result = outStr
                if !errStr.isEmpty {
                    result += "\n[stderr]: \(errStr)"
                }
                if exitCode != 0 {
                    result += "\n[exit code: \(exitCode)]"
                }
                // Limit output size
                if result.count > maxOutputBytes {
                    result = String(result.prefix(maxOutputBytes)) + "\n... (truncated)"
                }
                continuation.resume(returning: result.isEmpty ? "(no output)" : result)
            }
        }
    }
}
