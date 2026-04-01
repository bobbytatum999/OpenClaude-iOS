import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var providerRaw: String
    var systemPrompt: String
    var isArchived: Bool
    var tokenCount: Int
    @Relationship(deleteRule: .cascade) var messages: [Message]?

    enum LLMProvider: String, Codable, CaseIterable, Sendable {
        case openAI = "openai", anthropic = "anthropic", huggingFace = "huggingface", ollama = "ollama", local = "local", codex = "codex"

        var displayName: String {
            switch self {
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .huggingFace: return "Hugging Face"
            case .ollama: return "Ollama"
            case .local: return "Local Model"
            case .codex: return "Codex"
            }
        }

        var icon: String {
            switch self {
            case .openAI: return "circle.hexagongrid.fill"
            case .anthropic: return "a.circle.fill"
            case .huggingFace: return "face.smiling.fill"
            case .ollama: return "server.rack"
            case .local: return "cpu.fill"
            case .codex: return "code.square.fill"
            }
        }
    }

    var provider: LLMProvider {
        get { LLMProvider(rawValue: providerRaw) ?? .openAI }
        set { providerRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), title: String = "New Chat", createdAt: Date = Date(), updatedAt: Date = Date(),
         model: String = "gpt-4o", provider: LLMProvider = .openAI, systemPrompt: String = Conversation.defaultSystemPrompt,
         isArchived: Bool = false, tokenCount: Int = 0, messages: [Message] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.providerRaw = provider.rawValue
        self.systemPrompt = systemPrompt
        self.isArchived = isArchived
        self.tokenCount = tokenCount
        self.messages = messages
    }

    static let defaultSystemPrompt = """
        You are Claude, an AI assistant. You have access to tools for bash, file operations, grep, glob, and web tasks. Use tools when helpful.
        """
}

extension Conversation {
    var sortedMessages: [Message] {
        guard let messages = messages else { return [] }
        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    var lastMessage: Message? { sortedMessages.last }
    var messageCount: Int { messages?.count ?? 0 }

    var displayTitle: String {
        if title != "New Chat" { return title }
        if let firstUserMessage = sortedMessages.first(where: { $0.isUser }) {
            let preview = firstUserMessage.content.prefix(30)
            return preview.isEmpty ? "New Chat" : String(preview) + (preview.count >= 30 ? "..." : "")
        }
        return "New Chat"
    }

    func updateTimestamp() { updatedAt = Date() }

    func generateTitle(from content: String) {
        let cleanContent = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        title = cleanContent.count > 40 ? String(cleanContent.prefix(40)) + "..." : cleanContent
    }
}

@Model
final class DownloadedModel {
    @Attribute(.unique) var id: UUID
    var modelId: String
    var name: String
    var about: String
    var size: Int64
    var downloadedSize: Int64
    var downloadURL: String
    var localPath: String?
    var isDownloaded: Bool
    var isDownloading: Bool
    var downloadProgress: Double
    var downloadDate: Date?
    var quantization: String
    var parameters: String

    init(id: UUID = UUID(), modelId: String, name: String, description: String = "", size: Int64 = 0,
         downloadedSize: Int64 = 0, downloadURL: String = "", localPath: String? = nil, isDownloaded: Bool = false,
         isDownloading: Bool = false, downloadProgress: Double = 0, downloadDate: Date? = nil,
         quantization: String = "Q4_K_M", parameters: String = "7B") {
        self.id = id
        self.modelId = modelId
        self.name = name
        self.about = description
        self.size = size
        self.downloadedSize = downloadedSize
        self.downloadURL = downloadURL
        self.localPath = localPath
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.downloadProgress = downloadProgress
        self.downloadDate = downloadDate
        self.quantization = quantization
        self.parameters = parameters
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct APIConfiguration: Codable, Equatable, Sendable {
    var openAIKey: String = ""
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var openAIModel: String = "gpt-4o"
    var anthropicKey: String = ""
    var anthropicModel: String = "claude-3-5-sonnet-20241022"
    var huggingFaceKey: String = ""
    var ollamaURL: String = "http://localhost:11434"
    var codexKey: String = ""
    var useLocalServer: Bool = true
    var localServerPort: Int = 8080

    static let `default` = APIConfiguration()
    static let sharedKey = "api_configuration"

    static func load() -> APIConfiguration {
        guard let data = UserDefaults.standard.data(forKey: sharedKey),
              let config = try? JSONDecoder().decode(APIConfiguration.self, from: data) else {
            return .default
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: APIConfiguration.sharedKey)
        }
    }
}
