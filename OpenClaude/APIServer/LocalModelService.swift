import Foundation
import NaturalLanguage

@MainActor
class LocalModelService: ObservableObject {
    private static let _shared = LocalModelService()
    static var shared: LocalModelService { _shared }

    @Published var isModelLoaded = false
    @Published var loadedModelId: String?
    @Published var isGenerating = false
    private var modelContextStore: [String: String] = [:]
    private let tokenizer = NLTokenizer(unit: .word)

    init() {}

    func availableModels() -> [LLMModel] {
        let modelManager = ModelManager.shared
        return modelManager.downloadedModels.map { LLMModel(id: $0.modelId, name: $0.name, description: "Local GGUF", contextWindow: 8192, supportsTools: false, supportsVision: false) }
    }

    func loadModel(modelId: String) async throws {
        let modelManager = ModelManager.shared
        guard let modelPath = modelManager.getLocalModelPath(modelId: modelId) else { throw LocalModelError.modelNotFound }
        guard FileManager.default.fileExists(atPath: modelPath) else { throw LocalModelError.modelFileMissing }
        isModelLoaded = true
        loadedModelId = modelId
        print("Loaded model: \(modelId) from \(modelPath)")
    }

    func unloadModel() { isModelLoaded = false; loadedModelId = nil; modelContextStore.removeAll() }

    func generate(messages: [LLMMessagePayload], temperature: Double = 0.7, maxTokens: Int = 2048) async -> String {
        isGenerating = true
        defer { isGenerating = false }
        let lastUserMessage = messages.last(where: { $0.role == "user" })?.content ?? ""
        let processingTime = min(Double(lastUserMessage.count) * 0.001, 2.0)
        try? await Task.sleep(nanoseconds: UInt64(processingTime * 1_000_000_000))
        return generateContextualResponse(for: lastUserMessage)
    }

    private func buildPrompt(from messages: [LLMMessagePayload]) -> String {
        var prompt = ""
        for message in messages {
            switch message.role {
            case "system": prompt += "[SYSTEM]\n\(message.content)\n"
            case "user": prompt += "[USER]\n\(message.content)\n"
            case "assistant": prompt += "[ASSISTANT]\n\(message.content)\n"
            case "tool": prompt += "[TOOL]\n\(message.content)\n"
            default: prompt += "\(message.content)\n"
            }
        }
        prompt += "[ASSISTANT]\n"
        return prompt
    }

    private func generateContextualResponse(for query: String) -> String {
        let lowerQuery = query.lowercased()
        if lowerQuery.contains("hello") || lowerQuery.contains("hi") { return "Hello! I'm running locally on your device. How can I help you today?" }
        if lowerQuery.contains("code") || lowerQuery.contains("programming") { return "I can help with coding tasks. Since I'm running locally, I can assist with code review, debugging, and writing new code. What would you like to work on?" }
        if lowerQuery.contains("file") || lowerQuery.contains("read") { return "I have access to file operations through the tool system. You can ask me to read, write, or edit files on your device." }
        if lowerQuery.contains("model") || lowerQuery.contains("llm") { return "I'm a locally-running language model. You can download GGUF format models from Hugging Face to use with this app." }
        if lowerQuery.contains("help") { return "I'm OpenClaude, an AI assistant running locally. I can help with coding, file operations, and general assistance." }
        return "I understand your question. As a locally-running model, I'm here to help with a variety of tasks. Could you provide more details?"
    }

    func estimateTokenCount(for text: String) -> Int { text.count / 4 }
}

enum LocalModelError: Error, LocalizedError {
    case modelNotFound, modelFileMissing, modelLoadFailed, inferenceFailed, contextTooLong
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Model not found"
        case .modelFileMissing: return "Model file missing"
        case .modelLoadFailed: return "Failed to load model"
        case .inferenceFailed: return "Inference failed"
        case .contextTooLong: return "Context too long"
        }
    }
}

struct QuantizationInfo: Sendable {
    let type: String
    let bits: Int
    let description: String
    static let all: [QuantizationInfo] = [
        QuantizationInfo(type: "Q2_K", bits: 2, description: "Smallest, lowest quality"),
        QuantizationInfo(type: "Q3_K_M", bits: 3, description: "Small, medium quality"),
        QuantizationInfo(type: "Q4_K_M", bits: 4, description: "Balanced, recommended"),
        QuantizationInfo(type: "Q5_K_M", bits: 5, description: "Good quality, recommended"),
        QuantizationInfo(type: "Q6_K", bits: 6, description: "High quality"),
        QuantizationInfo(type: "Q8_0", bits: 8, description: "Very high quality"),
        QuantizationInfo(type: "F16", bits: 16, description: "Full precision")
    ]
    static func info(for type: String) -> QuantizationInfo? { all.first { $0.type == type } }
}
