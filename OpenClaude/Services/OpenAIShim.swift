import Foundation

@MainActor
class OpenAIShim {
    private static let _shared = OpenAIShim()
    static var shared: OpenAIShim { _shared }
    private init() {}

    func translateAnthropicToOpenAI(_ messages: [LLMMessagePayload]) -> [[String: Any]] {
        return messages.compactMap { message -> [String: Any]? in
            var dict: [String: Any] = [:]
            switch message.role {
            case "system": dict["role"] = "system"
            case "user": dict["role"] = "user"
            case "assistant": dict["role"] = "assistant"
            case "tool":
                dict["role"] = "user"
                dict["content"] = "Tool result: \(message.content)"
                return dict
            default: dict["role"] = "user"
            }
            if let toolCalls = message.toolCalls {
                dict["tool_calls"] = toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
                if !message.content.isEmpty { dict["content"] = message.content }
            } else { dict["content"] = message.content }
            return dict
        }
    }

    func translateOpenAIToolToAnthropic(_ openAITool: [String: Any]) -> ToolDefinition? {
        guard let function = openAITool["function"] as? [String: Any], let name = function["name"] as? String, let description = function["description"] as? String, let parameters = function["parameters"] as? [String: Any], let type = parameters["type"] as? String, let properties = parameters["properties"] as? [String: [String: Any]], let required = parameters["required"] as? [String] else { return nil }
        let toolProperties = properties.mapValues { ToolDefinition.ToolProperty(type: $0["type"] as? String ?? "string", description: $0["description"] as? String ?? "", enumValues: $0["enum"] as? [String]) }
        return ToolDefinition(name: name, description: description, parameters: .init(type: type, properties: toolProperties, required: required))
    }
}

struct ProviderConfiguration: Sendable {
    let provider: Conversation.LLMProvider
    let apiKey: String
    let baseURL: String
    let model: String
    let maxTokens: Int
    let temperature: Double
    let topP: Double

    static func current() -> ProviderConfiguration {
        let config = APIConfiguration.load()
        let provider: Conversation.LLMProvider
        let apiKey: String
        let baseURL: String
        let model: String

        if !config.openAIKey.isEmpty {
            provider = .openAI; apiKey = config.openAIKey; baseURL = config.openAIBaseURL; model = config.openAIModel
        } else if !config.anthropicKey.isEmpty {
            provider = .anthropic; apiKey = config.anthropicKey; baseURL = "https://api.anthropic.com"; model = config.anthropicModel
        } else if !config.huggingFaceKey.isEmpty {
            provider = .huggingFace; apiKey = config.huggingFaceKey; baseURL = "https://api-inference.huggingface.co"; model = "meta-llama/Llama-2-70b-chat-hf"
        } else if config.useLocalServer {
            provider = .local; apiKey = ""; baseURL = "http://localhost:\(config.localServerPort)"; model = "local-model"
        } else {
            provider = .ollama; apiKey = ""; baseURL = config.ollamaURL; model = "llama3.1"
        }

        return ProviderConfiguration(provider: provider, apiKey: apiKey, baseURL: baseURL, model: model, maxTokens: 4096, temperature: 0.7, topP: 0.95)
    }
}

@MainActor
class UnifiedLLMService {
    private static let _shared = UnifiedLLMService()
    static var shared: UnifiedLLMService { _shared }
    private var currentClient: LLMClientProtocol?
    private var currentConfig: ProviderConfiguration?
    private init() {}

    func getClient() -> LLMClientProtocol {
        let config = ProviderConfiguration.current()
        if let currentConfig = currentConfig, currentConfig.provider == config.provider, let currentClient = currentClient { return currentClient }
        let client = LLMClientFactory.client(for: config.provider)
        self.currentClient = client
        self.currentConfig = config
        return client
    }

    func resetClient() { currentClient = nil; currentConfig = nil }

    func sendMessage(messages: [LLMMessagePayload], conversationId: UUID, tools: [ToolDefinition]? = nil, stream: Bool = true) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let client = getClient()
        let config = ProviderConfiguration.current()
        return client.sendMessage(messages, model: config.model, tools: tools, stream: stream)
    }

    func validateConfiguration() async throws -> Bool {
        let client = getClient()
        return try await client.validateAPIKey()
    }

    func availableModels() async throws -> [LLMModel] {
        let client = getClient()
        return try await client.listModels()
    }
}
