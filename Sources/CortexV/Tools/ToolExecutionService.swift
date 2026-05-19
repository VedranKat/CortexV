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

    func availableToolsForSession(_ sessionID: Int64) throws -> [ToolDefinition] {
        let readable = try readableWorkspacesForSession(sessionID)
        let writable = try writableWorkspacesForSession(sessionID)
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
                name: "read_file",
                description: "Read one UTF-8 text file from a readable workspace. Use this sparingly and do not reread the same file in the same turn once you already have its content. \(help)",
                inputSchema: schema(required: ["path"], properties: [
                    "workspaceId": ["type": "integer", "description": "Optional workspace id when multiple workspaces are available."],
                    "path": ["type": "string", "description": "File path inside the workspace, for example Package.swift or Sources/App.swift"]
                ])
            ))
            tools.append(ToolDefinition(
                name: "search_in_files",
                description: "Search readable UTF-8 files in a workspace for a case-insensitive query. Use this before reading broad files. \(help)",
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

    func executeToolCall(sessionID: Int64, toolCall: ToolCallRequest) -> String {
        do {
            let args = try parseArguments(toolCall.argumentsJSON)
            let workspaceID = optionalInt(args["workspaceId"])
            switch toolCall.name {
            case "list_files":
                return try listFiles(sessionID: sessionID, workspaceID: workspaceID, path: optionalText(args["path"]))
            case "read_file":
                return try readFile(sessionID: sessionID, workspaceID: workspaceID, path: requiredText(args["path"], name: "path"))
            case "search_in_files":
                return try searchInFiles(sessionID: sessionID, workspaceID: workspaceID, query: requiredText(args["query"], name: "query"), path: optionalText(args["path"]))
            case "propose_file_write":
                return try proposeFileWrite(sessionID: sessionID, workspaceID: workspaceID, path: requiredText(args["path"], name: "path"), newContent: requiredRawText(args["newContent"], name: "newContent"))
            default:
                return "Tool error: Unknown tool '\(toolCall.name)'."
            }
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    func listFiles(sessionID: Int64, workspaceID: Int64?, path: String?) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false)
        return try fileSystemService.listFiles(workspace: workspace, relativeDirectory: path)
    }

    func readFile(sessionID: Int64, workspaceID: Int64?, path: String) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false)
        return try fileSystemService.readFile(workspace: workspace, relativePath: path)
    }

    func searchInFiles(sessionID: Int64, workspaceID: Int64?, query: String, path: String?) throws -> String {
        let workspace = try resolveWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID, requireWrite: false)
        return try fileSystemService.searchInFiles(workspace: workspace, query: query, relativeDirectory: path)
    }

    func proposeFileWrite(sessionID: Int64, workspaceID: Int64?, path: String, newContent: String) throws -> String {
        let fileChange = try changeReviewService.proposeFileWrite(sessionID: sessionID, workspaceID: workspaceID, relativePath: path, newContent: newContent)
        return "Created change proposal #\(fileChange.id) for '\(fileChange.filePath)'. Review it in the Changes view before anything is written to disk."
    }

    private func readableWorkspacesForSession(_ sessionID: Int64) throws -> [Workspace] {
        try boundWorkspacesForSession(sessionID).filter(\.allowRead).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func writableWorkspacesForSession(_ sessionID: Int64) throws -> [Workspace] {
        try boundWorkspacesForSession(sessionID).filter(\.allowWrite).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func boundWorkspacesForSession(_ sessionID: Int64) throws -> [Workspace] {
        let session = try persistence.sessions.find(id: sessionID)
        let ids = try persistence.agents.findWorkspaceIDs(agentID: session.agentID)
        return try ids.map { try persistence.workspaces.find(id: $0) }
    }

    private func resolveWorkspace(sessionID: Int64, requestedWorkspaceID: Int64?, requireWrite: Bool) throws -> Workspace {
        let workspaces = try requireWrite ? writableWorkspacesForSession(sessionID) : readableWorkspacesForSession(sessionID)
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
