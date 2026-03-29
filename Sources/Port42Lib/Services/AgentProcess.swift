import Foundation

// MARK: - Errors

public enum AgentProcessError: Error {
    case notRunning
    case timeout
    case invalidResponse(String)
    case commandAgentRequired
}

// MARK: - Agent Process (command agents only)

public final class AgentProcess {
    private let config: AgentConfig
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var logBuffer: String = ""
    private let logLock = NSLock()

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public init(config: AgentConfig) {
        self.config = config
    }

    public func start() throws {
        guard config.mode == .command else {
            throw AgentProcessError.commandAgentRequired
        }
        guard let command = config.command else {
            throw AgentProcessError.commandAgentRequired
        }

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = config.args ?? []
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        if let workingDir = config.workingDir {
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }

        if let envVars = config.envVars {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in envVars {
                env[key] = value
            }
            proc.environment = env
        }

        // Capture stderr for logs
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                self?.appendLog(str)
            }
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
    }

    public func stop() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
    }

    public func send(_ event: AgentEvent, timeout: TimeInterval) async throws -> AgentResponse {
        guard let process = process, process.isRunning,
              let stdinPipe = stdinPipe, let stdoutPipe = stdoutPipe else {
            throw AgentProcessError.notRunning
        }

        let encoded = try AgentProtocol.encode(event)
        stdinPipe.fileHandleForWriting.write(encoded)

        // Use readabilityHandler + continuation so cancellation works
        final class ResumeState: @unchecked Sendable {
            var resumed = false
            var lineBuffer = Data()
            var timeoutItem: DispatchWorkItem?
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumeLock = NSLock()
            let state = ResumeState()

            @Sendable func resumeOnce(with result: Result<AgentResponse, Error>) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !state.resumed else { return }
                state.resumed = true
                state.timeoutItem?.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(with: result)
            }

            // Timeout
            let work = DispatchWorkItem {
                resumeOnce(with: .failure(AgentProcessError.timeout))
            }
            state.timeoutItem = work
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)

            // Read line from stdout
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    resumeOnce(with: .failure(AgentProcessError.notRunning))
                    return
                }
                state.lineBuffer.append(data)
                // Check for newline
                if let newlineIndex = state.lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = state.lineBuffer[state.lineBuffer.startIndex..<newlineIndex]
                    do {
                        let response = try AgentProtocol.decode(Data(lineData))
                        resumeOnce(with: .success(response))
                    } catch {
                        resumeOnce(with: .failure(error))
                    }
                }
            }
        }
    }

    public func getLogs() -> String {
        logLock.lock()
        defer { logLock.unlock() }
        return logBuffer
    }

    private func appendLog(_ text: String) {
        logLock.lock()
        defer { logLock.unlock() }
        logBuffer += text
    }
}
