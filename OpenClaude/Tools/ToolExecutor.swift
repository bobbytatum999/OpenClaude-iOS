import Foundation

protocol Tool {
    var name: String { get }
    var description: String { get }
    func execute(arguments: [String: Any]) async throws -> String
}

@MainActor
class ToolExecutor: ObservableObject {
    static let shared = ToolExecutor()
    @Published var lastExecution: ToolExecution?
    @Published var executionHistory: [ToolExecution] = []
    private var tools: [String: Tool] = [:]

    struct ToolExecution: Identifiable {
        let id = UUID()
        let toolName: String
        let arguments: [String: Any]
        let result: String
        let timestamp: Date
        let duration: TimeInterval
        let isError: Bool
    }

    private init() {
        register(BashToolImpl())
        register(FileReadTool())
        register(FileWriteTool())
        register(FileEditTool())
        register(GrepToolImpl())
        register(GlobTool())
        register(WebFetchTool())
        register(WebSearchTool())
    }

    func register(_ tool: Tool) { tools[tool.name] = tool }

    func execute(toolCall: Message.ToolCall) async -> Message.ToolResult {
        let startTime = Date()
        guard let tool = tools[toolCall.name] else {
            let result = Message.ToolResult(toolCallId: toolCall.id, output: "Error: Tool '\(toolCall.name)' not found", isError: true)
            logExecution(name: toolCall.name, arguments: [:], result: result.output, startTime: startTime, isError: true)
            return result
        }
        guard let argumentsData = toolCall.arguments.data(using: .utf8), let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            let result = Message.ToolResult(toolCallId: toolCall.id, output: "Error: Invalid arguments JSON", isError: true)
            logExecution(name: toolCall.name, arguments: [:], result: result.output, startTime: startTime, isError: true)
            return result
        }
        do {
            let output = try await tool.execute(arguments: arguments)
            let result = Message.ToolResult(toolCallId: toolCall.id, output: output, isError: false)
            logExecution(name: toolCall.name, arguments: arguments, result: output, startTime: startTime, isError: false)
            return result
        } catch {
            let result = Message.ToolResult(toolCallId: toolCall.id, output: "Error: \(error.localizedDescription)", isError: true)
            logExecution(name: toolCall.name, arguments: arguments, result: result.output, startTime: startTime, isError: true)
            return result
        }
    }

    private func logExecution(name: String, arguments: [String: Any], result: String, startTime: Date, isError: Bool) {
        let execution = ToolExecution(toolName: name, arguments: arguments, result: result, timestamp: startTime, duration: Date().timeIntervalSince(startTime), isError: isError)
        lastExecution = execution
        executionHistory.append(execution)
        if executionHistory.count > 100 { executionHistory.removeFirst(executionHistory.count - 100) }
    }

    func getToolDefinitions() -> [ToolDefinition] {
        return ToolDefinition.allTools
    }
}

struct BashToolImpl: Tool {
    let name = "bash"
    let description = "Execute bash commands"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else { throw ToolError.missingParameter("command") }
        let blockedCommands = ["rm -rf /", "mkfs", "dd if=/dev/zero", ":(){ :|:& };:"]
        for blocked in blockedCommands { if command.contains(blocked) { throw ToolError.blockedCommand } }
        return "Error: Bash tool is only available on macOS/Desktop"
    }
}

struct FileReadTool: Tool {
    let name = "file_read"
    let description = "Read file contents"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else { throw ToolError.missingParameter("path") }
        let offset = arguments["offset"] as? Int ?? 0
        let limit = arguments["limit"] as? Int ?? 100
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { throw ToolError.fileNotFound }
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let startIndex = min(offset, lines.count)
        let endIndex = min(startIndex + limit, lines.count)
        let selectedLines = Array(lines[startIndex..<endIndex])
        var result: String
        if offset > 0 || lines.count > limit {
            let numberedLines = selectedLines.enumerated().map { "\(startIndex + $0 + 1): \($1)" }
            result = numberedLines.joined(separator: "\n")
        } else {
            result = selectedLines.joined(separator: "\n")
        }
        if lines.count > limit { result += "\n\n... (\(lines.count - endIndex) more lines)" }
        return result
    }
}

struct FileWriteTool: Tool {
    let name = "file_write"
    let description = "Write to file"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String, let content = arguments["content"] as? String else { throw ToolError.missingParameter("path or content") }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Successfully wrote \(content.count) characters to \(path)"
    }
}

struct FileEditTool: Tool {
    let name = "file_edit"
    let description = "Edit file by replacing text"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String, let oldString = arguments["old_string"] as? String, let newString = arguments["new_string"] as? String else { throw ToolError.missingParameter("path, old_string, or new_string") }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { throw ToolError.fileNotFound }
        var content = try String(contentsOf: url, encoding: .utf8)
        guard content.contains(oldString) else { throw ToolError.stringNotFound }
        content = content.replacingOccurrences(of: oldString, with: newString)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Successfully edited \(path)"
    }
}

struct GrepToolImpl: Tool {
    let name = "grep"
    let description = "Search files with regex"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let pattern = arguments["pattern"] as? String, let path = arguments["path"] as? String else { throw ToolError.missingParameter("pattern or path") }
        let include = arguments["include"] as? String
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        var results: [String] = []

