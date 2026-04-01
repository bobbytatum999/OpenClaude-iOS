import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var selectedConversation: Conversation?
    @State private var showingNewChatSheet = false
    @State private var showingSettings = false
    @State private var searchText = ""

    var filteredConversations: [Conversation] {
        if searchText.isEmpty { return conversations.filter { !$0.isArchived } }
        return conversations.filter { conv in !conv.isArchived && (conv.title.localizedCaseInsensitiveContains(searchText) || conv.messages?.contains(where: { $0.content.localizedCaseInsensitiveContains(searchText) }) ?? false) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let conversation = selectedConversation { ChatView(conversation: conversation) }
            else { EmptyStateView() }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private var sidebar: some View {
        List(selection: $selectedConversation) {
            Section {
                Button(action: { showingNewChatSheet = true }) { Label("New Chat", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderedProminent)
            }
            Section("Recent Conversations") {
                ForEach(filteredConversations) { conversation in
                    ConversationRow(conversation: conversation)
                        .tag(conversation)
                        .contextMenu {
                            Button { duplicateConversation(conversation) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                            Button { archiveConversation(conversation) } label: { Label("Archive", systemImage: "archivebox") }
                            Divider()
                            Button(role: .destructive) { deleteConversation(conversation) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OpenClaude")
        .searchable(text: $searchText, prompt: "Search conversations")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { showingNewChatSheet = true }) { Label("New Chat", systemImage: "plus") }
                    Divider()
                    Button(action: { showingSettings = true }) { Label("Settings", systemImage: "gear") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showingNewChatSheet) {
            NewChatSheet { provider, model in
                createNewConversation(provider: provider, model: model)
                showingNewChatSheet = false
            }
        }
    }

    private func createNewConversation(provider: Conversation.LLMProvider, model: String) {
        let conversation = Conversation(title: "New Chat", model: model, provider: provider)
        modelContext.insert(conversation)
        selectedConversation = conversation
    }

    private func duplicateConversation(_ conversation: Conversation) {
        let duplicate = Conversation(title: conversation.title + " (Copy)", model: conversation.model, provider: conversation.provider, systemPrompt: conversation.systemPrompt)
        if let messages = conversation.messages {
            for message in messages {
                let copiedMessage = Message(conversationId: duplicate.id, role: message.role, content: message.content)
                modelContext.insert(copiedMessage)
            }
        }
        modelContext.insert(duplicate)
    }

    private func archiveConversation(_ conversation: Conversation) { conversation.isArchived = true }

    private func deleteConversation(_ conversation: Conversation) {
        if selectedConversation?.id == conversation.id { selectedConversation = nil }
        modelContext.delete(conversation)
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: conversation.provider.icon).foregroundStyle(Color.accentColor).font(.caption)
                Text(conversation.displayTitle).lineLimit(1).font(.system(.body, design: .rounded))
                Spacer()
            }
            HStack {
                Text(conversation.model).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(conversation.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EmptyStateView: View {
    @State private var isAnimating = false
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 80)).foregroundStyle(Color.accentColor).symbolEffect(.bounce, options: .repeat(3), value: isAnimating)
            Text("Welcome to OpenClaude").font(.largeTitle).fontWeight(.bold)
            Text("Select a conversation or start a new chat").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "cpu", text: "Run models locally on your device")
                FeatureRow(icon: "cloud", text: "Connect to OpenAI, Anthropic, Hugging Face")
                FeatureRow(icon: "hammer", text: "Use tools for file operations")
                FeatureRow(icon: "lock.shield", text: "Your data stays private")
            }
            .padding(.top, 20)
            Spacer()
        }
        .padding()
        .onAppear { isAnimating = true }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct NewChatSheet: View {
    let onCreate: (Conversation.LLMProvider, String) -> Void
    @State private var selectedProvider: Conversation.LLMProvider = .openAI
    @State private var selectedModel = "gpt-4o"
    @State private var availableModels: [LLMModel] = []
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(Conversation.LLMProvider.allCases, id: \.self) { provider in
                            Label(provider.displayName, systemImage: provider.icon).tag(provider)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .onChange(of: selectedProvider) { _, _ in loadModels() }
                }
                Section("Model") {
                    if isLoading { ProgressView() }
                    else {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(availableModels, id: \.id) { model in Text(model.name).tag(model.id) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
                Section {
                    Button("Create Chat") { onCreate(selectedProvider, selectedModel) }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { loadModels() }
        }
    }

    private func loadModels() {
        isLoading = true
        Task {
            let client = LLMClientFactory.client(for: selectedProvider)
            do {
                let models = try await client.listModels()
                await MainActor.run {
                    availableModels = models
                    if let first = models.first { selectedModel = first.id }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    availableModels = defaultModels(for: selectedProvider)
                    selectedModel = availableModels.first?.id ?? "gpt-4o"
                    isLoading = false
                }
            }
        }
    }

    private func defaultModels(for provider: Conversation.LLMProvider) -> [LLMModel] {
        switch provider {
        case .openAI: return [.gpt4o, .gpt4oMini]
        case .anthropic: return [.claudeSonnet, .claudeHaiku]
        case .huggingFace: return [LLMModel(id: "meta-llama/Llama-2-70b-chat-hf", name: "Llama 2 70B", description: "", contextWindow: 4096, supportsTools: false, supportsVision: false)]
        case .ollama: return [LLMModel(id: "llama3.1", name: "Llama 3.1", description: "", contextWindow: 8192, supportsTools: false, supportsVision: false)]
        case .local: return []
        case .codex: return [LLMModel(id: "codexplan", name: "Codex Plan", description: "", contextWindow: 128000, supportsTools: true, supportsVision: false)]
        }
    }
}
