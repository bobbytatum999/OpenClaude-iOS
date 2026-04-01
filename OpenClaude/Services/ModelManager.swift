import Foundation
import Combine

@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()
    
    @Published var downloadedModels: [DownloadedModel] = []
    @Published var isLoading = false
    @Published var downloadProgress: [String: Double] = [:]
    @Published var currentDownload: String?
    
    private let hfClient = HuggingFaceClient()
    private let fileManager = FileManager.default
    
    private var modelsDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Models", isDirectory: true)
    }
    
    private init() {
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        loadDownloadedModels()
    }
    
    func loadDownloadedModels() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
            downloadedModels = contents.compactMap { url -> DownloadedModel? in
                guard url.pathExtension == "gguf" || url.pathExtension == "bin" else { return nil }
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let size = attributes?[.size] as? Int64 ?? 0
                let creationDate = attributes?[.creationDate] as? Date
                return DownloadedModel(
                    modelId: url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    size: size,
                    localPath: url.path,
                    isDownloaded: true,
                    downloadDate: creationDate
                )
            }
        } catch { print("Error loading models: \(error)") }
    }
    
    func downloadModel(modelId: String, quantization: String = "Q4_K_M") async throws {
        guard currentDownload == nil else { throw ModelError.alreadyDownloading }
        currentDownload = modelId
        downloadProgress[modelId] = 0
        defer { 
            currentDownload = nil 
            downloadProgress.removeValue(forKey: modelId)
        }
        
        let hfClient = self.hfClient
        let modelInfo = try await hfClient.getModelInfo(modelId: modelId)
        guard let ggufFile = modelInfo.ggufFiles.first(where: { $0.rfilename.contains(quantization) }) ?? modelInfo.ggufFiles.first else { throw ModelError.noGGUFFiles }
        
        let downloadURL = URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(ggufFile.rfilename)")!
        let config = APIConfiguration.load()
        var request = URLRequest(url: downloadURL)
        if !config.huggingFaceKey.isEmpty {
            request.setValue("Bearer \(config.huggingFaceKey)", forHTTPHeaderField: "Authorization")
        }
        
        let urlSession = URLSession(configuration: .default)
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw ModelError.downloadFailed }
        
        let totalSize = ggufFile.lfs?.size ?? (httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : 0)
        var downloadedSize: Int64 = 0
        let destinationURL = modelsDirectory.appendingPathComponent(ggufFile.rfilename)
        
        // Use a file handle to write directly to disk instead of keeping everything in memory
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }
        
        // In Swift 6, we should update progress less frequently to avoid flooding the main actor
        var lastUpdate = Date()
        
        for try await byte in asyncBytes {
            try fileHandle.write(contentsOf: Data([byte]))
            downloadedSize += 1
            
            if totalSize > 0 {
                let now = Date()
                if now.timeIntervalSince(lastUpdate) > 0.1 { // Update max 10 times per second
                    let progress = Double(downloadedSize) / Double(totalSize)
                    let mid = modelId
                    await MainActor.run { [weak self] in
                        self?.downloadProgress[mid] = progress
                    }
                    lastUpdate = now
                }
            }
        }
        
        await MainActor.run { [weak self] in
            self?.loadDownloadedModels()
        }
    }
    
    func searchModels(query: String) async throws -> [HuggingFaceModel] {
        isLoading = true
        defer { isLoading = false }
        return try await hfClient.searchModels(query: query)
    }
    
    func getModelDetail(modelId: String) async throws -> HuggingFaceModelDetail {
        return try await hfClient.getModelInfo(modelId: modelId)
    }
    
    func deleteModel(_ model: DownloadedModel) {
        guard let path = model.localPath else { return }
        try? fileManager.removeItem(at: URL(fileURLWithPath: path))
        loadDownloadedModels()
    }
    
    func isModelDownloaded(modelId: String) -> Bool {
        return downloadedModels.contains { $0.modelId == modelId }
    }
    
    func getLocalModelPath(modelId: String) -> String? {
        return downloadedModels.first { $0.modelId == modelId }?.localPath
    }
    
    struct PredefinedModel: Sendable {
        let id: String
        let name: String
        let description: String
        let sizeGB: Double
        let recommended: Bool
    }
    
    static let recommendedModels: [PredefinedModel] = [
        PredefinedModel(id: "TheBloke/Llama-2-7B-Chat-GGUF", name: "Llama 2 7B Chat", description: "Meta's Llama 2 optimized for chat", sizeGB: 3.8, recommended: true),
        PredefinedModel(id: "TheBloke/Mistral-7B-Instruct-v0.2-GGUF", name: "Mistral 7B Instruct", description: "Mistral's instruction-tuned model", sizeGB: 4.1, recommended: true),
        PredefinedModel(id: "TheBloke/phi-2-GGUF", name: "Phi-2", description: "Microsoft's compact model", sizeGB: 1.6, recommended: true),
        PredefinedModel(id: "TheBloke/CodeLlama-7B-Instruct-GGUF", name: "CodeLlama 7B", description: "Code-specialized model", sizeGB: 3.8, recommended: true)
    ]
    
    var totalStorageUsed: Int64 { downloadedModels.reduce(0) { $0 + $1.size } }
    var formattedTotalStorage: String { ByteCountFormatter.string(fromByteCount: totalStorageUsed, countStyle: .file) }
    
    func clearAllModels() {
        for model in downloadedModels {
            if let path = model.localPath { try? fileManager.removeItem(atPath: path) }
        }
        loadDownloadedModels()
    }
}

enum ModelError: Error, LocalizedError {
    case alreadyDownloading, noGGUFFiles, downloadFailed, invalidURL, modelNotFound, insufficientStorage
    var errorDescription: String? {
        switch self {
        case .alreadyDownloading: return "A download is already in progress"
        case .noGGUFFiles: return "No GGUF files found"
        case .downloadFailed: return "Failed to download model"
        case .invalidURL: return "Invalid download URL"
        case .modelNotFound: return "Model not found"
        case .insufficientStorage: return "Insufficient storage"
        }
    }
}
