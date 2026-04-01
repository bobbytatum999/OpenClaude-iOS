import Foundation

@MainActor
class SearchUtilities {
    private static let _shared = SearchUtilities()
    static var shared: SearchUtilities { _shared }
    func regexSearch(pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }
    func findOccurrences(of pattern: String, in text: String) -> [(line: Int, column: Int, match: String)] {
        var results: [(Int, Int, String)] = []
        guard let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: [.caseInsensitive]) else { return results }
        let lines = text.components(separatedBy: .newlines)
        for (lineIndex, line) in lines.enumerated() {
            let matches = regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
            for match in matches {
                if let range = Range(match.range, in: line) {
                    results.append((lineIndex + 1, line.distance(from: line.startIndex, to: range.lowerBound) + 1, String(line[range])))
                }
            }
        }
        return results
    }
    func replace(pattern: String, with replacement: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}

struct CodeSearch: Sendable {
    let pattern: String
    let path: String
    let fileTypes: [String]
    func execute() async throws -> [SearchResult] {
        let fileManager = FileManager.default
        let baseURL = URL(fileURLWithPath: path)
        var results: [SearchResult] = []
        guard let enumerator = fileManager.enumerator(at: baseURL, includingPropertiesForKeys: [.isRegularFileKey]) else { return results }
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        for case let fileURL as URL in enumerator {
            guard !fileURL.hasDirectoryPath else { continue }
            if !fileTypes.isEmpty {
                guard fileTypes.contains(fileURL.pathExtension) else { continue }
            }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let matches = regex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let textRange = Range(match.range, in: content) {
                    let beforeMatch = content[content.startIndex..<textRange.lowerBound]
                    let lineNumber = beforeMatch.components(separatedBy: .newlines).count
                    let lines = content.components(separatedBy: .newlines)
                    let contextLine = lineNumber > 0 && lineNumber <= lines.count ? lines[lineNumber - 1] : ""
                    results.append(SearchResult(file: fileURL.path, line: lineNumber, column: 1, match: String(content[textRange]), context: contextLine.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return results
    }
}

struct SearchResult: Identifiable, Sendable {
    let id = UUID()
    let file: String
    let line: Int
    let column: Int
    let match: String
    let context: String
    var displayPath: String { URL(fileURLWithPath: file).lastPathComponent }
}
