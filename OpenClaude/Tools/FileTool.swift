import Foundation

@MainActor
class FileOperations {
    private static let _shared = FileOperations()
    static var shared: FileOperations { _shared }
    private let fileManager = FileManager.default
    private init() {}
    
    var documentsDirectory: URL { fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var temporaryDirectory: URL { fileManager.temporaryDirectory }
    
    func fileExists(at path: String) -> Bool { fileManager.fileExists(atPath: path) }
    func createDirectory(at path: String) throws {
        try fileManager.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    }
    func listDirectory(at path: String) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: URL(fileURLWithPath: path).path)
    }
    func fileInfo(at path: String) -> [FileAttributeKey: Any]? {
        try? fileManager.attributesOfItem(atPath: path)
    }
    func copyFile(from source: String, to destination: String) throws {
        try fileManager.copyItem(at: URL(fileURLWithPath: source), to: URL(fileURLWithPath: destination))
    }
    func moveFile(from source: String, to destination: String) throws {
        try fileManager.moveItem(at: URL(fileURLWithPath: source), to: URL(fileURLWithPath: destination))
    }
    func deleteFile(at path: String) throws {
        try fileManager.removeItem(atPath: path)
    }
    func fileSize(at path: String) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64
    }
    func formatFileSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct FileDiff {
    let oldLines: [String]
    let newLines: [String]
    let changes: [Change]
    enum Change {
        case added(line: String, at: Int)
        case removed(line: String, from: Int)
        case modified(oldLine: String, newLine: String, at: Int)
    }
    static func compute(old: String, new: String) -> FileDiff {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        var changes: [Change] = []
        let maxLines = max(oldLines.count, newLines.count)
        for i in 0..<maxLines {
            let oldLine = i < oldLines.count ? oldLines[i] : nil
            let newLine = i < newLines.count ? newLines[i] : nil
            if let old = oldLine, let new = newLine {
                if old != new { changes.append(.modified(oldLine: old, newLine: new, at: i + 1)) }
            } else if let new = newLine { changes.append(.added(line: new, at: i + 1)) }
            else if let old = oldLine { changes.append(.removed(line: old, from: i + 1)) }
        }
        return FileDiff(oldLines: oldLines, newLines: newLines, changes: changes)
    }
    func format() -> String {
        var result = ["--- old", "+++ new", ""]
        for change in changes {
            switch change {
            case .added(let line, let at): result.append("+ \(at): \(line)")
            case .removed(let line, let from): result.append("- \(from): \(line)")
            case .modified(let oldLine, let newLine, let at): result.append("- \(at): \(oldLine)"); result.append("+ \(at): \(newLine)")
            }
        }
        return result.joined(separator: "\n")
    }
}
