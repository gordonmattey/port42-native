import Foundation

// MARK: - Automation Bridge (P-601)

/// Bridges port42.automation.* calls to AppleScript and JXA execution.
/// Stateless bridge following ClipboardBridge/ScreenBridge pattern.
@MainActor
public final class AutomationBridge {

    private static let defaultTimeout: TimeInterval = 30
    private static let maxTimeout: TimeInterval = 120

    /// Clamp timeout from opts dict to [1...maxTimeout], defaulting to defaultTimeout.
    private func resolveTimeout(_ opts: [String: Any]) -> TimeInterval {
        guard let raw = opts["timeout"] as? Int else { return Self.defaultTimeout }
        return min(max(TimeInterval(raw), 1), Self.maxTimeout)
    }

    /// Execute AppleScript source code and return the result as a string.
    func runAppleScript(source: String, opts: [String: Any]) async -> [String: Any] {
        let timeout = resolveTimeout(opts)
        let source = source  // capture for sendable closure

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
            let guard_ = ContinuationGuard(continuation: continuation)

            // NSAppleScript is not MainActor-bound; run on a background queue.
            DispatchQueue.global(qos: .userInitiated).async {
                var errorDict: NSDictionary?
                let script = NSAppleScript(source: source)
                let descriptor = script?.executeAndReturnError(&errorDict)

                if let error = errorDict {
                    let msg = error[NSAppleScript.errorMessage] as? String ?? "AppleScript execution failed"
                    guard_.resumeOnce(["error": msg])
                } else {
                    let result = descriptor?.stringValue ?? ""
                    guard_.resumeOnce(["result": result])
                }
            }

            // Enforce timeout
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                guard_.resumeOnce(["error": "AppleScript timed out after \(Int(timeout))s"])
            }
        }
    }

    /// Execute JXA (JavaScript for Automation) source code via osascript.
    func runJXA(source: String, opts: [String: Any]) async -> [String: Any] {
        let timeout = resolveTimeout(opts)

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
            let guard_ = ContinuationGuard(continuation: continuation)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    guard_.resumeOnce(["result": stdout])
                } else {
                    let msg = stderr.isEmpty ? "JXA execution failed (exit \(proc.terminationStatus))" : stderr
                    guard_.resumeOnce(["error": msg])
                }
            }

            do {
                try process.run()
            } catch {
                guard_.resumeOnce(["error": "Failed to launch osascript: \(error.localizedDescription)"])
                return
            }

            // Enforce timeout
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    // Give it a moment, then force kill
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { process.interrupt() }
                    }
                    guard_.resumeOnce(["error": "JXA timed out after \(Int(timeout))s"])
                }
            }
        }
    }
}

// MARK: - Continuation Guard

/// Thread-safe wrapper ensuring a CheckedContinuation is resumed exactly once.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: Any], Never>?

    init(continuation: CheckedContinuation<[String: Any], Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: [String: Any]) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
