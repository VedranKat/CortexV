import Foundation

enum ToolExecutionError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}

struct ToolExecutionService {
    let persistence: PersistenceContainer
    let fileSystemService: FileSystemService
    let changeReviewService: ChangeReviewService

    func availableToolsForSession(_ sessionID: Int64, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> [ToolDefinition] {
        let readable = try readableWorkspacesForSession(sessionID, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        let writable = try writableWorkspacesForSession(sessionID, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        var tools: [ToolDefinition] = []

        if !readable.isEmpty {
            let help = workspaceSummary(label: "Readable", workspaces: readable)
            tools.append(ToolDefinition(
                name: "list_files",
                description: "List readable files and folders in a workspace so you can choose what to inspect next. \(help)",
                inputSchema: schema(required: [], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "path": ["type": "string", "description": "Optional directory path inside the workspace. Leave empty for the workspace root."]
                ])
            ))
            tools.append(ToolDefinition(
                name: "glob_files",
                description: "Find readable files by glob pattern or path substring using a fresh filesystem scan. Use this to discover candidate files before reading. \(help)",
                inputSchema: schema(required: ["pattern"], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "pattern": ["type": "string", "description": "Glob pattern such as **/*.swift, *Service*, or a path substring such as ChatService."],
                    "path": ["type": "string", "description": "Optional directory path inside the workspace. Leave empty for the workspace root."]
                ])
            ))
            tools.append(ToolDefinition(
                name: "grep_files",
                description: "Search current readable UTF-8 files for a regex pattern and return file paths with line numbers. Use this for exact symbols, strings, and narrow code discovery. \(help)",
                inputSchema: schema(required: ["pattern"], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "pattern": ["type": "string", "description": "Regular expression to search for, for example delegate_to_child_agent or struct\\s+Agent."],
                    "path": ["type": "string", "description": "Optional file or directory path inside the workspace. Leave empty for the workspace root."],
                    "include": ["type": "string", "description": "Optional file glob to narrow searched files, for example **/*.swift."],
                    "caseSensitive": ["type": "boolean", "description": "Optional. Defaults to false."]
                ])
            ))
            tools.append(ToolDefinition(
                name: "read_file_range",
                description: "Read a fresh line range from one UTF-8 text file. Prefer this over read_file when grep_files or prior context identified relevant lines. \(help)",
                inputSchema: schema(required: ["path"], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "path": ["type": "string", "description": "File path inside the workspace, for example Sources/App.swift"],
                    "startLine": ["type": "integer", "description": "Optional 1-based first line. Defaults to 1."],
                    "lineCount": ["type": "integer", "description": "Optional number of lines to read. Defaults to 160 and is capped."]
                ])
            ))
            tools.append(ToolDefinition(
                name: "read_file",
                description: "Read one full UTF-8 text file from a readable workspace. Use this for small files or when full-file context is necessary; prefer read_file_range for known line areas. \(help)",
                inputSchema: schema(required: ["path"], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "path": ["type": "string", "description": "File path inside the workspace, for example Package.swift or Sources/App.swift"]
                ])
            ))
            tools.append(ToolDefinition(
                name: "search_in_files",
                description: "Search readable UTF-8 files in a workspace for a case-insensitive literal query. Prefer grep_files when you need line-numbered regex search or include filters. \(help)",
                inputSchema: schema(required: ["query"], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "query": ["type": "string", "description": "Text to search for."],
                    "path": ["type": "string", "description": "Optional directory path inside the workspace. Leave empty for the workspace root."]
                ])
            ))
        }

        if !writable.isEmpty {
            let help = workspaceSummary(label: "Writable", workspaces: writable)
            tools.append(ToolDefinition(
                name: "propose_file_write",
                description: "Create a reviewable file-edit proposal inside a writable workspace. Use this after you already have enough context. Pass the full replacement file content. This does not write to disk until the user approves it. \(help)",
                inputSchema: schema(required: ["path", "newContent"], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "path": ["type": "string", "description": "File path inside the workspace that should be created or updated."],
                    "newContent": ["type": "string", "description": "The full replacement content for the file."]
                ])
            ))
        }

        return tools
    }

    func executeToolCall(sessionID: Int64, toolCall: ToolCallRequest, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) -> String {
        do {
            let args = try parseArguments(toolCall.argumentsJSON)
            let workspaceID = optionalInt(args["workspaceId"])
            switch toolCall.name {
            case "list_files":
                return try listFiles(sessionID: sessionID, workspaceID: workspaceID, path: optionalText(args["path"]), limitingToWorkspaceIDs: allowedWorkspaceIDs)
            case "glob_files":
                return try globFiles(sessionID: sessionID, workspaceID: workspaceID, pattern: requiredText(args["pattern"], name: "pattern"), path: optionalText(args["path"]), limitingToWorkspaceIDs: allowedWorkspaceIDs)
            case "grep_files":
                return try grepFiles(sessionID: sessionID, workspaceID: workspaceID, pattern: requiredText(args["pattern"], name: "pattern"), path: optionalText(args["path"]), include: optionalText(args["include"]), caseSensitive: optionalBool(args["caseSensitive"]), limitingToWorkspaceIDs: allowedWorkspaceIDs)
            case "read_file_range":
                return try readFileRange(sessionID: sessionID, workspaceID: workspaceID, path: requiredText(args["path"], name: "path"), startLine: optionalInt(args["startLine"]), lineCount: optionalInt(args["lineCount"]), limitingToWorkspaceIDs: allowedWorkspaceIDs)
            case "read_file":
                return try readFile(sessionID: sessionID, workspaceID: workspaceID, path: requiredText(args["path"], name: "path"), limitingToWorkspaceIDs: allowedWorkspaceIDs)
            case "search_in_files":
                return try searchInFiles(sessionID: sessionID, workspaceID: workspaceID, query: requiredText(args["query"], name: "query"), path: optionalText(args["path"]), limitingToWorkspaceIDs: allowedWorkspaceIDs)
            case "propose_file_write":
                return try proposeFileWrite(sessionID: sessionID, workspaceID: workspaceID, path: requiredText(args["path"], name: "path"), newContent: requiredRawText(args["newContent"], name: "newContent"), limitingToWorkspaceIDs: allowedWorkspaceIDs)
            default:
                return "Tool error: Unknown tool '\(toolCall.name)'."
            }
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    func listFiles(sessionID: Int64, workspaceID: Int64?, path: String?, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        return try fileSystemService.listFiles(workspace: workspace, relativeDirectory: path)
    }

    func readFile(sessionID: Int64, workspaceID: Int64?, path: String, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        return try fileSystemService.readFile(workspace: workspace, relativePath: path)
    }

    func readFileRange(sessionID: Int64, workspaceID: Int64?, path: String, startLine: Int64?, lineCount: Int64?, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        return try fileSystemService.readFileRange(
            workspace: workspace,
            relativePath: path,
            startLine: startLine.map(Int.init),
            lineCount: lineCount.map(Int.init)
        )
    }

    func searchInFiles(sessionID: Int64, workspaceID: Int64?, query: String, path: String?, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        return try fileSystemService.searchInFiles(workspace: workspace, query: query, relativeDirectory: path)
    }

    func globFiles(sessionID: Int64, workspaceID: Int64?, pattern: String, path: String?, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        return try fileSystemService.globFiles(workspace: workspace, pattern: pattern, relativeDirectory: path)
    }

    func grepFiles(sessionID: Int64, workspaceID: Int64?, pattern: String, path: String?, include: String?, caseSensitive: Bool, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        return try fileSystemService.grepFiles(
            workspace: workspace,
            pattern: pattern,
            relativePath: path,
            includePattern: include,
            caseSensitive: caseSensitive
        )
    }

    func proposeFileWrite(sessionID: Int64, workspaceID: Int64?, path: String, newContent: String, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: true, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        let fileChange = try changeReviewService.proposeFileWrite(sessionID: sessionID, workspaceID: workspace.id, relativePath: path, newContent: newContent)
        return "Created change proposal #\(fileChange.id) for '\(fileChange.filePath)'. Review it in the Changes view before anything is written to disk."
    }

    private func readableWorkspacesForSession(_ sessionID: Int64, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> [Workspace] {
        try scopedWorkspacesForSession(sessionID, limitingToWorkspaceIDs: allowedWorkspaceIDs).filter(\.allowRead).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func writableWorkspacesForSession(_ sessionID: Int64, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> [Workspace] {
        try scopedWorkspacesForSession(sessionID, limitingToWorkspaceIDs: allowedWorkspaceIDs).filter(\.allowWrite).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scopedWorkspacesForSession(_ sessionID: Int64, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>?) throws -> [Workspace] {
        let workspaces = try boundWorkspacesForSession(sessionID)
        guard let allowedWorkspaceIDs else { return workspaces }
        return workspaces.filter { allowedWorkspaceIDs.contains($0.id) }
    }

    private func boundWorkspacesForSession(_ sessionID: Int64) throws -> [Workspace] {
        let session = try persistence.sessions.find(id: sessionID)
        let ids = try persistence.agents.findWorkspaceIDs(agentID: session.agentID)
        return try ids.map { try persistence.workspaces.find(id: $0) }
    }

    private func resolveWorkspace(sessionID: Int64, requestedWorkspaceID: Int64?, requireWrite: Bool, limitingToWorkspaceIDs allowedWorkspaceIDs: Set<Int64>? = nil) throws -> Workspace {
        let workspaces = try requireWrite ? writableWorkspacesForSession(sessionID, limitingToWorkspaceIDs: allowedWorkspaceIDs) : readableWorkspacesForSession(sessionID, limitingToWorkspaceIDs: allowedWorkspaceIDs)
        guard !workspaces.isEmpty else {
            throw ToolExecutionError.message("No \(requireWrite ? "writable" : "readable") workspaces are bound to this session's agent.")
        }
        let session = try persistence.sessions.find(id: sessionID)
        let targetID = requestedWorkspaceID ?? session.workspaceID
        guard let targetID else { return workspaces[0] }
        guard let workspace = workspaces.first(where: { $0.id == targetID }) else {
            throw ToolExecutionError.message("The selected workspace is not bound to this session's agent or does not allow \(requireWrite ? "writes" : "reads").")
        }
        return workspace
    }

    private func parseArguments(_ json: String) throws -> [String: Any] {
        let normalized = json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : json
        let data = Data(normalized.utf8)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func optionalText(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func requiredText(_ value: Any?, name: String) throws -> String {
        let text = optionalText(value)
        guard !text.isEmpty else { throw ToolExecutionError.message("Missing required argument '\(name)'.") }
        return text
    }

    private func requiredRawText(_ value: Any?, name: String) throws -> String {
        guard let value else { throw ToolExecutionError.message("Missing required argument '\(name)'.") }
        return String(describing: value)
    }

    private func optionalInt(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func optionalBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            default:
                return false
            }
        }
        return false
    }

    private func schema(required: [String], properties: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty {
            result["required"] = required
        }
        return result
    }

    private func workspaceSummary(label: String, workspaces: [Workspace]) -> String {
        let entries = workspaces.map { "\($0.id)=\($0.name)" }.joined(separator: "; ")
        return "\(label) workspaces: \(entries)"
    }
}
