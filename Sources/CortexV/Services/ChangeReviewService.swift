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
            baseContentExists: currentContent != nil,
            newContent: proposedContent,
            diffText: diffText,
            status: "PENDING"
        )
    }

    func approveFileChange(_ fileChangeID: Int64) throws -> FileChange {
        let fileChange = try persistence.fileChanges.find(id: fileChangeID)
        let preflight = try makePreflightService().preflight(fileChange)
        guard preflight.canApprove else {
            throw ToolExecutionError.message(preflight.blockingSummary)
        }
        let changeSet = try persistence.changeSets.find(id: fileChange.changeSetID)
        let workspace = try resolveChangeWorkspace(changeSet)
        try fileSystemService.writeFile(workspace: workspace, relativePath: fileChange.filePath, content: fileChange.newContent)
        try persistence.fileChanges.updateStatus(id: fileChange.id, status: "APPLIED")
        try updateChangeSetStatus(id: changeSet.id)
        return try persistence.fileChanges.find(id: fileChange.id)
    }

    func rejectFileChange(_ fileChangeID: Int64) throws -> FileChange {
        let fileChange = try persistence.fileChanges.find(id: fileChangeID)
        let changeSet = try persistence.changeSets.find(id: fileChange.changeSetID)
        try persistence.fileChanges.updateStatus(id: fileChange.id, status: "REJECTED")
        try updateChangeSetStatus(id: changeSet.id)
        return try persistence.fileChanges.find(id: fileChange.id)
    }

    func approvePendingFileChanges(sessionID: Int64) throws -> [FileChange] {
        let pending = try persistence.fileChanges.findBySessionID(sessionID).filter(\.pending)
        let preflightResults = try makePreflightService().preflight(pending)
        let blocked = preflightResults.values.filter { !$0.canApprove }
        guard blocked.isEmpty else {
            let paths = blocked
                .sorted { $0.filePath.localizedCaseInsensitiveCompare($1.filePath) == .orderedAscending }
                .map(\.filePath)
                .prefix(4)
                .joined(separator: ", ")
            throw ToolExecutionError.message("Batch apply blocked by \(blocked.count) unsafe proposal\(blocked.count == 1 ? "" : "s"): \(paths). Review the preflight warnings in Changes.")
        }

        let plans = try pending.map { fileChange in
            let changeSet = try persistence.changeSets.find(id: fileChange.changeSetID)
            let workspace = try resolveChangeWorkspace(changeSet)
            let originalContent = try fileSystemService.readFileIfExists(workspace: workspace, relativePath: fileChange.filePath)
            return BatchApplyPlan(fileChange: fileChange, changeSet: changeSet, workspace: workspace, originalContent: originalContent)
        }

        var appliedPlans: [BatchApplyPlan] = []
        do {
            for plan in plans {
                try applyPreflightedFileChange(plan.fileChange, changeSet: plan.changeSet, workspace: plan.workspace)
                appliedPlans.append(plan)
            }
            return try appliedPlans.map { try persistence.fileChanges.find(id: $0.fileChange.id) }
        } catch {
            let rollbackErrors = rollbackAppliedBatch(appliedPlans)
            if rollbackErrors.isEmpty {
                throw error
            }
            throw ToolExecutionError.message("Batch apply failed and rollback could not fully restore all files: \(rollbackErrors.joined(separator: " ")) Original error: \(error.localizedDescription)")
        }
    }

    func rejectPendingFileChanges(sessionID: Int64) throws -> [FileChange] {
        let pending = try persistence.fileChanges.findBySessionID(sessionID).filter(\.pending)
        return try pending.map { try rejectFileChange($0.id) }
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

    private func updateChangeSetStatus(id: Int64) throws {
        let fileChanges = try persistence.fileChanges.findByChangeSetID(id)
        guard !fileChanges.isEmpty else { return }
        let statuses = Set(fileChanges.map { $0.status.uppercased() })
        let status: String
        if statuses == ["APPLIED"] {
            status = "APPLIED"
        } else if statuses == ["REJECTED"] {
            status = "REJECTED"
        } else if statuses.contains("PENDING") {
            status = "PENDING"
        } else {
            status = "MIXED"
        }
        try persistence.changeSets.updateStatus(id: id, status: status)
    }

    private func applyPreflightedFileChange(_ fileChange: FileChange, changeSet: ChangeSet, workspace: Workspace) throws {
        try fileSystemService.writeFile(workspace: workspace, relativePath: fileChange.filePath, content: fileChange.newContent)
        try persistence.fileChanges.updateStatus(id: fileChange.id, status: "APPLIED")
        try updateChangeSetStatus(id: changeSet.id)
    }

    private func rollbackAppliedBatch(_ appliedPlans: [BatchApplyPlan]) -> [String] {
        var errors: [String] = []
        for plan in appliedPlans.reversed() {
            do {
                try fileSystemService.restoreFile(
                    workspace: plan.workspace,
                    relativePath: plan.fileChange.filePath,
                    content: plan.originalContent
                )
                try persistence.fileChanges.updateStatus(id: plan.fileChange.id, status: "PENDING")
                try updateChangeSetStatus(id: plan.changeSet.id)
            } catch {
                errors.append("\(plan.fileChange.filePath): \(error.localizedDescription)")
            }
        }
        return errors
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

    private func makePreflightService() -> ChangePreflightService {
        ChangePreflightService(
            persistence: persistence,
            fileSystemService: fileSystemService
        )
    }

    private func normalizeRequired(_ value: String, fieldName: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { throw ToolExecutionError.message("Missing required argument '\(fieldName)'.") }
        return normalized
    }
}

private struct BatchApplyPlan {
    let fileChange: FileChange
    let changeSet: ChangeSet
    let workspace: Workspace
    let originalContent: String?
}
