import Foundation

/// Manages an ngrok tunnel to expose the local gateway to the internet.
/// Downloads ngrok automatically on first use.
@MainActor
public final class TunnelService: ObservableObject {
    @Published public var publicURL: String?
    @Published public var isRunning = false
    @Published public var status: String = ""

    private var process: Process?
    private var processGeneration: Int = 0
    private var pollTask: Task<Void, Never>?

    public static let shared = TunnelService()

    private init() {
        // Check if ngrok is already running (e.g. started by another instance)
        detectExistingTunnel()
    }

    /// Check if ngrok is already running and pick up its public URL.
    private func detectExistingTunnel() {
        Task { @MainActor in
            if let url = await Self.fetchTunnelURL() {
                self.publicURL = url
                self.isRunning = true
                self.status = "connected"
                print("[tunnel] detected existing tunnel: \(url)")
            }
        }
    }

    /// Directory where we store the ngrok binary
    private var binaryDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Port42/bin")
    }

    private var ngrokPath: String {
        binaryDir.appendingPathComponent("ngrok").path
    }

    /// Check common locations for ngrok
    private func findNgrok() -> String? {
        // Check our bundled copy first
        if FileManager.default.isExecutableFile(atPath: ngrokPath) {
            return ngrokPath
        }
        // Check PATH via /usr/bin/env
        let whichProc = Process()
        whichProc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProc.arguments = ["ngrok"]
        let pipe = Pipe()
        whichProc.standardOutput = pipe
        whichProc.standardError = Pipe()
        do {
            try whichProc.run()
            whichProc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        // Common homebrew paths
        for candidate in ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Start an ngrok tunnel pointing at the given local port.
    public func start(port: Int) {
        guard !isRunning else { return }
        isRunning = true
        status = "looking for ngrok..."

        Task { @MainActor in
            // Find or download ngrok
            let binary: String
            if let found = findNgrok() {
                binary = found
                print("[tunnel] found ngrok at \(found)")
            } else {
                status = "downloading ngrok..."
                if let downloaded = await downloadNgrok() {
                    binary = downloaded
                } else {
                    status = "download failed"
                    isRunning = false
                    return
                }
            }

            launchNgrok(binary: binary, port: port)
        }
    }

    /// Stop the ngrok tunnel.
    public func stop() {
        processGeneration += 1  // Invalidate any pending termination handler
        pollTask?.cancel()
        pollTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        } else {
            // We detected an external ngrok (process is nil) so kill it by name
            killExternalNgrok()
        }
        process = nil
        isRunning = false
        publicURL = nil
        status = ""
        print("[tunnel] stopped")
    }

    /// Kill any ngrok process we didn't start (detected via localhost:4040).
    private func killExternalNgrok() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-x", "ngrok"]
        kill.standardOutput = Pipe()
        kill.standardError = Pipe()
        try? kill.run()
        kill.waitUntilExit()
        print("[tunnel] killed external ngrok")
    }

    // MARK: - Download

    /// Download ngrok binary for macOS ARM64
    private func downloadNgrok() async -> String? {
        let arch = "arm64"
        let urlString = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-\(arch).zip"
        guard let url = URL(string: urlString) else { return nil }

        print("[tunnel] downloading ngrok from \(urlString)")

        do {
            let (zipURL, response) = try await URLSession.shared.download(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[tunnel] download failed with status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            // Create bin directory
            try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true)

            // Unzip
            let unzipProc = Process()
            unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProc.arguments = ["-o", zipURL.path, "-d", binaryDir.path]
            unzipProc.standardOutput = Pipe()
            unzipProc.standardError = Pipe()
            try unzipProc.run()
            unzipProc.waitUntilExit()

            // Clean up zip
            try? FileManager.default.removeItem(at: zipURL)

            // Make executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: ngrokPath
            )

            guard FileManager.default.isExecutableFile(atPath: ngrokPath) else {
                print("[tunnel] ngrok binary not found after unzip")
                return nil
            }

            print("[tunnel] ngrok downloaded to \(ngrokPath)")
            return ngrokPath
        } catch {
            print("[tunnel] download error: \(error)")
            return nil
        }
    }

    // MARK: - Launch

    /// Save the ngrok auth token
    public func setAuthToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "ngrokAuthToken")
    }

    /// Get the saved ngrok auth token
    public var authToken: String {
        UserDefaults.standard.string(forKey: "ngrokAuthToken") ?? ""
    }

    /// Save the ngrok custom domain
    public func setDomain(_ domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "ngrokDomain")
    }

    /// Get the saved ngrok domain
    public var domain: String {
        UserDefaults.standard.string(forKey: "ngrokDomain") ?? ""
    }

    private func launchNgrok(binary: String, port: Int) {
        // Configure auth token if we have one
        let token = authToken
        if !token.isEmpty {
            let configProc = Process()
            configProc.executableURL = URL(fileURLWithPath: binary)
            configProc.arguments = ["config", "add-authtoken", token]
            configProc.standardOutput = Pipe()
            configProc.standardError = Pipe()
            do {
                try configProc.run()
                configProc.waitUntilExit()
                print("[tunnel] auth token configured")
            } catch {
                print("[tunnel] failed to configure auth token: \(error)")
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)

        // Build arguments: ngrok http --url=domain port
        var args = ["http"]
        let savedDomain = domain
        if !savedDomain.isEmpty {
            args += ["--url=\(savedDomain)"]
        }
        args += ["\(port)", "--log", "stdout"]
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Watch ngrok output for auth errors
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("authtoken") || trimmed.contains("ERR_NGROK") {
                Task { @MainActor in
                    self?.status = "needs auth token"
                    print("[tunnel] \(trimmed)")
                }
            }
        }

        processGeneration += 1
        let expectedGeneration = processGeneration
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.processGeneration == expectedGeneration else {
                    print("[tunnel] ignoring stale termination handler")
                    return
                }
                let wasAuthError = self.status == "needs auth token"
                self.isRunning = false
                self.publicURL = nil
                if !wasAuthError {
                    self.status = "tunnel closed"
                }
                print("[tunnel] ngrok process terminated")
            }
        }

        do {
            try proc.run()
            self.process = proc
            status = "connecting..."
            print("[tunnel] ngrok started, pid \(proc.processIdentifier)")

            // If we have a static domain, we know the URL already
            let savedDomain = domain
            if !savedDomain.isEmpty {
                publicURL = "wss://\(savedDomain)"
                status = "connected"
                print("[tunnel] static domain: wss://\(savedDomain)")
            } else {
                startPollingForURL()
            }
        } catch {
            print("[tunnel] failed to start ngrok: \(error)")
            status = "failed to start"
            isRunning = false
        }
    }

    // MARK: - URL Discovery

    /// Poll ngrok's local API to discover the public URL.
    private func startPollingForURL() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Give ngrok a moment to start
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            for attempt in 0..<20 {
                guard !Task.isCancelled else { return }

                if let url = await Self.fetchTunnelURL() {
                    self.publicURL = url
                    self.status = "connected"
                    print("[tunnel] public URL: \(url)")
                    return
                }

                let delay = UInt64(min(1_000_000_000 * (attempt + 1), 3_000_000_000))
                try? await Task.sleep(nanoseconds: delay)
            }

            status = "could not get public URL"
            print("[tunnel] failed to discover public URL after retries")
        }
    }

    /// Fetch the public HTTPS URL from ngrok's local API (localhost:4040).
    private static func fetchTunnelURL() async -> String? {
        guard let url = URL(string: "http://localhost:4040/api/tunnels") else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tunnels = json["tunnels"] as? [[String: Any]] else {
                return nil
            }

            // Prefer the https tunnel
            for tunnel in tunnels {
                if let publicURL = tunnel["public_url"] as? String,
                   publicURL.hasPrefix("https://") {
                    return "wss://" + publicURL.dropFirst("https://".count)
                }
            }

            // Fall back to any tunnel
            if let first = tunnels.first,
               let publicURL = first["public_url"] as? String {
                if publicURL.hasPrefix("http://") {
                    return "ws://" + publicURL.dropFirst("http://".count)
                }
                return publicURL
            }
        } catch {
            // ngrok API not ready yet
        }
        return nil
    }

    deinit {
        process?.terminate()
    }
}
