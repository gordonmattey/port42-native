import Foundation

// MARK: - Gemini Error Translation

private enum GeminiErrorTranslator {
    static func translate(statusCode: Int, body: String) -> LLMEngineError {
        var errorMessage: String?
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any] {
            errorMessage = errorObj["message"] as? String
        }

        switch statusCode {
        case 400:
            return .httpError(400, errorMessage ?? "Bad request. Check your Gemini configuration.")
        case 401, 403:
            return .authExpired("Gemini API key rejected (\(statusCode)). Check your key in Settings → AI connection.")
        case 429:
            return .httpError(429, "Gemini rate limited. Try again shortly.")
        case 500, 503:
            return .httpError(statusCode, "Gemini service error. Try again in a moment.")
        default:
            return .httpError(statusCode, errorMessage ?? body)
        }
    }
}

// MARK: - GeminiEngine

/// LLMBackend implementation for the Google Gemini API (native wire format).
/// Auth: API key passed as ?key= query param.
/// Streaming: SSE events with candidates[].content.parts[] payloads.
public final class GeminiEngine: NSObject, URLSessionDataDelegate, LLMBackend {

    private let store: Port42AuthStore
    private var session: URLSession?
    private weak var delegate: LLMStreamDelegate?
    private var buffer = ""
    private(set) var fullResponse = ""
    private var currentTask: URLSessionDataTask?

    // Tool call accumulation
    private var pendingToolCalls: [(id: String, name: String, input: [String: Any])] = []
    // The last function call parts from the model — needed to build continuation messages
    private(set) var lastFunctionCallParts: [[String: Any]] = []
    private var hasFunctionCall = false

    public init(store: Port42AuthStore = .shared) {
        self.store = store
        super.init()
    }

    // MARK: - LLMBackend

    public func send(
        messages: [[String: Any]],
        systemPrompt: String,
        model: String,
        maxTokens: Int,
        tools: [[String: Any]]?,
        thinkingEnabled: Bool,
        thinkingEffort: String,
        delegate: LLMStreamDelegate
    ) throws {
        guard let apiKey = store.loadCredential(provider: "gemini"), !apiKey.isEmpty else {
            throw LLMEngineError.noAuth
        }

        currentTask?.cancel()
        session?.invalidateAndCancel()
        session = nil

        self.delegate = delegate
        self.buffer = ""
        self.fullResponse = ""
        self.pendingToolCalls = []
        self.lastFunctionCallParts = []
        self.hasFunctionCall = false

        // Build Gemini request body
        // Gemini messages use "user" / "model" roles with parts arrays
        var geminiContents: [[String: Any]] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let geminiRole = role == "assistant" ? "model" : role

            // Content can be a string or an array of blocks (Anthropic format)
            if let text = msg["content"] as? String {
                geminiContents.append([
                    "role": geminiRole,
                    "parts": [["text": text]]
                ])
            } else if let parts = msg["content"] as? [[String: Any]] {
                // Could be Anthropic tool_result blocks (continuation) or text blocks
                // These are pre-formatted Gemini parts — pass through
                geminiContents.append([
                    "role": geminiRole,
                    "parts": parts
                ])
            }
        }

        var body: [String: Any] = [
            "contents": geminiContents,
            "generationConfig": [
                "maxOutputTokens": maxTokens
            ]
        ]

