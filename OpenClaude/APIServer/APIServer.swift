import Foundation
import Network

@MainActor
class APIServer: ObservableObject {
    private static let _shared = APIServer()
    static var shared: APIServer { _shared }
    @Published var isRunning = false
    @Published var port: UInt16 = 8080
    @Published var requestCount: Int = 0
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let localModelService = LocalModelService()
    private let queue = DispatchQueue(label: "com.openclaude.apiserver", qos: .utility)
    private init() {}

    func start() async {
        guard !isRunning else { return }
        let config = APIConfiguration.load()
        self.port = UInt16(config.localServerPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: self.port))
            self.listener = listener
        } catch {
            print("Failed to create listener: \(error)")
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isRunning = true; print("API Server started on port \(self?.port ?? 0)")
                case .failed(let error): print("API Server failed: \(error)"); self?.isRunning = false
                case .cancelled: self?.isRunning = false
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }
        listener.start(queue: queue)
    }

    func stop() async {
        listener?.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
        isRunning = false
    }

    func restart() async { await stop(); await start() }

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                Task { @MainActor in
                    self?.connections.removeAll { $0 === connection }
                }
            }
        }
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection)
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else { connection.cancel(); return }
            if let requestString = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self.requestCount += 1
                    self.handleHTTPRequest(requestString, on: connection)
                }
            }
            if isComplete { connection.cancel() }
        }
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { sendErrorResponse(status: 400, message: "Bad Request", on: connection); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { sendErrorResponse(status: 400, message: "Bad Request", on: connection); return }
        let method = parts[0]
        let path = parts[1]
        var body: Data?
        if let bodyRange = request.range(of: "\r\n\r\n") { body = String(request[bodyRange.upperBound...]).data(using: .utf8) }
        switch (method, path) {
        case ("GET", "/v1/models"): handleListModels(on: connection)
        case ("POST", "/v1/chat/completions"): handleChatCompletion(body: body, on: connection)
        case ("GET", "/health"): handleHealthCheck(on: connection)
        case ("GET", "/"): handleRoot(on: connection)
        default: sendErrorResponse(status: 404, message: "Not Found", on: connection)
        }
    }

    private func handleListModels(on connection: NWConnection) {
        let models = localModelService.availableModels()
        let response: [String: Any] = ["object": "list", "data": models.map { ["id": $0.id, "object": "model", "created": Int(Date().timeIntervalSince1970), "owned_by": "openclaude-local"] }]
        sendJSONResponse(status: 200, body: response, on: connection)
    }

    private func handleChatCompletion(body: Data?, on connection: NWConnection) {
        guard let body = body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { sendErrorResponse(status: 400, message: "Invalid JSON", on: connection); return }
        let model = json["model"] as? String ?? "local-model"
        let messages = json["messages"] as? [[String: Any]] ?? []
        let stream = json["stream"] as? Bool ?? false
        let temperature = json["temperature"] as? Double ?? 0.7
        let maxTokens = json["max_tokens"] as? Int ?? 2048
        let internalMessages = messages.compactMap { msg -> LLMMessagePayload? in
            guard let role = msg["role"] as? String, let content = msg["content"] as? String else { return nil }
            return LLMMessagePayload(role: role, content: content)
        }
        if stream { handleStreamingCompletion(model: model, messages: internalMessages, temperature: temperature, maxTokens: maxTokens, on: connection) }
        else { handleNonStreamingCompletion(model: model, messages: internalMessages, temperature: temperature, maxTokens: maxTokens, on: connection) }
    }

    private func handleStreamingCompletion(model: String, messages: [LLMMessagePayload], temperature: Double, maxTokens: Int, on connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        sendData(headers.data(using: .utf8)!, on: connection)
        Task {
            let id = "chatcmpl-\(UUID().uuidString)"
            let created = Int(Date().timeIntervalSince1970)
            let roleChunk: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [["index": 0, "delta": ["role": "assistant"], "finish_reason": NSNull()]]]
            sendSSEEvent(data: roleChunk, on: connection)
            let fullResponse = await localModelService.generate(messages: messages, temperature: temperature, maxTokens: maxTokens)
            let words = fullResponse.components(separatedBy: " ")
            for (index, word) in words.enumerated() {
                let content = index == 0 ? word : " " + word
                let chunk: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [["index": 0, "delta": ["content": content], "finish_reason": NSNull()]]]
                sendSSEEvent(data: chunk, on: connection)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let finishChunk: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [["index": 0, "delta": [String: String](), "finish_reason": "stop"]]]
            sendSSEEvent(data: finishChunk, on: connection)
            sendData("data: [DONE]\n\n".data(using: .utf8)!, on: connection)
            connection.cancel()
        }
    }

    private func handleNonStreamingCompletion(model: String, messages: [LLMMessagePayload], temperature: Double, maxTokens: Int, on connection: NWConnection) {
        Task {
            let content = await localModelService.generate(messages: messages, temperature: temperature, maxTokens: maxTokens)
            let promptTokens = messages.map { $0.content.count / 4 }.reduce(0, +)
            let completionTokens = content.count / 4
            let response: [String: Any] = ["id": "chatcmpl-\(UUID().uuidString)", "object": "chat.completion", "created": Int(Date().timeIntervalSince1970), "model": model, "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]], "usage": ["prompt_tokens": promptTokens, "completion_tokens": completionTokens, "total_tokens": promptTokens + completionTokens]]
            sendJSONResponse(status: 200, body: response, on: connection)
        }
    }

    private func handleHealthCheck(on connection: NWConnection) {
        let response: [String: Any] = ["status": "healthy", "version": "1.0.0", "models": localModelService.availableModels().count]
        sendJSONResponse(status: 200, body: response, on: connection)
    }

    private func handleRoot(on connection: NWConnection) {
        let html = """
            <!DOCTYPE html><html><head><title>OpenClaude Local API</title><style>body{font-family:-apple-system,sans-serif;max-width:800px;margin:50px auto;padding:20px}code{background:#f4f4f4;padding:2px 6px;border-radius:3px}pre{background:#f4f4f4;padding:15px;border-radius:5px;overflow-x:auto}</style></head><body><h1>OpenClaude Local API Server</h1><p>Running on port \(port)</p><h2>Endpoints</h2><ul><li><code>GET /v1/models</code> - List models</li><li><code>POST /v1/chat/completions</code> - Chat completions</li><li><code>GET /health</code> - Health check</li></ul></body></html>
            """
        sendHTMLResponse(status: 200, body: html, on: connection)
    }

    private func sendJSONResponse(status: Int, body: [String: Any], on connection: NWConnection) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted) else { sendErrorResponse(status: 500, message: "Internal Error", on: connection); return }
        let response = "HTTP/1.1 \(status) \(HTTPStatusText(status))\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nConnection: close\r\n\r\n"
        var data = response.data(using: .utf8)!
        data.append(jsonData)
        sendData(data, on: connection)
        connection.cancel()
    }

    private func sendHTMLResponse(status: Int, body: String, on connection: NWConnection) {
        let bodyData = body.data(using: .utf8)!
        let response = "HTTP/1.1 \(status) \(HTTPStatusText(status))\r\nContent-Type: text/html\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var data = response.data(using: .utf8)!
        data.append(bodyData)
        sendData(data, on: connection)
        connection.cancel()
    }

    private func sendErrorResponse(status: Int, message: String, on connection: NWConnection) {
        let body: [String: Any] = ["error": ["message": message, "type": "api_error", "code": status]]
        sendJSONResponse(status: status, body: body, on: connection)
    }

    private func sendSSEEvent(data: [String: Any], on connection: NWConnection) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else { return }
        let event = "data: \(String(data: jsonData, encoding: .utf8)!)\n\n"
        sendData(event.data(using: .utf8)!, on: connection)
    }

    private func sendData(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func HTTPStatusText(_ code: Int) -> String {
        switch code { case 200: return "OK"; case 400: return "Bad Request"; case 404: return "Not Found"; case 500: return "Internal Error"; default: return "Unknown" }
    }
}
