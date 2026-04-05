import Foundation

// MARK: - OpenClaw Gateway API Client

/// Connects to a local OpenClaw gateway over WebSocket to manage
/// Port42 plugin configuration and agent routing.
@MainActor
public final class OpenClawService: NSObject, ObservableObject {

    // MARK: - Published state

    @Published public var status: ConnectionStatus = .idle
    @Published public var agents: [OpenClawAgent] = []
    @Published public var pluginInstalled = false
    @Published public var pluginVersion: String?
    @Published public var openclawVersion: String?
    @Published public var updateAvailable = false
    @Published public var error: String?

    public enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case connected
        case notInstalled
        case gatewayOffline
        case error(String)
    }

    public struct OpenClawAgent: Identifiable, Hashable {
        public let id: String
    }

    // MARK: - Internal state

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var gatewayPort: Int = 18789
    private var gatewayToken: String?
    private var reqId = 0
    private var pending: [String: (Result<Any, Error>) -> Void] = [:]
    private var connectReqId: String?
    private var retryCount = 0
    private var maxRetries = 3
    private var retryTask: Task<Void, Never>?

    // MARK: - Config discovery

    /// Read OpenClaw config from ~/.openclaw/openclaw.json
    private static func readConfig() -> (port: Int, token: String)? {
        let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let gateway = json["gateway"] as? [String: Any]
        let port = gateway?["port"] as? Int ?? 18789
        let auth = gateway?["auth"] as? [String: Any]
        let token = auth?["token"] as? String

        guard let token else { return nil }
        return (port, token)
    }

    /// Check if OpenClaw is installed (config file exists)
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.openclaw/openclaw.json")
    }

    /// Get local OpenClaw version by running `npx openclaw --version`
    /// Returns version string like "2026.3.11" or nil
    public static func getLocalVersion() async -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["npx", "openclaw", "--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Output format: "OpenClaw 2026.3.11 (29dc654)"
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            return parts.count >= 2 ? String(parts[1]) : nil
        } catch {
            return nil
        }
    }

    /// Get latest OpenClaw version from npm registry
    /// Returns version string like "2026.3.11" or nil
    public static func getLatestVersion() async -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/openclaw/latest") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String {
                return version
            }
        } catch {}
        return nil
    }

    // MARK: - Connect

    /// Connect to the local OpenClaw gateway with automatic retry
    public func connect() {
        retryCount = 0
        retryTask?.cancel()
        retryTask = nil
        attemptConnect()
    }

    private func attemptConnect() {
        // Clean up any previous connection
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        pending.removeAll()
        reqId = 0
        connectReqId = nil

        guard let config = Self.readConfig() else {
            status = .notInstalled
            return
        }

        gatewayPort = config.port
        gatewayToken = config.token
        status = .connecting
        error = nil

        NSLog("[Port42:OpenClaw] connecting to ws://127.0.0.1:%d (attempt %d/%d)", gatewayPort, retryCount + 1, maxRetries + 1)

        let url = URL(string: "ws://127.0.0.1:\(gatewayPort)")!
        var request = URLRequest(url: url)
        request.setValue("http://127.0.0.1:\(gatewayPort)", forHTTPHeaderField: "Origin")

        let delegate = WebSocketDelegate(service: self)
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        ws = session?.webSocketTask(with: request)
        ws?.resume()
        listen()
    }

    /// Schedule a retry after a delay (2s, 4s, 6s backoff)
    private func scheduleRetry() {
        guard retryCount < maxRetries else {
            NSLog("[Port42:OpenClaw] max retries reached")
            return
        }
        retryCount += 1
        let delay = Double(retryCount) * 2.0
        NSLog("[Port42:OpenClaw] retrying in %.0fs (attempt %d/%d)", delay, retryCount + 1, maxRetries + 1)
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            attemptConnect()
        }
    }

    /// Disconnect from the gateway
    public func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        status = .idle
        pending.removeAll()
    }

    // MARK: - WebSocket I/O

    private func listen() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    default:
                        break
                    }
                    self.listen()
                case .failure(let error):
                    NSLog("[Port42:OpenClaw] WebSocket receive failed: %@", error.localizedDescription)
                    if self.retryCount < self.maxRetries {
                        self.scheduleRetry()
                    } else {
                        self.status = .gatewayOffline
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String
        NSLog("[Port42:OpenClaw] received: type=%@", type ?? "nil")

        if type == "event" {
            let event = json["event"] as? String
            NSLog("[Port42:OpenClaw] event: %@", event ?? "nil")
            if event == "connect.challenge" {
                sendConnect()
            }
            return
        }

        if type == "res" {
            let id = json["id"] as? String ?? ""
            let ok = json["ok"] as? Bool ?? false

            if let handler = pending.removeValue(forKey: id) {
                if ok {
                    handler(.success(json["payload"] as Any))
                } else {
                    let errMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                    handler(.failure(NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg])))
                }
            }

            // After connect succeeds, load initial data
            if id == connectReqId && ok {
                status = .connected
                Analytics.shared.openClawDetected()
                // Extract agents from the hello snapshot (avoids a separate agents.list RPC call
                // which requires operator.read scope the token may not grant)
                if let payload = json["payload"] as? [String: Any],
                   let snapshot = payload["snapshot"] as? [String: Any],
                   let health = snapshot["health"] as? [String: Any],
                   let agentList = health["agents"] as? [[String: Any]] {
                    agents = agentList.compactMap { dict in
                        guard let agentId = dict["agentId"] as? String else { return nil }
                        return OpenClawAgent(id: agentId)
                    }
                    NSLog("[Port42:OpenClaw] loaded %d agents from hello snapshot", agents.count)
                }
                Task { await loadInitialData() }
            }
        }
    }

    // MARK: - RPC

    private func sendConnect() {
        guard let token = gatewayToken else { return }

        let params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "cli",
                "version": "0.1.0",
                "platform": "macos",
                "mode": "webchat"
            ],
            "role": "operator",
            "scopes": ["operator.admin"],
            "auth": ["token": token],
            "caps": [] as [String]
        ]

        connectReqId = request("connect", params: params)
    }

    @discardableResult
    private func request(_ method: String, params: [String: Any]? = nil) -> String {
        reqId += 1
        let id = String(reqId)

        var msg: [String: Any] = [
            "type": "req",
            "id": id,
            "method": method
        ]
        if let params {
            msg["params"] = params
        } else {
            msg["params"] = [String: Any]()
        }

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return id }

        ws?.send(.string(text)) { _ in }
        return id
    }

    /// Send an RPC request and await the result
    private func rpc(_ method: String, params: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let id = request(method, params: params)
            pending[id] = { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let err): continuation.resume(throwing: err)
                }
            }
        }
    }

    // MARK: - API calls

    private func loadInitialData() async {
        // Check plugin status from disk (config.get requires operator.read scope which gateway tokens don't grant)
        let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let plugins = config["plugins"] as? [String: Any]
            let installs = plugins?["installs"] as? [String: Any]
            pluginInstalled = installs?["port42-openclaw"] != nil
                || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.openclaw/extensions/port42-openclaw")
        }

        // Check version in background
        Task {
            async let localV = Self.getLocalVersion()
            async let latestV = Self.getLatestVersion()
            let local = await localV
            let latest = await latestV
            await MainActor.run {
                openclawVersion = local
                if let local, let latest, local != latest {
                    updateAvailable = true
                    NSLog("[Port42:OpenClaw] update available: %@ -> %@", local, latest)
                }
            }
        }
    }

    /// Install the port42-openclaw plugin via CLI (no RPC method for plugin install)
    public func installPlugin() async -> Bool {
        // If plugin files already exist on disk, treat as installed
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.openclaw/extensions/port42-openclaw") {
            pluginInstalled = true
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "openclaw", "plugins", "install", "port42-openclaw"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Treat "already exists" as success
            if process.terminationStatus == 0 || output.contains("already exists") {
                pluginInstalled = true
                Analytics.shared.openClawPluginInstalled()
                return true
            } else {
                // Strip ANSI escape codes for cleaner display
                let clean = output.replacingOccurrences(of: "\\x1B\\[[0-9;]*m", with: "", options: .regularExpression)
                error = "Plugin install failed: \(clean)"
                return false
            }
        } catch {
            self.error = "Could not run openclaw CLI: \(error.localizedDescription)"
            return false
        }
    }

    /// Force update the port42-openclaw plugin
    public func updatePlugin() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "openclaw", "plugins", "install", "port42-openclaw"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return await withCheckedContinuation { cont in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume(returning: true)
                } else {
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let clean = output.replacingOccurrences(of: "\\x1B\\[[0-9;]*m", with: "", options: .regularExpression)
                    Task { @MainActor in self.error = "Plugin update failed: \(clean)" }
                    cont.resume(returning: false)
                }
            }
            do {
                try process.run()
            } catch {
                Task { @MainActor in self.error = "Could not run openclaw CLI: \(error.localizedDescription)" }
                cont.resume(returning: false)
            }
        }
    }

    /// Add a Port42 channel account to OpenClaw and bind the agent.
    /// Reads and writes openclaw.json directly on disk — avoids RPC methods that
    /// require operator.read/operator.admin scopes the gateway token doesn't grant.
    /// NOTE: local-only. Remote OpenClaw gateways would need the RPC path with a
    /// properly-scoped device-auth token instead of the broadcast gateway token.
    public func addChannelAgent(agentId: String, inviteURL: String, trigger: String = "mention", owner: String = "clawd") async -> Bool {
        let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"

        guard let data = FileManager.default.contents(atPath: configPath),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            error = "Could not read OpenClaw config"
            return false
        }

        // Ensure channels.port42.accounts structure
        var channels = config["channels"] as? [String: Any] ?? [:]
        var port42 = channels["port42"] as? [String: Any] ?? [:]
        var accounts = port42["accounts"] as? [String: Any] ?? [:]

        accounts[agentId] = [
            "invite": inviteURL,
            "displayName": agentId,
            "owner": owner,
            "trigger": trigger
        ] as [String: Any]

        port42["accounts"] = accounts
        channels["port42"] = port42
        config["channels"] = channels

        // Add binding if not already present
        var bindings = config["bindings"] as? [[String: Any]] ?? []
        let hasBinding = bindings.contains { binding in
            let match = binding["match"] as? [String: Any]
            return match?["channel"] as? String == "port42" && match?["accountId"] as? String == agentId
        }
        if !hasBinding {
            bindings.append([
                "type": "route",
                "agentId": agentId,
                "match": ["channel": "port42", "accountId": agentId]
            ])
            config["bindings"] = bindings
        }

        guard let newData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            error = "Could not serialize config"
            return false
        }

        do {
            try newData.write(to: URL(fileURLWithPath: configPath))
        } catch {
            self.error = "Could not write config: \(error.localizedDescription)"
            return false
        }

        // Restart the gateway so it picks up the new config.
        // Use launchctl kickstart -k to stop + restart via launchd (respects the correct binary path
        // from the plist, unlike pkill which kills but won't restart if the plist path is stale).
        let uid = String(getuid())
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        restart.arguments = ["kickstart", "-k", "gui/\(uid)/ai.openclaw.gateway"]
        try? restart.run()

        // Wait for gateway to restart then reconnect
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        connect()
        return true
    }

    // MARK: - WebSocket Delegate

    private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var service: OpenClawService?

        init(service: OpenClawService) {
            self.service = service
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            NSLog("[Port42:OpenClaw] WebSocket connected")
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            Task { @MainActor in
                guard let service = self.service else { return }
                if service.retryCount < service.maxRetries {
                    service.scheduleRetry()
                } else {
                    service.status = .gatewayOffline
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                NSLog("[Port42:OpenClaw] Connection failed: %@", error.localizedDescription)
                Task { @MainActor in
                    guard let service = self.service else { return }
                    if service.retryCount < service.maxRetries {
                        service.scheduleRetry()
                    } else {
                        service.status = .gatewayOffline
                    }
                }
            }
        }
    }
}
