import Foundation

protocol LLMClientProtocol: AnyObject, Sendable {
    var provider: Conversation.LLMProvider { get }
    func sendMessage(_ messages: [LLMMessagePayload], model: String, tools: [ToolDefinition]?, stream: Bool) -> AsyncThrowingStream<LLMStreamEvent, Error>
    func validateAPIKey() async throws -> Bool
    func listModels() async throws -> [LLMModel]
}

struct LLMMessagePayload: Sendable {
    let role: String
    let content: String
    let toolCalls: [LLMToolCallPayload]?

    init(role: String, content: String, toolCalls: [LLMToolCallPayload]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }

    init(from message: Message) {
        self.role = message.role.rawValue
        self.content = message.content
        if let tc = message.toolCalls {
            self.toolCalls = tc.map { LLMToolCallPayload(id: $0.id, name: $0.name, arguments: $0.arguments) }
        } else {
            self.toolCalls = nil
        }
    }
}

struct LLMToolCallPayload: Sendable {
    let id: String
    let name: String
    let arguments: String
}

enum LLMStreamEvent: Sendable {
    case content(String)
    case toolCall(LLMToolCallPayload)
    case done
    case error(Error)
}

struct LLMModel: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let contextWindow: Int
    let supportsTools: Bool
    let supportsVision: Bool

    static let gpt4o = LLMModel(id: "gpt-4o", name: "GPT-4o", description: "Most capable multimodal", contextWindow: 128000, supportsTools: true, supportsVision: true)
    static let gpt4oMini = LLMModel(id: "gpt-4o-mini", name: "GPT-4o Mini", description: "Fast affordable", contextWindow: 128000, supportsTools: true, supportsVision: true)
    static let claudeSonnet = LLMModel(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", description: "Balanced", contextWindow: 200000, supportsTools: true, supportsVision: true)
    static let claudeHaiku = LLMModel(id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", description: "Fast", contextWindow: 200000, supportsTools: true, supportsVision: false)
}

struct LLMClientFactory: Sendable {
    static func client(for provider: Conversation.LLMProvider) -> LLMClientProtocol {
        switch provider {
        case .openAI, .codex: return OpenAIClient()
        case .anthropic: return AnthropicClient()
        case .huggingFace: return HuggingFaceClient()
        case .ollama: return OllamaClient()
        case .local: return LocalModelClient()
        }
    }
}

final class OpenAIClient: LLMClientProtocol, @unchecked Sendable {
    let provider: Conversation.LLMProvider = .openAI
    private let config: APIConfiguration
    private let urlSession: URLSession

    init() {
        self.config = APIConfiguration.load()
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 600
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    func validateAPIKey() async throws -> Bool {
        let _ = try await listModels()
        return true
    }

    func listModels() async throws -> [LLMModel] {
        var request = URLRequest(url: URL(string: "\(config.openAIBaseURL)/models")!)
        request.setValue("Bearer \(config.openAIKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LLMError.invalidResponse
        }
        struct ModelsResponse: Codable { let data: [OpenAIModel] }
        struct OpenAIModel: Codable { let id: String }
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return modelsResponse.data.map { LLMModel(id: $0.id, name: $0.id, description: "", contextWindow: 128000, supportsTools: true, supportsVision: $0.id.contains("vision") || $0.id.contains("gpt-4o")) }
    }

    func sendMessage(_ messages: [LLMMessagePayload], model: String, tools: [ToolDefinition]?, stream: Bool) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let config = self.config
        let urlSession = self.urlSession
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "\(config.openAIBaseURL)/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(config.openAIKey)", forHTTPHeaderField: "Authorization")

                    let openAIMessages = messages.map { msg -> [String: Any] in
                        var dict: [String: Any] = ["role": msg.role, "content": msg.content]
                        if let toolCalls = msg.toolCalls {
                            dict["tool_calls"] = toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
                        }
                        return dict
                    }

                    var body: [String: Any] = ["model": model, "messages": openAIMessages, "stream": stream, "max_tokens": 32000]

                    if let tools = tools, !tools.isEmpty {
                        body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": ["type": $0.parameters.type, "properties": $0.parameters.properties.mapValues { ["type": $0.type, "description": $0.description] }, "required": $0.parameters.required]]] }
                        body["tool_choice"] = "auto"
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    if stream {
                        let (bytes, response) = try await urlSession.bytes(for: request)
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
                        var currentContent = ""
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let data = String(line.dropFirst(6))
                            if data == "[DONE]" { continuation.finish(); return }
                            guard let jsonData = data.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                  let choices = json["choices"] as? [[String: Any]] else { continue }
                            for choice in choices {
                                if let delta = choice["delta"] as? [String: Any] {
                                    if let content = delta["content"] as? String { currentContent += content; continuation.yield(.content(currentContent)) }
                                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                        for toolCall in toolCalls {
                                            if let id = toolCall["id"] as? String, let function = toolCall["function"] as? [String: Any], let name = function["name"] as? String, let arguments = function["arguments"] as? String {
                                                continuation.yield(.toolCall(LLMToolCallPayload(id: id, name: name, arguments: arguments)))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        continuation.finish()
                    } else {
                        let (data, response) = try await urlSession.data(for: request)
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let choices = json?["choices"] as? [[String: Any]], let first = choices.first, let message = first["message"] as? [String: Any] {
                            if let content = message["content"] as? String { continuation.yield(.content(content)) }
                            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                                for toolCall in toolCalls {
                                    if let id = toolCall["id"] as? String, let function = toolCall["function"] as? [String: Any], let name = function["name"] as? String, let arguments = function["arguments"] as? String {
                                        continuation.yield(.toolCall(LLMToolCallPayload(id: id, name: name, arguments: arguments)))
                                    }
                                }
                            }
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }
}

final class AnthropicClient: LLMClientProtocol, @unchecked Sendable {
    let provider: Conversation.LLMProvider = .anthropic
    private let config: APIConfiguration
    private let urlSession: URLSession

    init() {
        self.config = APIConfiguration.load()
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 600
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    func validateAPIKey() async throws -> Bool { return true }

    func listModels() async throws -> [LLMModel] {
        return [.claudeSonnet, .claudeHaiku, LLMModel(id: "claude-3-opus-20240229", name: "Claude 3 Opus", description: "Most powerful", contextWindow: 200000, supportsTools: true, supportsVision: true)]
    }

    func sendMessage(_ messages: [LLMMessagePayload], model: String, tools: [ToolDefinition]?, stream: Bool) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let config = self.config
        let urlSession = self.urlSession
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "https://api.anthropic.com/v1/messages")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(config.anthropicKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let systemMessage = messages.first { $0.role == "system" }?.content ?? ""
                    let chatMessages = messages.filter { $0.role != "system" }.map { ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.content] }

                    var body: [String: Any] = ["model": model, "messages": chatMessages, "max_tokens": 4096, "stream": stream]
                    if !systemMessage.isEmpty { body["system"] = systemMessage }

                    if let tools = tools, !tools.isEmpty {
                        body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": ["type": $0.parameters.type, "properties": $0.parameters.properties.mapValues { ["type": $0.type, "description": $0.description] }, "required": $0.parameters.required]] }
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    if stream {
                        let (bytes, response) = try await urlSession.bytes(for: request)
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
                        var currentContent = ""
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let data = String(line.dropFirst(6))
                            guard let jsonData = data.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                            if let type = json["type"] as? String {
                                if type == "content_block_delta", let delta = json["delta"] as? [String: Any], let text = delta["text"] as? String {
                                    currentContent += text
                                    continuation.yield(.content(currentContent))
                                }
                                if type == "message_stop" { continuation.finish(); return }
                            }
                        }
                        continuation.finish()
                    } else {
                        let (data, response) = try await urlSession.data(for: request)
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let content = json?["content"] as? [[String: Any]] {
                            var fullText = ""
                            for block in content { if let text = block["text"] as? String { fullText += text } }
                            continuation.yield(.content(fullText))
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }
}

enum LLMError: Error, LocalizedError, Sendable {
    case invalidResponse, invalidAPIKey, rateLimited, modelNotFound, networkError(Error), decodingError, serverError(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .invalidAPIKey: return "Invalid API key"
        case .rateLimited: return "Rate limit exceeded"
        case .modelNotFound: return "Model not found"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError: return "Failed to decode response"
        case .serverError(let m): return "Server error: \(m)"
        }
    }
}
