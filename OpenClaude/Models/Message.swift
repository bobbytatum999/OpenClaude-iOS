import Foundation
import SwiftData

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    var toolCallsData: Data?
    var toolResultsData: Data?
    var isStreaming: Bool
    var isError: Bool
    var model: String?
    var tokensUsed: Int?

    enum MessageRole: String, Codable, Sendable {
        case user, assistant, system, tool
    }

    struct ToolCall: Codable, Sendable {
        let id: String
        let name: String
        let arguments: String
    }

    struct ToolResult: Codable, Sendable {
        let toolCallId: String
        let output: String
        let isError: Bool
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var toolCalls: [ToolCall]? {
        get {
            guard let data = toolCallsData else { return nil }
            return try? JSONDecoder().decode([ToolCall].self, from: data)
        }
        set {
            toolCallsData = try? JSONEncoder().encode(newValue)
        }
    }

    var toolResults: [ToolResult]? {
        get {
            guard let data = toolResultsData else { return nil }
            return try? JSONDecoder().decode([ToolResult].self, from: data)
        }
        set {
            toolResultsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(id: UUID = UUID(), conversationId: UUID, role: MessageRole, content: String,
         timestamp: Date = Date(), toolCalls: [ToolCall]? = nil, toolResults: [ToolResult]? = nil,
         isStreaming: Bool = false, isError: Bool = false, model: String? = nil, tokensUsed: Int? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.roleRaw = role.rawValue
        self.content = content
        self.timestamp = timestamp
        self.toolCallsData = try? JSONEncoder().encode(toolCalls)
        self.toolResultsData = try? JSONEncoder().encode(toolResults)
        self.isStreaming = isStreaming
        self.isError = isError
        self.model = model
        self.tokensUsed = tokensUsed
    }

    var isUser: Bool { role == .user }
    var isAssistant: Bool { role == .assistant }
    var isSystem: Bool { role == .system }
    var isTool: Bool { role == .tool }
}

struct ToolDefinition: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let parameters: ToolParameters

    init(name: String, description: String, parameters: ToolParameters) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    struct ToolParameters: Codable, Sendable {
        let type: String
        let properties: [String: ToolProperty]
        let required: [String]
    }

    struct ToolProperty: Codable, Sendable {
        let type: String
        let description: String
        let enumValues: [String]?
        enum CodingKeys: String, CodingKey {
            case type, description, enumValues = "enum"
        }
    }

    static let allTools: [ToolDefinition] = [bashTool, fileReadTool, fileWriteTool, fileEditTool, grepTool, globTool, webFetchTool, webSearchTool]

    static let bashTool = ToolDefinition(name: "bash", description: "Execute bash commands",
        parameters: .init(type: "object", properties: [
            "command": .init(type: "string", description: "The bash command to execute", enumValues: nil),
            "timeout": .init(type: "integer", description: "Timeout in seconds", enumValues: nil)
        ], required: ["command"]))

    static let fileReadTool = ToolDefinition(name: "file_read", description: "Read file contents",
        parameters: .init(type: "object", properties: [
            "path": .init(type: "string", description: "Absolute path to file", enumValues: nil),
            "offset": .init(type: "integer", description: "Line offset", enumValues: nil),
            "limit": .init(type: "integer", description: "Max lines", enumValues: nil)
        ], required: ["path"]))

    static let fileWriteTool = ToolDefinition(name: "file_write", description: "Write to file",
        parameters: .init(type: "object", properties: [
            "path": .init(type: "string", description: "File path", enumValues: nil),
            "content": .init(type: "string", description: "Content to write", enumValues: nil)
        ], required: ["path", "content"]))

    static let fileEditTool = ToolDefinition(name: "file_edit", description: "Edit file",
        parameters: .init(type: "object", properties: [
            "path": .init(type: "string", description: "File path", enumValues: nil),
            "old_string": .init(type: "string", description: "Text to replace", enumValues: nil),
            "new_string": .init(type: "string", description: "Replacement", enumValues: nil)
        ], required: ["path", "old_string", "new_string"]))

    static let grepTool = ToolDefinition(name: "grep", description: "Search files",
        parameters: .init(type: "object", properties: [
            "pattern": .init(type: "string", description: "Regex pattern", enumValues: nil),
            "path": .init(type: "string", description: "Directory or file", enumValues: nil),
            "include": .init(type: "string", description: "File pattern", enumValues: nil)
        ], required: ["pattern", "path"]))

    static let globTool = ToolDefinition(name: "glob", description: "Find files by pattern",
        parameters: .init(type: "object", properties: [
            "pattern": .init(type: "string", description: "Glob pattern", enumValues: nil),
            "path": .init(type: "string", description: "Directory", enumValues: nil)
        ], required: ["pattern"]))

    static let webFetchTool = ToolDefinition(name: "web_fetch", description: "Fetch URL content",
        parameters: .init(type: "object", properties: [
            "url": .init(type: "string", description: "URL to fetch", enumValues: nil)
        ], required: ["url"]))

    static let webSearchTool = ToolDefinition(name: "web_search", description: "Search web",
        parameters: .init(type: "object", properties: [
            "query": .init(type: "string", description: "Search query", enumValues: nil),
            "num_results": .init(type: "integer", description: "Number of results", enumValues: nil)
        ], required: ["query"]))
}
