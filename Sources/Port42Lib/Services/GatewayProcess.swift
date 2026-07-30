import Foundation
import AppKit

/// Manages the bundled Port42 Gateway process lifecycle.
/// The gateway binary lives inside the app bundle and is launched as a subprocess.
@MainActor
public final class GatewayProcess: ObservableObject {
    @Published public var isRunning = false
    /// The prod default port — also the canonical port baked into the PUBLISHED llms.txt (so the
    /// committed artifact is stable regardless of which instance regenerates it).
    public static let defaultPort = 4242
    @Published public var port: Int = {
        if let envPort = ProcessInfo.processInfo.environment["PORT42_GATEWAY_PORT"],
           let p = Int(envPort) {
            return p
        }
        return GatewayProcess.defaultPort
    }()

    private var process: Process?
    private var outputPipe: Pipe?
    /// Write end held open for the app's lifetime; the gateway reads the read end as stdin and
    /// exits on EOF. When the app dies by ANY means (including SIGKILL), the OS closes this FD,
    /// so the gateway can never orphan and hold the port. See the "-watch-parent" flag in main.go.
    private var parentPipe: Pipe?

    /// The credential this spawn's gateway must present to claim `is_host`. In memory only, never
    /// written anywhere, and replaced on every spawn (D2). Readable so the host side can present it.
    public private(set) var hostCredential: String?

    /// 32 random bytes. Not a token in the `p42_` format — the gateway does not parse it, it only
    /// compares against it, which is exactly why no format needs to exist in two languages.
    static func freshHostCredential() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    public static let shared = GatewayProcess()

    private var terminationObserver: NSObjectProtocol?

    /// Path to the gateway binary inside the app bundle
    private var binaryPath: String? {
        // Try standard auxiliary executable lookup first
        if let path = Bundle.main.path(forAuxiliaryExecutable: "port42-gateway") {
            return path
        }
        // Fallback: look next to the main executable in Contents/MacOS/
        if let execURL = Bundle.main.executableURL {
            let sibling = execURL.deletingLastPathComponent().appendingPathComponent("port42-gateway")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling.path
            }
        }
        return nil
    }

    /// Start the local gateway on the configured port
    public func start() {
        guard !isRunning else { return }

        guard let path = binaryPath else {
            NSLog("[gateway] binary not found in app bundle")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        // LOOPBACK, not `:port` (GM 2026-07-24). `:port` bound every interface, so anything that
        // could route to this Mac reached /call — which proxies straight into the bridge registry
        // (files, clipboard, screen, terminal) and authenticates nobody. Sharing is unaffected:
        // ngrok forwards to a bare port, i.e. localhost. A deliberately-hosted relay still opts in
        // by launching the binary itself with -addr :port. See docs/plan-gateway-auth-tls.md P0.
        proc.arguments = ["-addr", "127.0.0.1:\(port)", "-watch-parent"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe = pipe

        // Give the gateway a stdin pipe we hold the write end of. We never write to it; its only
        // purpose is EOF-on-death. The gateway's -watch-parent goroutine reads to EOF and exits,
        // so a force-quit / SIGKILL of the app (which runs no cleanup on either side) can't leave
        // an orphaned gateway holding the port — the FD close is the kernel's job, not ours.
        let stdinPipe = Pipe()
        proc.standardInput = stdinPipe
        self.parentPipe = stdinPipe

        // THE HOST CREDENTIAL, regenerated per spawn (slice-02 half two, D2).
        //
        // Written to the pipe we already hold rather than passed in the environment, and that is
        // measured rather than stylistic: `ps -E` returns a same-user process's full environment, so
        // an env var here would publish the credential to every process running as the user — the
        // exact escalation this slice exists to close.
        //
        // ONE line, not two. The root secret stays in the app, because the app is now the only thing
        // that verifies a client token as well as the only thing that mints one. What the gateway
        // gets is the finished string it should compare host claims against — no secret it could mint
        // with, and no token format to reimplement.
        //
        // Fresh every spawn and stored nowhere, which is what makes `is_host` unforgeable by anything
        // on disk: a stale host credential cannot outlive the app that minted it. Today the claim is
        // simply believed, and whoever makes it becomes the peer every `/call` is routed to.
        let host = GatewayProcess.freshHostCredential()
        self.hostCredential = host

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

            // AFTER run(), because the read end does not exist until the child does. The gateway's
            // watch-parent goroutine reads this one line, then resumes the EOF death-watch from the
            // SAME buffered reader — resuming from os.Stdin would discard whatever the buffer had
            // already pulled in (spike C's carried detail, pinned by a Go test).
            //
            // Never logged, here or there (NFR2).
            if let data = (host + "\n").data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }

            isRunning = true
            print("[gateway] started on port \(port), pid \(proc.processIdentifier)")

            // Kill the gateway when the app terminates (singleton never deinits).
            // Terminate SYNCHRONOUSLY: the observer already runs on the main queue, and a
            // Task { @MainActor } hop enqueues work the dying app never drains, so the gateway
            // survived every normal quit as an orphan holding the port (the "no host" loop).
            if terminationObserver == nil {
                terminationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.process?.terminate() }
                }
            }
        } catch {
            print("[gateway] failed to start: \(error)")
        }
    }

    /// Stop the local gateway, giving it time to drain connections
    public func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        // Give gateway up to 2 seconds to drain WebSocket connections
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
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
