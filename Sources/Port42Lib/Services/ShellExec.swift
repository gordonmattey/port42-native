import Foundation

/// Headless shell command execution, shared by the tool surface (`terminal_exec`,
/// `ToolExecutor`) and the JS bridge (`terminal.exec`, `PortBridge`). Runs a command via
/// `/bin/zsh -c`, captures stdout/stderr, and enforces a timeout. Output is returned in FULL —
/// bounding a result to a model's context is the LLM tool-result adapter's job
/// (`ToolExecutor.maxToolResultBytes`), not this shared base, since a port or gateway caller is
/// not token-limited.
///
/// This is the *headless run-and-capture* path only — it owns no surface and is unrelated to
/// the native Ghostty terminal ports (those are created via `port.create`/`spawnNativeTerminalPort`).
public enum ShellExec {

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

                // Drain both pipes CONCURRENTLY with the running process. Reading only after
                // waitUntilExit deadlocks any command whose output exceeds the OS pipe buffer
                // (~64KB): the child blocks writing to a full pipe, never exits, and the timeout
                // then salvages a truncated 64KB. Reading to EOF on background threads keeps the
                // pipes drained so arbitrarily large output flows through whole.
                var outData = Data()
                var errData = Data()
                let ioGroup = DispatchGroup()
                let ioQueue = DispatchQueue(label: "com.port42.shellexec.io", attributes: .concurrent)
                ioQueue.async(group: ioGroup) { outData = stdout.fileHandleForReading.readDataToEndOfFile() }
                ioQueue.async(group: ioGroup) { errData = stderr.fileHandleForReading.readDataToEndOfFile() }

                // Timeout
                let deadline = DispatchTime.now() + .seconds(timeout)
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }

                process.waitUntilExit()
                ioGroup.wait()   // both pipes fully drained (EOF on the child's exit/terminate)

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
                continuation.resume(returning: result.isEmpty ? "(no output)" : result)
            }
        }
    }
}
