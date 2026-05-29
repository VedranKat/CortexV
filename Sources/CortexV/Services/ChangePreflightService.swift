import Foundation

enum ChangePreflightStatus: String, Equatable {
    case ready = "READY"
    case warning = "WARNING"
    case blocked = "BLOCKED"
    case resolved = "RESOLVED"

    var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .warning:
            return "Warning"
        case .blocked:
            return "Blocked"
        case .resolved:
            return "Resolved"
        }
    }
}

enum ChangePreflightSeverity: String, Equatable {
    case warning = "WARNING"
    case blocked = "BLOCKED"
}

struct ChangePreflightIssue: Identifiable, Equatable {
    var id: String { "\(severity.rawValue)-\(title)-\(detail)" }
    let severity: ChangePreflightSeverity
    let title: String
    let detail: String
}

struct ChangePreflightResult: Equatable {
    let fileChangeID: Int64
    let filePath: String
    let status: ChangePreflightStatus
    let issues: [ChangePreflightIssue]

    var canApprove: Bool {
        status != .blocked
    }

    var hasWarnings: Bool {
        issues.contains { $0.severity == .warning }
    }

    var blockingSummary: String {
        let blocked = issues.filter { $0.severity == .blocked }
        guard !blocked.isEmpty else {
            return "Preflight passed for '\(filePath)'."
        }
        let details = blocked.prefix(3).map { $0.title }.joined(separator: ", ")
        return "Approval blocked for '\(filePath)': \(details)."
    }

    static func resolved(fileChange: FileChange) -> ChangePreflightResult {
        ChangePreflightResult(
            fileChangeID: fileChange.id,
            filePath: fileChange.filePath,
            status: .resolved,
            issues: []
        )
    }

    static func blocked(fileChange: FileChange, title: String, detail: String) -> ChangePreflightResult {
        ChangePreflightResult(
            fileChangeID: fileChange.id,
            filePath: fileChange.filePath,
            status: .blocked,
            issues: [.blocked(title: title, detail: detail)]
        )
    }
}

struct ChangePreflightService {
    let persistence: PersistenceContainer
    let fileSystemService: FileSystemService

    func preflight(_ fileChanges: [FileChange]) throws -> [Int64: ChangePreflightResult] {
        var results: [Int64: ChangePreflightResult] = [:]
        for fileChange in fileChanges {
            do {
                results[fileChange.id] = try preflight(fileChange, scopedFileChanges: fileChanges)
            } catch {
                results[fileChange.id] = .blocked(
                    fileChange: fileChange,
                    title: "Preflight could not resolve proposal state",
                    detail: error.localizedDescription
                )
            }
        }
        return results
    }

    func preflight(_ fileChange: FileChange) throws -> ChangePreflightResult {
        try preflight(fileChange, scopedFileChanges: try persistence.fileChanges.findAll())
    }

    private func preflight(_ fileChange: FileChange, scopedFileChanges: [FileChange]) throws -> ChangePreflightResult {
        guard fileChange.pending else {
            return .resolved(fileChange: fileChange)
        }

        var issues: [ChangePreflightIssue] = []
        let changeSet = try persistence.changeSets.find(id: fileChange.changeSetID)
        let workspace = try resolveChangeWorkspace(changeSet)

        if !workspace.allowWrite {
            issues.append(.blocked(
                title: "Workspace write access is disabled",
                detail: "Enable write access for '\(workspace.name)' before applying this proposal."
            ))
        }

        do {
            let currentContent = try fileSystemService.readFileIfExists(workspace: workspace, relativePath: fileChange.filePath)
            if fileChange.baseContentExists {
                if currentContent == nil {
                    issues.append(.blocked(
                        title: "Base file is missing",
                        detail: "The proposal expected an existing file, but '\(fileChange.filePath)' no longer exists on disk."
                    ))
                } else if currentContent != fileChange.oldContent {
                    issues.append(.blocked(
                        title: "File changed on disk",
                        detail: "The current file content no longer matches the content used to create this proposal."
                    ))
                }
            } else if currentContent != nil {
                issues.append(.blocked(
                    title: "New file now exists",
                    detail: "The proposal expected to create '\(fileChange.filePath)', but a file already exists there."
                ))
            }
        } catch {
            issues.append(.blocked(
                title: "Path cannot be written safely",
                detail: error.localizedDescription
            ))
        }

        issues.append(contentsOf: duplicateTargetIssues(fileChange: fileChange, workspaceID: changeSet.workspaceID, scopedFileChanges: scopedFileChanges))
        issues.append(contentsOf: riskyOverwriteIssues(fileChange))

        let status: ChangePreflightStatus
        if issues.contains(where: { $0.severity == .blocked }) {
            status = .blocked
        } else if issues.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .ready
        }
        return ChangePreflightResult(
            fileChangeID: fileChange.id,
            filePath: fileChange.filePath,
            status: status,
            issues: issues
        )
    }

    private func duplicateTargetIssues(
        fileChange: FileChange,
        workspaceID: Int64?,
        scopedFileChanges: [FileChange]
    ) -> [ChangePreflightIssue] {
        let duplicates = scopedFileChanges.filter { other in
            guard other.id != fileChange.id, other.pending, other.filePath == fileChange.filePath else {
                return false
            }
            guard let otherChangeSet = try? persistence.changeSets.find(id: other.changeSetID) else {
                return false
            }
            return otherChangeSet.workspaceID == workspaceID
        }
        guard !duplicates.isEmpty else { return [] }
        let ids = duplicates.map { "#\($0.id)" }.joined(separator: ", ")
        return [.blocked(
            title: "Another pending proposal targets this file",
            detail: "Resolve proposal\(duplicates.count == 1 ? "" : "s") \(ids) before applying this one."
        )]
    }

    private func riskyOverwriteIssues(_ fileChange: FileChange) -> [ChangePreflightIssue] {
        let oldLines = normalizedLines(fileChange.oldContent)
        let newLines = normalizedLines(fileChange.newContent)
        var issues: [ChangePreflightIssue] = []

        if fileChange.newContent.count > 250_000 {
            issues.append(.warning(
                title: "Large replacement",
                detail: "The proposed content is over 250 KB. Review the full diff before applying."
            ))
        }

        if oldLines.count >= 24, newLines.count < max(3, oldLines.count / 3) {
            issues.append(.warning(
                title: "Large deletion",
                detail: "The proposal removes most of the file. Confirm this is intentional before applying."
            ))
        }

        return issues
    }

    private func normalizedLines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
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
}

private extension ChangePreflightIssue {
    static func warning(title: String, detail: String) -> ChangePreflightIssue {
        ChangePreflightIssue(severity: .warning, title: title, detail: detail)
    }

    static func blocked(title: String, detail: String) -> ChangePreflightIssue {
        ChangePreflightIssue(severity: .blocked, title: title, detail: detail)
    }
}
