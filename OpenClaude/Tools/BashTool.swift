import Foundation

extension BashToolImpl {
    func sanitizeCommand(_ command: String) -> String {
        var sanitized = command.replacingOccurrences(of: "\0", with: "")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }

    func isDangerousCommand(_ command: String) -> Bool {
        let dangerousPatterns = ["rm -rf /", "rm -rf /*", "mkfs", "dd if=/dev/zero", "dd if=/dev/random", ":(){ :|:& };:", "> /dev/sda", "mv / /dev/null"]
        let lowerCommand = command.lowercased()
        return dangerousPatterns.contains { lowerCommand.contains($0) }
    }
}
