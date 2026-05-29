import Darwin
import Foundation

struct FileSystemService {
    private let listLimit = 200
    private let globLimit = 200
    private let matchLimit = 120
    private let maxReadBytes: UInt64 = 512_000
    private let maxRangeSourceBytes: UInt64 = 2_000_000
    private let maxContentCharacters = 24_000
    private let defaultRangeLineCount = 160
    private let maxRangeLineCount = 300
    private let guardService: WorkspaceGuard

    init(guardService: WorkspaceGuard = WorkspaceGuard()) {
        self.guardService = guardService
    }

    func listFiles(workspace: Workspace, relativeDirectory: String?) throws -> String {
        let target = try guardService.resolveReadablePath(workspace: workspace, relativePath: relativeDirectory)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolExecutionError.message("Path does not exist inside workspace: \(relativeDirectory ?? "")")
        }
        let root = guardService.workspaceRoot(workspace)
        var output = """
        Workspace: \(workspace.name)
        Root: \(root.path)
        Listing: \(displayPath(root: root, url: target))

        """

        let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isDirectoryKey])
        let paths = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { guardService.isReadablePath(workspace: workspace, url: $0) }
            .sorted { $0.path < $1.path }

        if paths.isEmpty {
            return output + "No readable files or folders matched this workspace scope."
        }

        for (index, url) in paths.prefix(listLimit).enumerated() {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            output += "\(isDirectory ? "[dir]" : "[file]") \(displayPath(root: root, url: url))\n"
            if index == listLimit - 1, paths.count > listLimit {
                output += "... truncated after \(listLimit) entries"
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readFile(workspace: Workspace, relativePath: String) throws -> String {
        let file = try guardService.resolveReadablePath(workspace: workspace, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolExecutionError.message("Readable file not found: \(relativePath)")
        }
        let content = try readString(file: file, relativePath: relativePath)
        let trimmed = content.count > maxContentCharacters
            ? String(content.prefix(maxContentCharacters)) + "\n... truncated ..."
            : content
        return "File: \(displayPath(root: guardService.workspaceRoot(workspace), url: file))\n\n\(trimmed)"
    }

    func readFileRange(workspace: Workspace, relativePath: String, startLine: Int?, lineCount: Int?) throws -> String {
        let normalizedStart = startLine ?? 1
        let normalizedCount = lineCount ?? defaultRangeLineCount
        guard normalizedStart >= 1 else {
            throw ToolExecutionError.message("startLine must be 1 or greater.")
        }
        guard normalizedCount >= 1, normalizedCount <= maxRangeLineCount else {
            throw ToolExecutionError.message("lineCount must be between 1 and \(maxRangeLineCount).")
        }

        let file = try guardService.resolveReadablePath(workspace: workspace, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolExecutionError.message("Readable file not found: \(relativePath)")
        }

        let content = try readRangeString(file: file, relativePath: relativePath)
        let lines = normalizedLines(content)
        guard normalizedStart <= max(lines.count, 1) else {
            throw ToolExecutionError.message("startLine \(normalizedStart) is beyond the end of '\(relativePath)' (\(lines.count) line\(lines.count == 1 ? "" : "s")).")
        }

        let startIndex = normalizedStart - 1
        let endIndex = min(lines.count, startIndex + normalizedCount)
        let selected = lines[startIndex..<endIndex]
        let body = selected.enumerated().map { offset, line in
            "\(normalizedStart + offset): \(line)"
        }.joined(separator: "\n")
        let displayedPath = displayPath(root: guardService.workspaceRoot(workspace), url: file)
        return """
        File: \(displayedPath)
        Lines: \(normalizedStart)-\(endIndex) of \(lines.count)

        \(body)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readFileIfExists(workspace: Workspace, relativePath: String) throws -> String? {
        let file = try guardService.resolveWritablePath(workspace: workspace, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolExecutionError.message("Writable target is not a file: \(relativePath)")
        }
        return try readString(file: file, relativePath: relativePath)
    }

    func writeFile(workspace: Workspace, relativePath: String, content: String) throws {
        let file = try guardService.resolveWritablePath(workspace: workspace, relativePath: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func restoreFile(workspace: Workspace, relativePath: String, content: String?) throws {
        if let content {
            try writeFile(workspace: workspace, relativePath: relativePath, content: content)
            return
        }

        let file = try guardService.resolveWritablePath(workspace: workspace, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    func searchInFiles(workspace: Workspace, query: String, relativeDirectory: String?) throws -> String {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { throw ToolExecutionError.message("Search text is required.") }
        let target = try guardService.resolveReadablePath(workspace: workspace, relativePath: relativeDirectory)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolExecutionError.message("Search path does not exist inside workspace: \(relativeDirectory ?? "")")
        }

        let root = guardService.workspaceRoot(workspace)
        let lowercaseQuery = normalizedQuery.lowercased()
        var output = "Search: \(normalizedQuery)\nWorkspace: \(workspace.name)\n\n"
        var matches = 0
        var skippedUnreadable = 0
        let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        let files = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { guardService.isReadablePath(workspace: workspace, url: $0) }
            .sorted { $0.path < $1.path }

        for file in files where matches < matchLimit {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if UInt64(values?.fileSize ?? 0) > maxReadBytes {
                continue
            }
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                skippedUnreadable += 1
                continue
            }
            let lines = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where matches < matchLimit {
                if line.lowercased().contains(lowercaseQuery) {
                    output += "\(displayPath(root: root, url: file)):\(index + 1): \(line.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    matches += 1
                }
            }
        }

        if matches >= matchLimit {
            output += "... truncated after \(matchLimit) matches"
        } else if matches == 0 {
            output += "No matches found."
        }
        if skippedUnreadable > 0 {
            output += "\n\nSkipped \(skippedUnreadable) non-text or unreadable file\(skippedUnreadable == 1 ? "." : "s.")"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func globFiles(workspace: Workspace, pattern: String, relativeDirectory: String?) throws -> String {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty else { throw ToolExecutionError.message("Glob pattern is required.") }
        let target = try guardService.resolveReadablePath(workspace: workspace, relativePath: relativeDirectory)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolExecutionError.message("Glob path does not exist inside workspace: \(relativeDirectory ?? "")")
        }

        let root = guardService.workspaceRoot(workspace)
        let files = try readableFiles(workspace: workspace, target: target)
            .filter { globOrSubstringMatches(pattern: normalizedPattern, relative: displayPath(root: root, url: $0)) }
            .sorted { lhs, rhs in
                displayPath(root: root, url: lhs).localizedCaseInsensitiveCompare(displayPath(root: root, url: rhs)) == .orderedAscending
            }

        var output = """
        Glob: \(normalizedPattern)
        Workspace: \(workspace.name)

        """

        if files.isEmpty {
            return output + "No readable files matched."
        }

        for (index, file) in files.prefix(globLimit).enumerated() {
            output += "\(displayPath(root: root, url: file))\n"
            if index == globLimit - 1, files.count > globLimit {
                output += "... truncated after \(globLimit) files"
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func grepFiles(
        workspace: Workspace,
        pattern: String,
        relativePath: String?,
        includePattern: String?,
        caseSensitive: Bool
    ) throws -> String {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty else { throw ToolExecutionError.message("Grep pattern is required.") }
        let target = try guardService.resolveReadablePath(workspace: workspace, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolExecutionError.message("Grep path does not exist inside workspace: \(relativePath ?? "")")
        }

        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: normalizedPattern, options: options)
        } catch {
            throw ToolExecutionError.message("Invalid grep regex pattern: \(error.localizedDescription)")
        }

        let root = guardService.workspaceRoot(workspace)
        let normalizedInclude = includePattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let files = try readableFiles(workspace: workspace, target: target)
            .filter { file in
                normalizedInclude.isEmpty || globMatches(pattern: normalizedInclude, relative: displayPath(root: root, url: file))
            }
            .sorted { lhs, rhs in
                displayPath(root: root, url: lhs).localizedCaseInsensitiveCompare(displayPath(root: root, url: rhs)) == .orderedAscending
            }

        var output = """
        Grep: \(normalizedPattern)
        Workspace: \(workspace.name)

        """
        var matches = 0
        var skippedUnreadable = 0

        for file in files where matches < matchLimit {
            guard let content = try? readSearchableString(file: file) else {
                skippedUnreadable += 1
                continue
            }
            let lines = normalizedLines(content)
            for (index, line) in lines.enumerated() where matches < matchLimit {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if expression.firstMatch(in: line, options: [], range: range) != nil {
                    output += "\(displayPath(root: root, url: file)):\(index + 1): \(line.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    matches += 1
                }
            }
        }

        if matches >= matchLimit {
            output += "... truncated after \(matchLimit) matches"
        } else if matches == 0 {
            output += "No matches found."
        }
        if skippedUnreadable > 0 {
            output += "\n\nSkipped \(skippedUnreadable) non-text, oversized, or unreadable file\(skippedUnreadable == 1 ? "." : "s.")"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readString(file: URL, relativePath: String) throws -> String {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        if UInt64(values.fileSize ?? 0) > maxReadBytes {
            throw ToolExecutionError.message("File is too large to read in the MVP viewer (max 512 KB).")
        }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw ToolExecutionError.message("Failed to read file '\(relativePath)'.")
        }
    }

    private func readRangeString(file: URL, relativePath: String) throws -> String {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        if UInt64(values.fileSize ?? 0) > maxRangeSourceBytes {
            throw ToolExecutionError.message("File is too large for ranged reading in the MVP viewer (max 2 MB).")
        }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw ToolExecutionError.message("Failed to read file range from '\(relativePath)'.")
        }
    }

    private func readSearchableString(file: URL) throws -> String {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard UInt64(values.fileSize ?? 0) <= maxReadBytes else {
            throw ToolExecutionError.message("File is too large to search.")
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func readableFiles(workspace: Workspace, target: URL) throws -> [URL] {
        let values = try? target.resourceValues(forKeys: [.isRegularFileKey])
        if values?.isRegularFile == true {
            return guardService.isReadablePath(workspace: workspace, url: target) ? [target] : []
        }

        let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        return (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true && guardService.isReadablePath(workspace: workspace, url: url)
            }
    }

    private func normalizedLines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private func globOrSubstringMatches(pattern: String, relative: String) -> Bool {
        if containsGlobSyntax(pattern) {
            return globMatches(pattern: pattern, relative: relative)
        }
        return relative.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func globMatches(pattern: String, relative: String) -> Bool {
        let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
        let normalizedRelative = relative.replacingOccurrences(of: "\\", with: "/")
        let candidates = normalizedPattern.hasPrefix("**/") ? [normalizedPattern, String(normalizedPattern.dropFirst(3))] : [normalizedPattern]
        return candidates.contains { candidate in
            fnmatch(candidate, normalizedRelative, 0) == 0
        }
    }

    private func containsGlobSyntax(_ value: String) -> Bool {
        value.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]{}")) != nil
    }

    private func displayPath(root: URL, url: URL) -> String {
        if root.path == url.path {
            return "."
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }
}