        if fileManager.fileExists(atPath: path) {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                results = try searchDirectory(at: url, pattern: pattern, include: include)
            } else {
                if let result = try searchFile(at: url, pattern: pattern) { results = [result] }
            }
        }
        return results.isEmpty ? "No matches found" : results.joined(separator: "\n\n")
    }

    private func searchDirectory(at url: URL, pattern: String, include: String?) throws -> [String] {
        let fileManager = FileManager.default
        var results: [String] = []
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil)
        let regexPattern = include?.replacingOccurrences(of: "*", with: ".*") ?? ".*"
        let regex = try NSRegularExpression(pattern: regexPattern, options: [])

        while let fileURL = enumerator?.nextObject() as? URL {
            guard !fileURL.hasDirectoryPath else { continue }
            if include != nil {
                let range = NSRange(fileURL.lastPathComponent.startIndex..., in: fileURL.lastPathComponent)
                if regex.firstMatch(in: fileURL.lastPathComponent, options: [], range: range) == nil { continue }
            }
            if let result = try searchFile(at: fileURL, pattern: pattern) { results.append(result) }
        }
        return results
    }

    private func searchFile(at url: URL, pattern: String) throws -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        guard !matches.isEmpty else { return nil }
        var resultLines: [String] = []
        let lines = content.components(separatedBy: .newlines)
        for match in matches.prefix(10) {
            let nsRange = match.range
            if let swiftRange = Range(nsRange, in: content) {
                let beforeMatch = content[content.startIndex..<swiftRange.lowerBound]
                let lineNumber = beforeMatch.components(separatedBy: .newlines).count
                if lineNumber > 0 && lineNumber <= lines.count {
                    resultLines.append("\(lineNumber): \(lines[lineNumber - 1].trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return resultLines.isEmpty ? nil : "\(url.path):\n" + resultLines.joined(separator: "\n")
    }
}

struct GlobTool: Tool {
    let name = "glob"
    let description = "Find files by pattern"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let pattern = arguments["pattern"] as? String else { throw ToolError.missingParameter("pattern") }
        let path = arguments["path"] as? String ?? "."
        let baseURL = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        var matches: [String] = []
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**", with: "<<<DS>>>")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "<<<DS>>>", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
        let regex = try NSRegularExpression(pattern: regexPattern, options: [])
        let enumerator = fileManager.enumerator(at: baseURL, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = fileURL.path.replacingOccurrences(of: baseURL.path + "/", with: "")
            let range = NSRange(relativePath.startIndex..., in: relativePath)
            if regex.firstMatch(in: relativePath, options: [], range: range) != nil { matches.append(relativePath) }
        }
        return matches.isEmpty ? "No files matching pattern" : matches.sorted().joined(separator: "\n")
    }
}

struct WebFetchTool: Tool {
    let name = "web_fetch"
    let description = "Fetch URL content"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let urlString = arguments["url"] as? String, let url = URL(string: urlString) else { throw ToolError.missingParameter("url") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw ToolError.networkError }
        guard let html = String(data: data, encoding: .utf8) else { return "Failed to decode content" }
        return extractText(from: html)
    }

    private func extractText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.count > 10000 ? String(text.prefix(10000)) + "\n\n... (truncated)" : text
    }
}

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web"
    func execute(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String else { throw ToolError.missingParameter("query") }
        let numResults = min(arguments["num_results"] as? Int ?? 5, 10)
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)")!
        var request = URLRequest(url: searchURL)
        request.setValue("Mozilla/5.0 (compatible; OpenClaude/1.0)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { throw ToolError.networkError }
        return parseSearchResults(html, numResults: numResults)
    }

    private func parseSearchResults(_ html: String, numResults: Int) -> String {
        var results: [String] = []
        let titlePattern = "<a[^>]*class=\"result__a\"[^>]*>([^<]+)</a>"
        let snippetPattern = "<a[^>]*class=\"result__snippet\"[^>]*>([^<]+)</a>"
        let titleRegex = try? NSRegularExpression(pattern: titlePattern, options: [.caseInsensitive])
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive])
        let titles = titleRegex?.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html)) ?? []
        let snippets = snippetRegex?.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html)) ?? []

        for i in 0..<min(numResults, titles.count) {
            let titleRange = titles[i].range(at: 1)
            let snippetRange = i < snippets.count ? snippets[i].range(at: 1) : nil
            if let title = Range(titleRange, in: html) {
                var result = "\(i + 1). \(String(html[title]).trimmingCharacters(in: .whitespaces))"
                if let snippetRange = snippetRange, let snippet = Range(snippetRange, in: html) {
                    result += "\n   \(String(html[snippet]).trimmingCharacters(in: .whitespaces))"
                }
                results.append(result)
            }
        }
        return results.isEmpty ? "No search results found" : results.joined(separator: "\n\n")
    }
}

enum ToolError: Error, LocalizedError {
    case missingParameter(String), blockedCommand, timeout, accessDenied, fileNotFound, stringNotFound, networkError, toolNotFound
    var errorDescription: String? {
        switch self {
        case .missingParameter(let p): return "Missing parameter: \(p)"
        case .blockedCommand: return "Command blocked for security"
        case .timeout: return "Command timed out"
        case .accessDenied: return "Access denied"
        case .fileNotFound: return "File not found"
        case .stringNotFound: return "String not found in file"
        case .networkError: return "Network error"
        case .toolNotFound: return "Tool not found"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { return indices.contains(index) ? self[index] : nil }
}
