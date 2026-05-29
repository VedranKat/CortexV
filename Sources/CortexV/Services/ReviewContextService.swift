import Foundation

enum ReviewContextSendStatus: Equatable {
    case sent
    case skippedDuplicate
}

struct ReviewContextSendResult: Equatable {
    let sourceSessionID: Int64
    let targetSessionID: Int64
    let status: ReviewContextSendStatus
    let handoff: ReviewContextHandoff
}

enum ReviewContextPayload {
    static func message(for group: ReviewTaskGroup) -> String {
        let sourceID = group.sessionID.map { "#\($0)" } ?? group.id
        let outcome = "\(group.appliedCount) applied, \(group.rejectedCount) rejected, \(group.pendingCount) pending, \(group.blockedCount) blocked, \(group.warningCount) warning"
        let files = compactFileList(for: group)
        let warnings = warningSummary(for: group)
        let next = nextStep(for: group)

        var lines = [
            "Review update: Session \(sourceID), \(group.roleText), \(group.agentName)",
            "Workspace: \(group.workspaceName)",
            "Outcome: \(outcome).",
            "Files: \(files)"
        ]
        if !warnings.isEmpty {
            lines.append("Issues: \(warnings)")
        }
        lines.append("Next: \(next)")
        return lines.joined(separator: "\n")
    }

    static func hash(for group: ReviewTaskGroup) -> String {
        stableHash(group.leadContextFingerprint)
    }

    private static func compactFileList(for group: ReviewTaskGroup) -> String {
        let values = group.items
            .sorted { lhs, rhs in
                lhs.change.filePath.localizedCaseInsensitiveCompare(rhs.change.filePath) == .orderedAscending
            }
            .map { "\($0.change.filePath) (\($0.change.status.lowercased()))" }
        guard !values.isEmpty else { return "none" }
        let visible = values.prefix(12).joined(separator: ", ")
        let remaining = values.count - min(values.count, 12)
        return remaining > 0 ? "\(visible), +\(remaining) more" : visible
    }

    private static func warningSummary(for group: ReviewTaskGroup) -> String {
        let values = group.items.flatMap { item in
            (item.preflight?.issues ?? []).map { issue in
                "\(item.change.filePath): \(issue.title)"
            }
        }
        .prefix(6)
        return values.joined(separator: "; ")
    }

    private static func nextStep(for group: ReviewTaskGroup) -> String {
        if group.blockedCount > 0 {
            return "resolve blocked proposals before applying the rest."
        }
        if group.pendingCount > 0 {
            return "finish reviewing the remaining pending proposals before sending the lead forward."
        }
        if group.appliedCount > 0 {
            return "ready for reviewer or build/test verification unless another implementation pass is needed."
        }
        if group.rejectedCount > 0 {
            return "decide whether to request fixes or close this delegated task."
        }
        return "no review outcome to act on yet."
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}

struct ReviewContextService {
    let persistence: PersistenceContainer

    func sendLeadUpdate(for group: ReviewTaskGroup, allowDuplicate: Bool = false) throws -> ReviewContextSendResult {
        guard let sourceSessionID = group.sessionID,
              let targetSessionID = group.parentSessionID else {
            throw ToolExecutionError.message("Only sub-agent review tasks can send context to a lead.")
        }
        guard group.hasOutcome else {
            throw ToolExecutionError.message("Review at least one change before sending context to the lead.")
        }

        let payload = ReviewContextPayload.message(for: group)
        let payloadHash = ReviewContextPayload.hash(for: group)
        if !allowDuplicate,
           let existing = try persistence.reviewContextHandoffs.findLatest(sourceSessionID: sourceSessionID, targetSessionID: targetSessionID),
           existing.payloadHash == payloadHash {
            return ReviewContextSendResult(
                sourceSessionID: sourceSessionID,
                targetSessionID: targetSessionID,
                status: .skippedDuplicate,
                handoff: existing
            )
        }

        _ = try persistence.messages.insert(sessionID: targetSessionID, role: "context", content: payload)
        let handoff = try persistence.reviewContextHandoffs.insert(
            sourceSessionID: sourceSessionID,
            targetSessionID: targetSessionID,
            status: "SENT",
            payloadHash: payloadHash
        )
        return ReviewContextSendResult(
            sourceSessionID: sourceSessionID,
            targetSessionID: targetSessionID,
            status: .sent,
            handoff: handoff
        )
    }
}
