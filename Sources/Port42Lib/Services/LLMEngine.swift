import Foundation

// MARK: - Streaming Delegate

public protocol LLMStreamDelegate: AnyObject {
    func llmDidReceiveToken(_ token: String)
    func llmDidFinish(fullResponse: String)
    func llmDidError(_ error: Error)
}

// MARK: - Errors

public enum LLMEngineError: Error, LocalizedError {
    case noAuth
    case authExpired
    case httpError(Int, String)
    case invalidResponse
    case streamingError(String)

    public var errorDescription: String? {
        switch self {
        case .noAuth: return "No API key or OAuth token available"
        case .authExpired: return "Your Claude session has expired. Run /login in Claude Code to re-authenticate."
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .invalidResponse: return "Invalid response from API"
        case .streamingError(let msg): return "Streaming error: \(msg)"
        }
    }
}

// MARK: - LLM Engine

public final class LLMEngine: NSObject, URLSessionDataDelegate {
    private let authResolver: AgentAuthResolver
    private var session: URLSession?
    private weak var delegate: LLMStreamDelegate?
    private var buffer = ""
    private var fullResponse = ""
    private var currentTask: URLSessionDataTask?
    private var hasRetriedAuth = false
    private var lastSendArgs: (messages: [[String: Any]], systemPrompt: String, model: String, maxTokens: Int, authConfig: AgentAuthConfig?)?

    public init(authResolver: AgentAuthResolver = .shared) {
        self.authResolver = authResolver
        super.init()
    }

    /// Send a message to an LLM companion and stream the response back.
    public func send(
        messages: [[String: Any]],
        systemPrompt: String,
        model: String = "claude-opus-4-6",
        maxTokens: Int = 8192,
        authConfig: AgentAuthConfig? = nil,
        delegate: LLMStreamDelegate
    ) throws {
        // Clean up any existing session before starting a new one
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil

        let auth: ResolvedAuth
        if let config = authConfig {
            auth = try authResolver.resolve(config: config)
        } else if let detected = authResolver.autoDetect() {
            auth = try authResolver.resolve(config: detected)
        } else {
            throw LLMEngineError.noAuth
        }

        self.delegate = delegate
        self.buffer = ""
        self.fullResponse = ""
        self.hasRetriedAuth = false
        self.lastSendArgs = (messages, systemPrompt, model, maxTokens, authConfig)

        // Build request body
        // OAuth requires the system prompt to be an array
        let systemValue: Any
        if auth.source == .claudeCodeOAuth {
            systemValue = [
                ["type": "text", "text": systemPrompt]
            ]
        } else {
            systemValue = systemPrompt
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": systemValue,
            "messages": messages
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // OAuth tokens use Bearer auth + beta header; API keys use x-api-key
        switch auth.source {
        case .claudeCodeOAuth:
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .apiKey:
            request.setValue(auth.token, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = jsonData

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        currentTask = session?.dataTask(with: request)
        currentTask?.resume()
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        buffer = ""
        fullResponse = ""
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // We'll get the error body in the data callback
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        // Check for HTTP error (non-streaming response)
        if let http = dataTask.response as? HTTPURLResponse, http.statusCode != 200 {
            // On 401, clear cached token and retry once with fresh credentials
            if http.statusCode == 401, !hasRetriedAuth, let args = lastSendArgs, let del = delegate {
                hasRetriedAuth = true
                authResolver.clearCache()
                NSLog("[Port42] Auth 401, clearing cached token and retrying...")
                // Clean up current session before retrying
                self.currentTask = nil
                session.invalidateAndCancel()
                self.session = nil
                DispatchQueue.main.async { [weak self] in
                    do {
                        try self?.send(
                            messages: args.messages,
                            systemPrompt: args.systemPrompt,
                            model: args.model,
                            maxTokens: args.maxTokens,
                            authConfig: args.authConfig,
                            delegate: del
                        )
                    } catch {
                        del.llmDidError(error)
                    }
                }
                return
            }
            let errorMsg = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self] in
                if http.statusCode == 401 {
                    self?.delegate?.llmDidError(LLMEngineError.authExpired)
                } else {
                    self?.delegate?.llmDidError(LLMEngineError.httpError(http.statusCode, errorMsg))
                }
            }
            return
        }

        buffer += chunk
        processBuffer()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            let nsError = error as NSError
            NSLog("[Port42] LLM connection error: domain=%@ code=%d desc=%@", nsError.domain, nsError.code, nsError.localizedDescription)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.llmDidError(error)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.llmDidFinish(fullResponse: self.fullResponse)
            }
        }
        self.session = nil
        self.currentTask = nil
    }

    // MARK: - SSE Parsing

    private func processBuffer() {
        // SSE format: "event: ...\ndata: {...}\n\n"
        while let rangeEnd = buffer.range(of: "\n\n") {
            let eventBlock = String(buffer[buffer.startIndex..<rangeEnd.lowerBound])
            buffer = String(buffer[rangeEnd.upperBound...])
            parseSSEEvent(eventBlock)
        }
    }

    private func parseSSEEvent(_ block: String) {
        var eventType = ""
        var dataLine = ""

        for line in block.components(separatedBy: "\n") {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataLine = String(line.dropFirst(6))
            }
        }

        guard !dataLine.isEmpty,
              let jsonData = dataLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        switch eventType {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                fullResponse += text
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.llmDidReceiveToken(text)
                }
            }

        case "error":
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.llmDidError(LLMEngineError.streamingError(message))
                }
            }

        default:
            break // message_start, content_block_start, content_block_stop, message_delta, message_stop
        }
    }
}
