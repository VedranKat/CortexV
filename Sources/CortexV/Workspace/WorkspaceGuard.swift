import Darwin
import Foundation

enum WorkspaceError: LocalizedError {
    case readNotAllowed(String)
    case writeNotAllowed(String)
    case escapesRoot
    case blockedByRules

    var errorDescription: String? {
        switch self {
        case .readNotAllowed(let name): "Workspace '\(name)' is not allowed to read files."
        case .writeNotAllowed(let name): "Workspace '\(name)' is not allowed to write files."
        case .escapesRoot: "Requested path escapes the workspace root."
        case .blockedByRules: "Requested path is blocked by the workspace include/exclude rules."
        }
    }
}

struct WorkspaceGuard {
    func workspaceRoot(_ workspace: Workspace) -> URL {
        URL(fileURLWithPath: workspace.rootPath).standardizedFileURL
    }

    func resolveReadablePath(workspace: Workspace, relativePath: String?) throws -> URL {
        guard workspace.allowRead else { throw WorkspaceError.readNotAllowed(workspace.name) }
        return try resolveAllowedPath(workspace: workspace, relativePath: relativePath)
    }

    func resolveWritablePath(workspace: Workspace, relativePath: String?) throws -> URL {
        guard workspace.allowWrite else { throw WorkspaceError.writeNotAllowed(workspace.name) }
        return try resolveAllowedPath(workspace: workspace, relativePath: relativePath)
    }

    func isReadablePath(workspace: Workspace, url: URL) -> Bool {
        guard workspace.allowRead else { return false }
        let root = workspaceRoot(workspace)
        let candidate = url.standardizedFileURL
        return candidate.path.hasPrefix(root.path) && isPathAllowed(workspace: workspace, root: root, candidate: candidate)
    }

    private func resolveAllowedPath(workspace: Workspace, relativePath: String?) throws -> URL {
        let root = workspaceRoot(workspace)
        let trimmed = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = trimmed.isEmpty ? root : root.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.escapesRoot
        }
        guard isPathAllowed(workspace: workspace, root: root, candidate: candidate) else {
            throw WorkspaceError.blockedByRules
        }
        return candidate
    }

    private func isPathAllowed(workspace: Workspace, root: URL, candidate: URL) -> Bool {
        if candidate.path == root.path {
            return true
        }
        let relative = relativePath(root: root, candidate: candidate)
        guard !isGeneratedDiagnosticsPath(relative) else {
            return false
        }
        let includes = patterns(workspace.includePatterns)
        let excludes = patterns(workspace.excludePatterns)
        let included = includes.isEmpty || includes.contains { globMatches(pattern: $0, relative: relative) }
        return included && !excludes.contains { globMatches(pattern: $0, relative: relative) }
    }

    private func isGeneratedDiagnosticsPath(_ relative: String) -> Bool {
        relative == "cortexv-diagnostics" || relative.hasPrefix("cortexv-diagnostics/")
    }

    private func relativePath(root: URL, candidate: URL) -> String {
        var value = candidate.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        return value.replacingOccurrences(of: "\\", with: "/")
    }

    private func patterns(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",\r\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/") }
            .filter { !$0.isEmpty }
    }

    private func globMatches(pattern: String, relative: String) -> Bool {
        let candidates = pattern.hasPrefix("**/") ? [pattern, String(pattern.dropFirst(3))] : [pattern]
        return candidates.contains { candidate in
            fnmatch(candidate, relative, 0) == 0
        }
    }
}
