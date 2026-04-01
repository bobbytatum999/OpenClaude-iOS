import Foundation

final class HuggingFaceClient: LLMClientProtocol, @unchecked Sendable {
    let provider: Conversation.LLMProvider = .huggingFace
    private let config: APIConfiguration
    private let urlSession: URLSession
    private let baseURL = "https://api-inference.huggingface.co"

    init() {
        self.config = APIConfiguration.load()
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 600
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    func validateAPIKey() async throws -> Bool {
        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.setValue("Bearer \(config.huggingFaceKey)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    func listModels() async throws -> [LLMModel] {
        return [
            LLMModel(id: "meta-llama/Llama-2-70b-chat-hf", name: "Llama 2 70B Chat", description: "Meta's model", contextWindow: 4096, supportsTools: false, supportsVision: false),
            LLMModel(id: "mistralai/Mistral-7B-Instruct-v0.2", name: "Mistral 7B", description: "Instruction tuned", contextWindow: 8192, supportsTools: false, supportsVision: false),
            LLMModel(id: "google/gemma-7b-it", name: "Gemma 7B", description: "Google's model", contextWindow: 8192, supportsTools: false, supportsVision: false),
            LLMModel(id: "HuggingFaceH4/zephyr-7b-beta", name: "Zephyr 7B", description: "Helpful assistant", contextWindow: 8192, supportsTools: false, supportsVision: false)
        ]
    }

    func sendMessage(_ messages: [LLMMessagePayload], model: String, tools: [ToolDefinition]?, stream: Bool) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let baseURL = self.baseURL
        let config = self.config
        let urlSession = self.urlSession
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "\(baseURL)/models/\(model)")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(config.huggingFaceKey)", forHTTPHeaderField: "Authorization")

                    let prompt = HuggingFaceClient.formatMessages(messages)
                    let body: [String: Any] = ["inputs": prompt, "parameters": ["max_new_tokens": 2048, "temperature": 0.7, "top_p": 0.95, "return_full_text": false], "options": ["wait_for_model": true, "use_cache": true]]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (data, response) = try await urlSession.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }

