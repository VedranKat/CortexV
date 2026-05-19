import Foundation

struct DiffService {
    func generate(filePath: String, oldContent: String?, newContent: String?) -> String {
        let safePath = filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "file" : filePath
        let oldValue = oldContent ?? ""
        let newValue = newContent ?? ""
        if oldValue == newValue {
            return "No content changes."
        }

        let oldLines = splitLines(oldValue)
        let newLines = splitLines(newValue)
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let oldChangeEnd = oldLines.count - suffix
        let newChangeEnd = newLines.count - suffix
        let contextStart = max(0, prefix - 3)
        let oldContextEnd = min(oldLines.count, oldChangeEnd + 3)
        let newContextEnd = min(newLines.count, newChangeEnd + 3)

        var output = "--- \(safePath)\n+++ \(safePath)\n@@ around line \(prefix + 1) @@\n"
        for index in contextStart..<prefix {
            output += "  \(oldLines[index])\n"
        }
        for index in prefix..<oldChangeEnd {
            output += "- \(oldLines[index])\n"
        }
        for index in prefix..<newChangeEnd {
            output += "+ \(newLines[index])\n"
        }
        for index in oldChangeEnd..<oldContextEnd {
            output += "  \(oldLines[index])\n"
        }
        if newContextEnd > oldContextEnd {
            for index in oldContextEnd..<newContextEnd {
                output += "  \(newLines[index])\n"
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}