        if !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }

        // Translate Anthropic-format tools to Gemini function_declarations format
        if let tools, !tools.isEmpty {
            body["tools"] = GeminiEngine.translateTools(tools)
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        // Gemini streaming endpoint
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlStr) else {
            throw LLMEngineError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        currentTask = session?.dataTask(with: request)
        currentTask?.resume()
    }

    public func continueWithToolResults(
        results: [(toolUseId: String, content: [[String: Any]])],
        messages: [[String: Any]],
        systemPrompt: String,
        model: String,
        maxTokens: Int,
        tools: [[String: Any]]?,
        thinkingEnabled: Bool,
        thinkingEffort: String
    ) throws {
        // Gemini continuation: append model turn with functionCall parts,
        // then user turn with functionResponse parts.
        var allMessages = messages

        // Model turn: the function call parts
        allMessages.append([
            "role": "model",
            "parts": lastFunctionCallParts
        ])

        // User turn: function responses
        var responseParts: [[String: Any]] = []
        for result in results {
            // result.content is [[String: Any]] with at least one {type: text, text: ...}
            let responseText: Any
            if result.content.count == 1,
               let first = result.content.first,
               let text = first["text"] as? String {
                responseText = ["output": text]
            } else {
                // Serialize as JSON string for multi-block results
                let combined = result.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                responseText = ["output": combined]
            }
            responseParts.append([
                "functionResponse": [
                    "name": toolIdToName(result.toolUseId),
                    "response": responseText
                ]
            ])
        }
        allMessages.append([
            "role": "user",
            "parts": responseParts
        ])

        try send(
            messages: allMessages,
            systemPrompt: systemPrompt,
            model: model,
            maxTokens: maxTokens,
            tools: tools,
            thinkingEnabled: thinkingEnabled,
            thinkingEffort: thinkingEffort,
            delegate: delegate!
        )
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
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        if let http = dataTask.response as? HTTPURLResponse, http.statusCode != 200 {
            let errorBody = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated = GeminiErrorTranslator.translate(statusCode: http.statusCode, body: errorBody)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.llmDidError(translated)
            }
            return
        }

        buffer += chunk
        processBuffer()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.llmDidError(error)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.hasFunctionCall, !self.pendingToolCalls.isEmpty {
                    let calls = self.pendingToolCalls.map { (id: $0.id, name: $0.name, input: $0.input) }
                    self.delegate?.llmDidRequestToolUse(calls: calls)
                } else {
                    self.delegate?.llmDidFinish(fullResponse: self.fullResponse)
                }
            }
        }
        self.session = nil
        self.currentTask = nil
    }

    // MARK: - SSE Parsing

    private func processBuffer() {
        while let rangeEnd = buffer.range(of: "\n\n") {
            let eventBlock = String(buffer[buffer.startIndex..<rangeEnd.lowerBound])
            buffer = String(buffer[rangeEnd.upperBound...])
            parseSSEEvent(eventBlock)
        }
    }

    private func parseSSEEvent(_ block: String) {
        var dataLine = ""
        for line in block.components(separatedBy: "\n") {
            if line.hasPrefix("data: ") {
                dataLine = String(line.dropFirst(6))
            }
        }

        guard !dataLine.isEmpty,
              let jsonData = dataLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        // Gemini: {"candidates": [{"content": {"parts": [...], "role": "model"}, "finishReason": "STOP"}]}
        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            // Check for top-level error
            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.llmDidError(LLMEngineError.streamingError(message))
                }
            }
            return
        }

        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return
        }

        for part in parts {
            if let text = part["text"] as? String {
                fullResponse += text
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.llmDidReceiveToken(text)
                }
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {
                let args = functionCall["args"] as? [String: Any] ?? [:]
                let id = "gemini-\(name)-\(pendingToolCalls.count)"
                pendingToolCalls.append((id: id, name: name, input: args))
                lastFunctionCallParts.append(["functionCall": functionCall])
                hasFunctionCall = true
            }
        }
    }

    // MARK: - Tool Schema Translation

    /// Translate Anthropic-format tool schemas to Gemini function_declarations format.
    /// Input: `[{name, description, input_schema}]` (Anthropic)
    /// Output: `[{function_declarations: [{name, description, parameters}]}]` (Gemini)
    static func translateTools(_ anthropicTools: [[String: Any]]) -> [[String: Any]] {
        let declarations: [[String: Any]] = anthropicTools.compactMap { tool in
            guard let name = tool["name"] as? String,
                  let description = tool["description"] as? String else { return nil }
            var decl: [String: Any] = ["name": name, "description": description]
            if let schema = tool["input_schema"] as? [String: Any] {
                decl["parameters"] = schema
            }
            return decl
        }
        return [["function_declarations": declarations]]
    }

    // MARK: - Test Hooks (internal — used only in test targets)

    func injectSSEForTesting(_ sseText: String, delegate: LLMStreamDelegate) {
        self.delegate = delegate
        buffer += sseText
        processBuffer()
        // Drain the main queue so token callbacks (dispatched async) arrive before assertions
        DispatchQueue.main.sync {}
    }

    func injectHTTPErrorForTesting(statusCode: Int, body: String, delegate: LLMStreamDelegate) {
        self.delegate = delegate
        let translated = GeminiErrorTranslator.translate(statusCode: statusCode, body: body)
        delegate.llmDidError(translated)
    }

    /// Returns the generated tool-call ID for the nth pending call (0-indexed). For tests only.
    func toolIdForTesting(_ index: Int) -> String? {
        guard index < pendingToolCalls.count else { return nil }
        return pendingToolCalls[index].id
    }

    // MARK: - Private

    /// Map a Gemini tool-call id (gemini-toolName-N) back to the tool name for functionResponse.
    private func toolIdToName(_ toolUseId: String) -> String {
        // Gemini tool IDs are "gemini-<name>-<index>" — extract the name
        let parts = toolUseId.components(separatedBy: "-")
        if parts.count >= 3 {
            // Drop "gemini" prefix and index suffix
            return parts.dropFirst().dropLast().joined(separator: "-")
        }
        return toolUseId
    }
}
