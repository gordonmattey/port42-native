import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Terminal Bridge (P-500)

/// Manages pseudo-terminal sessions for ports. Each session wraps a PTY
/// with a shell process. Output streams through the PortBridge event system.
@MainActor
public final class TerminalBridge {

    /// A single terminal session backed by a PTY.
    public final class Session: @unchecked Sendable {
        public let id: String
        let fileDescriptor: Int32
        let pid: pid_t
        private(set) var isRunning: Bool = true
        private var readThread: Thread?

        init(id: String, fd: Int32, pid: pid_t) {
            self.id = id
            self.fileDescriptor = fd
            self.pid = pid
        }

        /// Start reading output in a background thread. Calls `onOutput` with chunks
        /// and `onExit` when the process terminates.
        func startReading(onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
            let thread = Thread {
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }

                while true {
                    let bytesRead = read(self.fileDescriptor, buffer, bufferSize)
                    if bytesRead <= 0 { break }
                    if let str = String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .utf8) {
                        onOutput(str)
                    } else {
                        // Fall back to latin1 for binary-ish output
                        let str = String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .isoLatin1) ?? ""
                        onOutput(str)
                    }
                }

                // Process exited, get status
                var status: Int32 = 0
                waitpid(self.pid, &status, 0)
                let exited = (status & 0x7f) == 0
                let exitCode: Int32 = exited ? ((status >> 8) & 0xff) : -1
                self.isRunning = false
                close(self.fileDescriptor)
                onExit(exitCode)
            }
            thread.qualityOfService = .userInitiated
            thread.name = "port42-terminal-\(id)"
            self.readThread = thread
            thread.start()
        }

        /// Write data to stdin.
        func send(_ data: String) {
            guard isRunning else { return }
            data.withCString { ptr in
                _ = write(fileDescriptor, ptr, strlen(ptr))
            }
        }

        /// Resize the terminal.
        func resize(cols: UInt16, rows: UInt16) {
            guard isRunning else { return }
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(fileDescriptor, TIOCSWINSZ, &size)
        }

        /// Kill the process. SIGTERM first, then SIGKILL after a short delay.
        func kill() {
            guard isRunning else { return }
            Foundation.kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if self.isRunning {
                    Foundation.kill(self.pid, SIGKILL)
                }
            }
        }
    }

    // MARK: - State

    private var sessions: [String: Session] = [:]
    private weak var bridge: PortBridge?

    public init(bridge: PortBridge) {
        self.bridge = bridge
    }

    /// Strip ANSI escape sequences from terminal output for clean text rendering.
    private static func stripANSI(_ str: String) -> String {
        // Match ESC[ ... final_byte (CSI sequences), ESC] ... ST (OSC sequences),
        // and other ESC-initiated sequences
        guard let regex = try? NSRegularExpression(
            pattern: "\\x1b(?:\\[[0-9;?]*[a-zA-Z]|\\].*?(?:\\x07|\\x1b\\\\)|[()][0-9A-Za-z]|[>=<]|\\[\\?[0-9;]*[hl])",
            options: []
        ) else { return str }
        let range = NSRange(str.startIndex..., in: str)
        var result = regex.stringByReplacingMatches(in: str, range: range, withTemplate: "")
        // Strip carriage returns (cursor to start of line)
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
    }

    // MARK: - API

    /// Spawn a new terminal session.
    /// - Parameters:
    ///   - shell: Shell to run (default: /bin/zsh)
    ///   - cwd: Working directory (default: home)
    ///   - cols: Initial columns (default: 80)
    ///   - rows: Initial rows (default: 24)
    ///   - env: Additional environment variables
    /// - Returns: Session ID string, or nil on failure.
    public func spawn(shell: String = "/bin/zsh", cwd: String? = nil, cols: UInt16 = 80, rows: UInt16 = 24, env: [String: String]? = nil) -> String? {
        let sessionId = UUID().uuidString

        // Set up initial window size
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        // Fork with PTY
        var fd: Int32 = 0
        let pid = forkpty(&fd, nil, nil, &size)

        if pid < 0 {
            NSLog("[Port42] forkpty failed: %d", errno)
            return nil
        }

        if pid == 0 {
            // Child process
            if let cwd = cwd {
                chdir(cwd)
            } else {
                let home = NSHomeDirectory()
                chdir(home)
            }

            // Set environment
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("PORT42_TERMINAL", "1", 1)
            // Clear env vars that block nested tool usage
            unsetenv("CLAUDECODE")
            if let env = env {
                for (key, value) in env {
                    setenv(key, value, 1)
                }
            }

            // Exec shell
            // execl is unavailable in Swift (variadic), use execv
            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(shell),
                strdup("-l"),
                nil
            ]
            execv(shell, argv)
            // If exec fails
            _exit(1)
        }

        // Parent process
        let session = Session(id: sessionId, fd: fd, pid: pid)

        // Capture weak self for callbacks from background thread
        let bridgeRef = self.bridge
        let sid = sessionId

        session.startReading(
            onOutput: { chunk in
                Task { @MainActor in
                    bridgeRef?.pushEvent("terminal.output", data: [
                        "sessionId": sid,
                        "data": chunk
                    ])
                }
            },
            onExit: { exitCode in
                Task { @MainActor in
                    bridgeRef?.pushEvent("terminal.exit", data: [
                        "sessionId": sid,
                        "code": exitCode
                    ])
                }
            }
        )

        sessions[sessionId] = session
        NSLog("[Port42] Terminal session spawned: %@ (pid %d, %dx%d)", sessionId, pid, cols, rows)
        return sessionId
    }

    /// Send data to a terminal session's stdin.
    public func send(sessionId: String, data: String) -> Bool {
        guard let session = sessions[sessionId], session.isRunning else { return false }
        session.send(data)
        return true
    }

    /// Resize a terminal session.
    public func resize(sessionId: String, cols: UInt16, rows: UInt16) -> Bool {
        guard let session = sessions[sessionId], session.isRunning else { return false }
        session.resize(cols: cols, rows: rows)
        return true
    }

    /// Kill a terminal session.
    public func kill(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        session.kill()
        sessions.removeValue(forKey: sessionId)
        NSLog("[Port42] Terminal session killed: %@", sessionId)
        return true
    }

    /// Kill all sessions (cleanup on bridge dealloc).
    public func killAll() {
        for (_, session) in sessions {
            session.kill()
        }
        sessions.removeAll()
    }

    /// Check if a session is running.
    public func isRunning(sessionId: String) -> Bool {
        sessions[sessionId]?.isRunning ?? false
    }

    /// List all active session IDs.
    public var activeSessionIds: [String] {
        sessions.filter { $0.value.isRunning }.map { $0.key }
    }

    /// First active session ID, or nil.
    public var firstActiveSessionId: String? {
        sessions.first(where: { $0.value.isRunning })?.key
    }
}
