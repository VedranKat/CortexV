import Foundation

struct ChangeReviewService {
    let persistence: PersistenceContainer
    let fileSystemService: FileSystemService
    let diffService: DiffService

    func proposeFileWrite(sessionID: Int64, workspaceID: Int64?, relativePath: String, newContent: String) throws -> FileChange {
        let normalizedPath = try normalizeRequired(relativePath, fieldName: "path")
        let workspace = try resolveWritableWorkspace(sessionID: sessionID, requestedWorkspaceID: workspaceID)
        let currentContent = try fileSystemService.readFileIfExists(workspace: workspace, relativePath: normalizedPath)
        let proposedContent = newContent
        if (currentContent ?? "") == proposedContent {
            throw ToolExecutionError.message("The proposed file content is identical to the current file content.")
        }
        let changeSet = try persistence.changeSets.insert(sessionID: sessionID, workspaceID: workspace.id, status: "PENDING")
        let diffText = diffService.generate(filePath: normalizedPath, oldContent: currentContent, newContent: proposedContent)
        return try persistence.fileChanges.insert(
            changeSetID: changeSet.id,
            filePath: normalizedPath,
            oldContent: currentContent ?? "",
            newContent: proposedContent,
            diffText: diffText,
            status: "PENDING"
        )
    }

    func approveFileChange(_ fileChangeID: Int64) throws -> FileChange {
        let fileChange = try persistence.fileChanges.find(id: fileChangeID)
        let changeSet = try persistence.changeSets.find(id: fileChange.changeSetID)
        let workspace = try resolveChangeWorkspace(changeSet)
        try fileSystemService.writeFile(workspace: workspace, relativePath: fileChange.filePath, content: fileChange.newContent)
        try persistence.fileChanges.updateStatus(id: fileChange.id, status: "APPLIED")
        try persistence.changeSets.updateStatus(id: changeSet.id, status: "APPLIED")
        return try persistence.fileChanges.find(id: fileChange.id)
    }

    func rejectFileChange(_ fileChangeID: Int64) throws -> FileChange {
        let fileChange = try persistence.fileChanges.find(id: fileChangeID)
        let changeSet = try persistence.changeSets.find(id: fileChange.changeSetID)
        try persistence.fileChanges.updateStatus(id: fileChange.id, status: "REJECTED")
        try persistence.changeSets.updateStatus(id: changeSet.id, status: "REJECTED")
        return try persistence.fileChanges.find(id: fileChange.id)
    }

    private func resolveChangeWorkspace(_ changeSet: ChangeSet) throws -> Workspace {
        if let workspaceID = changeSet.workspaceID {
            return try persistence.workspaces.find(id: workspaceID)
        }
        let session = try persistence.sessions.find(id: changeSet.sessionID)
        if let workspaceID = session.workspaceID {
            return try persistence.workspaces.find(id: workspaceID)
        }
        throw ToolExecutionError.message("This change proposal is missing a workspace reference.")
    }

    private func resolveWritableWorkspace(sessionID: Int64, requestedWorkspaceID: Int64?) throws -> Workspace {
        let session = try persistence.sessions.find(id: sessionID)
        let boundIDs = try persistence.agents.findWorkspaceIDs(agentID: session.agentID)
        let writable = try boundIDs.map { try persistence.workspaces.find(id: $0) }
            .filter(\.allowWrite)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !writable.isEmpty else {
            throw ToolExecutionError.message("No writable workspaces are bound to this session's agent.")
        }
        let targetID = requestedWorkspaceID ?? session.workspaceID
        guard let targetID else { return writable[0] }
        guard let workspace = writable.first(where: { $0.id == targetID }) else {
            throw ToolExecutionError.message("The selected workspace is not bound to this session's agent or does not allow writes.")
        }
        return workspace
    }

    private func normalizeRequired(_ value: String, fieldName: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { throw ToolExecutionError.message("Missing required argument '\(fieldName)'.") }
        return normalized
    }
}
