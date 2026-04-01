import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var apiServer = APIServer.shared
    @StateObject private var modelManager = ModelManager.shared
    @State private var config = APIConfiguration.load()
    @State private var showingClearConfirmation = false
    @State private var testResult: TestResult?
    @State private var isTesting = false

    enum TestResult {
        case success(String), failure(String)
        var message: String {
            switch self { case .success(let m): return m; case .failure(let m): return m }
        }
        var color: Color {
            switch self { case .success: return Color.green; case .failure: return Color.red }
        }
        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable Local API Server", isOn: $config.useLocalServer)
                    HStack {
                        Text("Server Port")
                        Spacer()
                        TextField("Port", value: $config.localServerPort, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(apiServer.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(apiServer.isRunning ? "Running" : "Stopped").foregroundStyle(.secondary)
                        }
                    }
                    if apiServer.isRunning { Text("Server URL: http://localhost:\(apiServer.port)").font(.caption).foregroundStyle(.secondary) }
                    Button("Restart Server") { Task { await apiServer.restart() } }
                } header: { Text("Local API Server") } footer: { Text("Run models locally via OpenAI-compatible API") }

                Section("OpenAI") {
                    SecureField("API Key", text: $config.openAIKey).textContentType(.password)
                    TextField("Base URL", text: $config.openAIBaseURL).keyboardType(.URL).textInputAutocapitalization(.never)
                    TextField("Model", text: $config.openAIModel).textInputAutocapitalization(.never)
                }

                Section("Anthropic") {
                    SecureField("API Key", text: $config.anthropicKey).textContentType(.password)
                    TextField("Model", text: $config.anthropicModel).textInputAutocapitalization(.never)
                }

                Section("Hugging Face") {
                    SecureField("API Key", text: $config.huggingFaceKey).textContentType(.password)
                    NavigationLink("Downloaded Models") { ModelDownloadView() }
                    HStack { Text("Storage Used"); Spacer(); Text(modelManager.formattedTotalStorage).foregroundStyle(.secondary) }
                }

                Section("Ollama") {
                    TextField("Ollama URL", text: $config.ollamaURL).keyboardType(.URL).textInputAutocapitalization(.never)
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            Text("Test Connection")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting)
                    if let testResult = testResult {
                        HStack {
                            Image(systemName: testResult.isSuccess ? "checkmark.circle" : "xmark.circle").foregroundStyle(testResult.color)
                            Text(testResult.message).font(.caption)
                        }
                    }
                }

                Section {
                    Button("Clear All Conversations", role: .destructive) { showingClearConfirmation = true }
                    Button("Clear Downloaded Models", role: .destructive) { modelManager.clearAllModels() }
                }

                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { saveConfig(); dismiss() } }
            }
            .alert("Clear All Conversations?", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {}
            } message: { Text("This action cannot be undone.") }
        }
    }

    private func saveConfig() { config.save(); UnifiedLLMService.shared.resetClient() }

    private func testConnection() {
        isTesting = true; testResult = nil
        Task {
            do {
                let success = try await UnifiedLLMService.shared.validateConfiguration()
                await MainActor.run { isTesting = false; testResult = success ? .success("Connection successful!") : .failure("Invalid API key") }
            } catch { await MainActor.run { isTesting = false; testResult = .failure(error.localizedDescription) } }
        }
    }
}

struct ModelDownloadView: View {
    @StateObject private var modelManager = ModelManager.shared
    @State private var searchQuery = ""
    @State private var searchResults: [HuggingFaceModel] = []
    @State private var isSearching = false
    @State private var showingRecommended = true

