import SwiftUI
import SwiftData

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @State private var showingModelPicker = false
    @FocusState private var isInputFocused: Bool

    private var sortedMessages: [Message] { conversation.sortedMessages }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sortedMessages) { message in MessageBubble(message: message).id(message.id) }
                        if viewModel.isGenerating { TypingIndicator().id("typing") }
                    }
                    .padding()
                }
                .onChange(of: sortedMessages.count) { _, _ in
                    if let last = sortedMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: viewModel.isGenerating) { _, _ in withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
            Divider()
            VStack(spacing: 8) {
                if viewModel.isGenerating {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("Generating...").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { viewModel.cancelGeneration() }.font(.caption).buttonStyle(.bordered).tint(Color.red)
                    }
                    .padding(.horizontal)
                }
                HStack(spacing: 12) {
                    TextField("Message...", text: $messageText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .focused($isInputFocused)
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).foregroundStyle(messageText.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .disabled(messageText.isEmpty || viewModel.isGenerating)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
        }
        .navigationTitle(conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { showingModelPicker = true }) { Label("Change Model", systemImage: "cpu") }
                    Divider()
                    Button(action: clearConversation) { Label("Clear Chat", systemImage: "eraser") }
                    Button(action: exportConversation) { Label("Export", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showingModelPicker) { ModelPickerSheet(conversation: conversation) }
        .onAppear { viewModel.setConversation(conversation, context: modelContext) }
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        let content = messageText
        messageText = ""
        Task { await viewModel.sendMessage(content) }
    }

    private func clearConversation() {
        if let messages = conversation.messages { for message in messages { modelContext.delete(message) } }
        conversation.title = "New Chat"
    }

    private func exportConversation() {
        let exportText = sortedMessages.map { "[\($0.role.rawValue.uppercased())]\n\($0.content)\n" }.joined(separator: "\n---\n\n")
        let activityVC = UIActivityViewController(activityItems: [exportText], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController { rootVC.present(activityVC, animated: true) }
    }
}

struct TypingIndicator: View {
    @State private var animationOffset: CGFloat = 0
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(.secondary).frame(width: 6, height: 6).offset(y: animationOffset)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.15), value: animationOffset)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .onAppear { animationOffset = -4 }
    }
}

struct ModelPickerSheet: View {
    @Bindable var conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: Conversation.LLMProvider
    @State private var selectedModel: String
    @State private var availableModels: [LLMModel] = []
    @State private var isLoading = false

    init(conversation: Conversation) {
        self.conversation = conversation
        _selectedProvider = State(initialValue: conversation.provider)
        _selectedModel = State(initialValue: conversation.model)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(Conversation.LLMProvider.allCases, id: \.self) { provider in Label(provider.displayName, systemImage: provider.icon).tag(provider) }
                    }
                    .onChange(of: selectedProvider) { _, _ in loadModels() }
                }
                Section("Model") {
                    if isLoading { ProgressView() }
                    else { Picker("Model", selection: $selectedModel) { ForEach(availableModels, id: \.id) { model in Text(model.name).tag(model.id) } } }
                }
                Section {
                    Button("Apply Changes") {
                        conversation.provider = selectedProvider
                        conversation.model = selectedModel
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Change Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
                    if !models.contains(where: { $0.id == selectedModel }) { selectedModel = models.first?.id ?? "gpt-4o" }
                    isLoading = false
                }
            } catch { await MainActor.run { isLoading = false } }
        }
    }
}
