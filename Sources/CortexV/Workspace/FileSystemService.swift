import Foundation

struct FileSystemService {
    private let listLimit = 200
    private let matchLimit = 120
    private let maxReadBytes: UInt64 = 512_000
    private let maxContentCharacters = 24_000
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

    private func displayPath(root: URL, url: URL) -> String {
        if root.path == url.path {
            return "."
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }
}
