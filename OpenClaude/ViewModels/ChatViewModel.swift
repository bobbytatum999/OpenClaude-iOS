import Foundation
import SwiftData

@MainActor
class ChatViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var errorMessage: String?
    private var conversation: Conversation?
    private var modelContext: ModelContext?
    private var currentTask: Task<Void, Never>?
    private let toolExecutor = ToolExecutor.shared

    func setConversation(_ conversation: Conversation, context: ModelContext) {
        self.conversation = conversation
        self.modelContext = context
    }

    func sendMessage(_ content: String) async {
        guard let conversation = conversation, let modelContext = modelContext else { return }
        currentTask?.cancel()
        let userMessage = Message(conversationId: conversation.id, role: .user, content: content)
        modelContext.insert(userMessage)
        if conversation.messageCount == 1 { conversation.generateTitle(from: content) }
        conversation.updateTimestamp()
        isGenerating = true
        errorMessage = nil
        currentTask = Task { await generateResponse(for: conversation) }
    }

    private func generateResponse(for conversation: Conversation) async {
        guard let modelContext = modelContext else { return }
        let assistantMessage = Message(conversationId: conversation.id, role: .assistant, content: "", isStreaming: true)
        modelContext.insert(assistantMessage)
        do {
            let messages = conversation.sortedMessages
            var allMessages = messages
            if !messages.contains(where: { $0.isSystem }) {
                allMessages.insert(Message(conversationId: conversation.id, role: .system, content: conversation.systemPrompt), at: 0)
            }
            // Convert to LLMMessagePayload for sending
            let payloads = allMessages.map { LLMMessagePayload(from: $0) }
            let client = LLMClientFactory.client(for: conversation.provider)
            let tools: [ToolDefinition]? = conversation.provider == .openAI || conversation.provider == .anthropic ? toolExecutor.getToolDefinitions() : nil
            let stream = client.sendMessage(payloads, model: conversation.model, tools: tools, stream: true)
            var fullContent = ""
            var toolCallPayloads: [LLMToolCallPayload] = []
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .content(let content): fullContent = content; assistantMessage.content = content
                case .toolCall(let toolCall): toolCallPayloads.append(toolCall)
                case .done: break
                case .error(let error): throw error
                }
            }
            assistantMessage.isStreaming = false
            assistantMessage.content = fullContent
            // Convert LLMToolCallPayload to Message.ToolCall
            let toolCalls = toolCallPayloads.map { Message.ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
            if !toolCalls.isEmpty {
                assistantMessage.toolCalls = toolCalls
            }
            assistantMessage.model = conversation.model
            if !toolCalls.isEmpty {
                var toolResults: [Message.ToolResult] = []
                for toolCall in toolCalls {
                    toolResults.append(await toolExecutor.execute(toolCall: toolCall))
                }
                assistantMessage.toolResults = toolResults
                let toolResultMessage = Message(conversationId: conversation.id, role: .tool, content: toolResults.map { $0.output }.joined(separator: "\n\n"))
                modelContext.insert(toolResultMessage)
                if !Task.isCancelled { await generateResponse(for: conversation); return }
            }
            conversation.updateTimestamp()
        } catch {
            assistantMessage.isStreaming = false
            assistantMessage.isError = true
            assistantMessage.content = "Error: \(error.localizedDescription)"
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    func cancelGeneration() { currentTask?.cancel(); isGenerating = false }

    func regenerateLastMessage() async {
        guard let conversation = conversation, let lastMessage = conversation.sortedMessages.last(where: { $0.isAssistant }), let modelContext = modelContext else { return }
        modelContext.delete(lastMessage)
        isGenerating = true
        currentTask = Task { await generateResponse(for: conversation) }
    }

    func editMessage(_ message: Message, newContent: String) async {
        guard let conversation = conversation, let modelContext = modelContext else { return }
        message.content = newContent
        let sortedMessages = conversation.sortedMessages
        if let index = sortedMessages.firstIndex(where: { $0.id == message.id }) {
            for msg in sortedMessages.suffix(from: sortedMessages.index(after: index)) { modelContext.delete(msg) }
        }
        isGenerating = true
        currentTask = Task { await generateResponse(for: conversation) }
    }

    func deleteMessage(_ message: Message) { modelContext?.delete(message) }
}

extension Conversation {
    var lastUserMessage: Message? { sortedMessages.last { $0.isUser } }
    var lastAssistantMessage: Message? { sortedMessages.last { $0.isAssistant } }
    func estimateTokenCount() -> Int { sortedMessages.map { $0.content }.joined().count / 4 }
}
