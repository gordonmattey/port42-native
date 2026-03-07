import Foundation

/// Manages the bundled Port42 Gateway process lifecycle.
/// The gateway binary lives inside the app bundle and is launched as a subprocess.
@MainActor
public final class GatewayProcess: ObservableObject {
    @Published public var isRunning = false
    @Published public var port: Int = 4242

    private var process: Process?
    private var outputPipe: Pipe?

    public static let shared = GatewayProcess()

    /// Path to the gateway binary inside the app bundle
    private var binaryPath: String? {
        Bundle.main.path(forAuxiliaryExecutable: "port42-gateway")
    }

    /// Start the local gateway on the configured port
    public func start() {
        guard !isRunning else { return }

        guard let path = binaryPath else {
            print("[gateway] binary not found in app bundle")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-addr", ":\(port)"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe = pipe

        // Log gateway output
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                NSLog("[gateway] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                print("[gateway] process terminated")
            }
        }

        do {
            try proc.run()
            self.process = proc
            isRunning = true
            print("[gateway] started on port \(port), pid \(proc.processIdentifier)")
        } catch {
            print("[gateway] failed to start: \(error)")
        }
    }

    /// Stop the local gateway
    public func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
        isRunning = false
        print("[gateway] stopped")
    }

    /// The local WebSocket URL for connecting to this gateway
    public var localURL: String {
        "ws://localhost:\(port)"
    }

    deinit {
        process?.terminate()
    }
}
