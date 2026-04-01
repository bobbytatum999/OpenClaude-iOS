import Foundation
import llama

actor LlamaEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var batch: llama_batch?
    
    init(modelPath: String, contextSize: UInt32 = 4096) throws {
        llama_backend_init()
        
        var modelParams = llama_model_default_params()
        // Enable Metal for fast inference on iOS
        modelParams.n_gpu_layers = 99
        
        self.model = llama_load_model_from_file(modelPath.cString(using: .utf8), modelParams)
        guard self.model != nil else {
            throw LocalModelError.modelLoadFailed
        }
        
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_threads = 4
        ctxParams.n_threads_batch = 4
        
        self.context = llama_new_context_with_model(self.model, ctxParams)
        guard self.context != nil else {
            llama_free_model(self.model)
            self.model = nil
            throw LocalModelError.modelLoadFailed
        }
    }
    
    func unload() {
        if let batch = self.batch {
            llama_batch_free(batch)
            self.batch = nil
        }
        if let ctx = self.context {
            llama_free(ctx)
            self.context = nil
        }
        if let model = self.model {
            llama_free_model(model)
            self.model = nil
        }
        llama_backend_free()
    }
    
    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard let ctx = context else { return [] }
        var tokens = [llama_token](repeating: 0, count: Int(llama_n_ctx(ctx)))
        let n_tokens = llama_tokenize(model, text.cString(using: .utf8), Int32(text.utf8.count), &tokens, Int32(tokens.count), addBos, false)
        if n_tokens < 0 {
            return []
        }
        return Array(tokens.prefix(Int(n_tokens)))
    }
    
    private func addToBatch(_ batch: inout llama_batch, token: llama_token, pos: Int32, seq_id: Int32, logits: Bool) {
        let idx = Int(batch.n_tokens)
        batch.token[idx] = token
        batch.pos[idx] = pos
        batch.n_seq_id[idx] = 1
        batch.seq_id[idx]![0] = seq_id
        batch.logits[idx] = logits ? 1 : 0
        batch.n_tokens += 1
    }
    
    private func tokenToStr(token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        _ = llama_token_to_piece(model, token, &buf, Int32(buf.count), 0, false)
        return String(cString: buf)
    }
    
    func infer(prompt: String, maxTokens: Int) -> String {
        guard let ctx = context, let mdl = model else { return "Model not loaded properly." }
        
        let tokens = tokenize(text: prompt, addBos: true)
        if batch == nil {
            batch = llama_batch_init(512, 0, 1)
        }
        guard var b = batch else { return "Failed to init batch." }
        b.n_tokens = 0
        
        for (i, token) in tokens.enumerated() {
            let isLast = (i == tokens.count - 1)
            addToBatch(&b, token: token, pos: Int32(i), seq_id: 0, logits: isLast)
        }
        
        guard llama_decode(ctx, b) == 0 else { return "Error: llama_decode failed on prompt." }
        
        var response = ""
        var currentIdx = Int32(tokens.count)
        
        for _ in 0..<maxTokens {
            let n_vocab = llama_n_vocab(mdl)
            guard let logits = llama_get_logits_ith(ctx, b.n_tokens - 1) else { break }
            
            var candidates = (0..<n_vocab).map { i in
                llama_token_data(id: i, logit: logits[Int(i)], p: 0)
            }
            
            var candidates_p = llama_token_data_array(data: &candidates, size: candidates.count, sorted: false)
            let new_token = llama_sample_token_greedy(ctx, &candidates_p)
            
            if new_token == llama_token_eos(mdl) || new_token == llama_token_eot(mdl) {
                break
            }
            
            response += tokenToStr(token: new_token)
            
            b.n_tokens = 0
            addToBatch(&b, token: new_token, pos: currentIdx, seq_id: 0, logits: true)
            currentIdx += 1
            
            if llama_decode(ctx, b) != 0 {
                break
            }
            // Need to update the stored batch pointer with the mutated batch so it doesn't leak
            self.batch = b
        }
        
        return response
    }
}

@MainActor
class LocalModelService: ObservableObject {
    private static let _shared = LocalModelService()
    static var shared: LocalModelService { _shared }

    @Published var isModelLoaded = false
    @Published var loadedModelId: String?
    @Published var isGenerating = false
    
    private var engine: LlamaEngine?

    init() {}

    func availableModels() -> [LLMModel] {
        let modelManager = ModelManager.shared
        return modelManager.downloadedModels.map { LLMModel(id: $0.modelId, name: $0.name, description: "Local GGUF", contextWindow: 8192, supportsTools: false, supportsVision: false) }
    }



    func loadModel(modelId: String) async throws {
        let modelManager = ModelManager.shared
        guard let modelPath = modelManager.getLocalModelPath(modelId: modelId) else { throw LocalModelError.modelNotFound }
        guard FileManager.default.fileExists(atPath: modelPath) else { throw LocalModelError.modelFileMissing }
        
        if let currentEngine = engine {
            await currentEngine.unload()
        }
        
        let newEngine = try LlamaEngine(modelPath: modelPath)
        self.engine = newEngine
        
        isModelLoaded = true
        loadedModelId = modelId
        print("Loaded llama.cpp engine for model: \(modelId) from \(modelPath)")
    }

    func unloadModel() async {
        if let currentEngine = engine {
            await currentEngine.unload()
        }
        engine = nil
        isModelLoaded = false
        loadedModelId = nil
    }

    func generate(messages: [LLMMessagePayload], temperature: Double = 0.7, maxTokens: Int = 2048) async -> String {
        guard let currentEngine = engine else { return "No model loaded." }
        isGenerating = true
        defer { isGenerating = false }
        
        let prompt = buildPrompt(from: messages)
        return await currentEngine.infer(prompt: prompt, maxTokens: maxTokens)
    }

    private func buildPrompt(from messages: [LLMMessagePayload]) -> String {
        var prompt = ""
        for message in messages {
            switch message.role {
            case "system": prompt += "<|system|>\n\(message.content)\n"
            case "user": prompt += "<|user|>\n\(message.content)\n"
            case "assistant": prompt += "<|assistant|>\n\(message.content)\n"
            case "tool": prompt += "<|tool|>\n\(message.content)\n"
            default: prompt += "\(message.content)\n"
            }
        }
        prompt += "<|assistant|>\n"
        return prompt
    }
}

enum LocalModelError: Error, LocalizedError {
    case modelNotFound, modelFileMissing, modelLoadFailed, inferenceFailed, contextTooLong
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Model not found"
        case .modelFileMissing: return "Model file missing"
        case .modelLoadFailed: return "Failed to load llama.cpp context"
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