                    if httpResponse.statusCode == 503 {
                        continuation.yield(.content("Model is loading, please wait..."))
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        let (retryData, retryResponse) = try await urlSession.data(for: request)
                        guard let retryHttpResponse = retryResponse as? HTTPURLResponse, retryHttpResponse.statusCode == 200 else { throw LLMError.serverError("Model failed to load") }
                        if let json = try JSONSerialization.jsonObject(with: retryData) as? [[String: Any]], let first = json.first, let generatedText = first["generated_text"] as? String {
                            continuation.yield(.content(generatedText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    } else if httpResponse.statusCode == 200 {
                        if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = json.first, let generatedText = first["generated_text"] as? String {
                            continuation.yield(.content(generatedText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let generatedText = json["generated_text"] as? String {
                            continuation.yield(.content(generatedText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        } else { throw LLMError.decodingError }
                    } else {
                        let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                        throw LLMError.serverError("HTTP \(httpResponse.statusCode): \(errorText)")
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    private static func formatMessages(_ messages: [LLMMessagePayload]) -> String {
        var prompt = ""
        for message in messages {
            switch message.role {
            case "system": prompt += "<s>[INST] <<SYS>>\n\(message.content)\n<</SYS>>\n\n"
            case "user": prompt += "\(message.content) [/INST]"
            case "assistant": prompt += " \(message.content) </s><s>[INST]"
            case "tool": prompt += "\n[Tool Result]: \(message.content)\n"
            default: prompt += "\(message.content)"
            }
        }
        return prompt
    }

    func searchModels(query: String) async throws -> [HuggingFaceModel] {
        let searchURL = URL(string: "https://huggingface.co/api/models?search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&filter=text-generation&sort=downloads&limit=50")!
        let (data, response) = try await urlSession.data(from: searchURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
        return try JSONDecoder().decode([HuggingFaceModel].self, from: data)
    }

    func getModelInfo(modelId: String) async throws -> HuggingFaceModelDetail {
        let infoURL = URL(string: "https://huggingface.co/api/models/\(modelId)")!
        let (data, response) = try await urlSession.data(from: infoURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
        return try JSONDecoder().decode(HuggingFaceModelDetail.self, from: data)
    }
}

struct HuggingFaceModel: Codable, Identifiable, Sendable {
    let id: String
    let modelId: String
    let author: String?
    let downloads: Int?
    let likes: Int?

    enum CodingKeys: String, CodingKey {
        case id = "_id", modelId = "modelId", author, downloads, likes
    }

    var displayName: String { modelId.components(separatedBy: "/").last ?? modelId }

    var formattedDownloads: String {
        guard let downloads = downloads else { return "0" }
        if downloads >= 1_000_000 { return String(format: "%.1fM", Double(downloads) / 1_000_000) }
        else if downloads >= 1_000 { return String(format: "%.1fK", Double(downloads) / 1_000) }
        return "\(downloads)"
    }
}

struct HuggingFaceModelDetail: Codable, Sendable {
    let id: String
    let modelId: String
    let description: String?
    let downloads: Int?
    let likes: Int?
    let siblings: [ModelFile]?

    enum CodingKeys: String, CodingKey {
        case id = "_id", modelId = "modelId", description, downloads, likes, siblings
    }

    struct ModelFile: Codable, Sendable {
        let rfilename: String
        let size: Int64?
        let lfs: LFSInfo?
        struct LFSInfo: Codable, Sendable { let oid: String; let size: Int64 }
    }

    var totalSize: Int64 { siblings?.compactMap { $0.lfs?.size ?? $0.size }.reduce(0, +) ?? 0 }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file) }
    var ggufFiles: [ModelFile] { siblings?.filter { $0.rfilename.hasSuffix(".gguf") } ?? [] }
    var hasGGUF: Bool { !ggufFiles.isEmpty }
}

final class OllamaClient: LLMClientProtocol, @unchecked Sendable {
    let provider: Conversation.LLMProvider = .ollama
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
        let url = URL(string: "\(config.ollamaURL)/api/tags")!
        let (data, response) = try await urlSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
        struct ModelsResponse: Codable { let models: [OllamaModel] }
        struct OllamaModel: Codable { let name: String; let size: Int64?; let digest: String? }
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return modelsResponse.models.map { LLMModel(id: $0.name, name: $0.name, description: $0.digest?.prefix(12).map { String($0) }.joined() ?? "", contextWindow: 8192, supportsTools: false, supportsVision: $0.name.contains("vision") || $0.name.contains("llava")) }
    }

    func sendMessage(_ messages: [LLMMessagePayload], model: String, tools: [ToolDefinition]?, stream: Bool) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let config = self.config
        let urlSession = self.urlSession
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "\(config.ollamaURL)/api/chat")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let ollamaMessages = messages.map { msg -> [String: String] in
                        var role = "user"
                        switch msg.role {
                        case "system": role = "system"
                        case "user": role = "user"
                        case "assistant": role = "assistant"
                        default: role = "user"
                        }
                        return ["role": role, "content": msg.content]
                    }

                    let body: [String: Any] = ["model": model, "messages": ollamaMessages, "stream": stream, "options": ["temperature": 0.7, "num_ctx": 8192]]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    if stream {
                        let (bytes, response) = try await urlSession.bytes(for: request)
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
                        var currentContent = ""
                        for try await line in bytes.lines {
                            guard let jsonData = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                            if let message = json["message"] as? [String: Any], let content = message["content"] as? String {
                                currentContent += content
                                continuation.yield(.content(currentContent))
                            }
                            if let done = json["done"] as? Bool, done { continuation.finish(); return }
                        }
                        continuation.finish()
                    } else {
                        let (data, response) = try await urlSession.data(for: request)
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw LLMError.invalidResponse }
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let message = json?["message"] as? [String: Any], let content = message["content"] as? String {
                            continuation.yield(.content(content))
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

final class LocalModelClient: LLMClientProtocol, @unchecked Sendable {
    let provider: Conversation.LLMProvider = .local
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
        let url = URL(string: "http://localhost:\(config.localServerPort)/v1/models")!
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return [] }
            struct ModelsResponse: Codable { let data: [LocalModel] }
            struct LocalModel: Codable { let id: String }
            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return modelsResponse.data.map { LLMModel(id: $0.id, name: $0.id, description: "Local", contextWindow: 8192, supportsTools: true, supportsVision: false) }
        } catch { return [] }
    }

    func sendMessage(_ messages: [LLMMessagePayload], model: String, tools: [ToolDefinition]?, stream: Bool) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let localClient = OpenAIClient()
        return localClient.sendMessage(messages, model: model, tools: tools, stream: stream)
    }
}