    var body: some View {
        List {
            Section("Downloaded Models") {
                if modelManager.downloadedModels.isEmpty { Text("No models downloaded").foregroundStyle(.secondary) }
                else {
                    ForEach(modelManager.downloadedModels) { model in DownloadedModelRow(model: model) }
                        .onDelete { indexSet in for index in indexSet { modelManager.deleteModel(modelManager.downloadedModels[index]) } }
                }
                HStack { Text("Total Storage").fontWeight(.medium); Spacer(); Text(modelManager.formattedTotalStorage).foregroundStyle(.secondary) }
            }
            Section("Search Hugging Face") {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search models...", text: $searchQuery).submitLabel(.search).onSubmit(performSearch)
                }
                if isSearching { ProgressView().frame(maxWidth: .infinity) }
            }
            if showingRecommended {
                Section("Recommended Models") {
                    ForEach(ModelManager.recommendedModels, id: \.id) { model in RecommendedModelRow(model: model) }
                }
            } else {
                Section("Search Results") { ForEach(searchResults) { model in SearchResultRow(model: model) } }
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func performSearch() {
        guard !searchQuery.isEmpty else { showingRecommended = true; return }
        isSearching = true; showingRecommended = false
        Task {
            do {
                let results = try await modelManager.searchModels(query: searchQuery)
                await MainActor.run { searchResults = results; isSearching = false }
            } catch { await MainActor.run { isSearching = false } }
        }
    }
}

struct DownloadedModelRow: View {
    let model: DownloadedModel
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(model.formattedSize).font(.caption).foregroundStyle(.secondary)
                    if let date = model.downloadDate { Text("•").font(.caption).foregroundStyle(.secondary); Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        }
    }
}

struct RecommendedModelRow: View {
    let model: ModelManager.PredefinedModel
    @StateObject private var modelManager = ModelManager.shared
    @State private var isDownloading = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name).fontWeight(.medium)
                    if model.recommended { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.yellow) }
                }
                Text(model.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("\(String(format: "%.1f", model.sizeGB)) GB").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if isDownloading {
                if let progress = modelManager.downloadProgress[model.id] { CircularProgressView(progress: progress).frame(width: 32, height: 32) }
                else { ProgressView() }
            } else if modelManager.isModelDownloaded(modelId: model.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green) }
            else { Button(action: downloadModel) { Image(systemName: "icloud.and.arrow.down").font(.title3).foregroundStyle(Color.accentColor) } }
        }
    }

    private func downloadModel() {
        isDownloading = true
        Task {
            do { try await modelManager.downloadModel(modelId: model.id); await MainActor.run { isDownloading = false } }
            catch { await MainActor.run { isDownloading = false } }
        }
    }
}

struct SearchResultRow: View {
    let model: HuggingFaceModel
    @State private var showingDetail = false
    var body: some View {
        Button(action: { showingDetail = true }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName).fontWeight(.medium).foregroundStyle(.primary)
                    if let author = model.author { Text("by \(author)").font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        if model.downloads != nil { Label(model.formattedDownloads, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary) }
                        if let likes = model.likes, likes > 0 { Label("\(likes)", systemImage: "heart").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingDetail) { ModelDetailSheet(modelId: model.modelId) }
    }
}

struct CircularProgressView: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: progress).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%").font(.caption2).fontWeight(.medium)
        }
    }
}

struct ModelDetailSheet: View {
    let modelId: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelManager = ModelManager.shared
    @State private var modelDetail: HuggingFaceModelDetail?
    @State private var isLoading = true
    @State private var selectedQuantization = "Q4_K_M"

    var body: some View {
        NavigationStack {
            Group {
                if isLoading { ProgressView() }
                else if let detail = modelDetail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(detail.id).font(.title2).fontWeight(.bold)
                                if let description = detail.description { Text(description).foregroundStyle(.secondary) }
                                HStack(spacing: 16) {
                                    if let downloads = detail.downloads { Label("\(downloads)", systemImage: "arrow.down").font(.caption) }
                                    if let likes = detail.likes { Label("\(likes)", systemImage: "heart").font(.caption) }
                                }
                                .foregroundStyle(.secondary)
                            }
                            Divider()
                            if detail.hasGGUF {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Available Files").font(.headline)
                                    ForEach(detail.ggufFiles.prefix(5), id: \.rfilename) { file in
                                        HStack {
                                            Text(file.rfilename).font(.callout)
                                            Spacer()
                                            if let size = file.lfs?.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                                Divider()
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Quantization").font(.headline)
                                    Picker("Quantization", selection: $selectedQuantization) {
                                        ForEach(["Q2_K", "Q3_K_M", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0"], id: \.self) { Text($0).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                }
                                Button(action: downloadModel) {
                                    HStack {
                                        Image(systemName: "icloud.and.arrow.down")
                                        Text("Download Model")
                                    }
                                    .frame(maxWidth: .infinity).padding().background(Color.accentColor).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            } else { Label("No GGUF files available", systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange) }
                        }
                        .padding()
                    }
                } else { ContentUnavailableView("Model Not Found", systemImage: "exclamationmark.triangle") }
            }
            .navigationTitle("Model Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { loadModelDetail() }
        }
    }

    private func loadModelDetail() {
        Task {
            do {
                let detail = try await modelManager.getModelDetail(modelId: modelId)
                await MainActor.run { modelDetail = detail; isLoading = false }
            } catch { await MainActor.run { isLoading = false } }
        }
    }

    private func downloadModel() {
        Task {
            do { try await modelManager.downloadModel(modelId: modelId, quantization: selectedQuantization); await MainActor.run { dismiss() } }
            catch { print("Download failed: \(error)") }
        }
    }
}
