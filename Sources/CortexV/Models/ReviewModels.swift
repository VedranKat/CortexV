import Foundation

enum ReviewStatusFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case applied
    case rejected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pending: "Pending"
        case .applied: "Applied"
        case .rejected: "Rejected"
        }
    }
}

enum ReviewSafetyFilter: String, CaseIterable, Identifiable {
    case all
    case ready
    case warning
    case blocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .ready: "Ready"
        case .warning: "Warning"
        case .blocked: "Blocked"
        }
    }
}

enum ReviewSyncFilter: String, CaseIterable, Identifiable {
    case all
    case needsLeadSync
    case sent
    case changedSinceSent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .needsLeadSync: "Needs Sync"
        case .sent: "Sent"
        case .changedSinceSent: "Changed"
        }
    }
}

enum ReviewLeadSyncState: String, Identifiable, Equatable {
    case notApplicable
    case waitingForReview
    case needsLeadSync
    case sent
    case changedSinceSent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notApplicable: "No Lead"
        case .waitingForReview: "Reviewing"
        case .needsLeadSync: "Needs Sync"
        case .sent: "Sent"
        case .changedSinceSent: "Changed"
        }
    }

    var systemImage: String {
        switch self {
        case .notApplicable: "minus.circle"
        case .waitingForReview: "clock"
        case .needsLeadSync: "arrow.up.message"
        case .sent: "checkmark.circle"
        case .changedSinceSent: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }
}

struct ReviewFilters: Equatable {
    var status: ReviewStatusFilter = .pending
    var safety: ReviewSafetyFilter = .all
    var sync: ReviewSyncFilter = .all
    var workspaceID: Int64?
    var rootSessionID: Int64?
    var sessionID: Int64?
    var role: OrchestrationRole?
    var agentID: Int64?
    var searchText: String = ""

    var hasActiveFacets: Bool {
        status != .pending
            || safety != .all
            || sync != .all
            || workspaceID != nil
            || rootSessionID != nil
            || sessionID != nil
            || role != nil
            || agentID != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func reset() {
        self = ReviewFilters()
    }
}

struct ReviewFacetOption: Identifiable, Equatable {
    let id: Int64
    let title: String
    let subtitle: String?
    let count: Int
}

struct ReviewRoleFacetOption: Identifiable, Equatable {
    let role: OrchestrationRole
    let count: Int

    var id: String { role.rawValue }
    var title: String { role.title }
}

struct ReviewQueueSummary: Equatable {
    var taskCount: Int = 0
    var fileCount: Int = 0
    var pendingCount: Int = 0
    var appliedCount: Int = 0
    var rejectedCount: Int = 0
    var blockedCount: Int = 0
    var warningCount: Int = 0
    var needsLeadSyncCount: Int = 0
}

struct ReviewChangeItem: Identifiable, Equatable {
    let change: FileChange
    let changeSet: ChangeSet?
    let session: Session?
    let preflight: ChangePreflightResult?
    let rootSessionID: Int64?
    let parentSessionID: Int64?
    let agentID: Int64?
    let agentName: String
    let workspaceID: Int64?
    let workspaceName: String
    let role: OrchestrationRole?
    let roleText: String
    let sessionTitle: String
    let rootTitle: String
    let createdAt: Date?

    var id: Int64 { change.id }
    var sessionID: Int64? { changeSet?.sessionID }
    var sortDate: Date { createdAt ?? session?.startedAt ?? .distantPast }
    var pending: Bool { change.pending }
    var applied: Bool { change.applied }
    var rejected: Bool { change.rejected }
    var blocked: Bool { change.pending && preflight?.status == .blocked }
    var warning: Bool { change.pending && preflight?.status == .warning }
    var ready: Bool { change.pending && preflight?.status == .ready }
    var canApprove: Bool { change.pending && preflight?.canApprove != false }
    var hasWarnings: Bool { change.pending && preflight?.hasWarnings == true }
}

struct ReviewTaskGroup: Identifiable, Equatable {
    let id: String
    let sessionID: Int64?
    let parentSessionID: Int64?
    let rootSessionID: Int64?
    let agentID: Int64?
    let workspaceID: Int64?
    let role: OrchestrationRole?
    let taskTitle: String
    let rootTitle: String
    let agentName: String
    let workspaceName: String
    let roleText: String
    let startedAt: Date?
    let latestHandoff: ReviewContextHandoff?
    let syncState: ReviewLeadSyncState
    let items: [ReviewChangeItem]

    var sortDate: Date { items.map(\.sortDate).max() ?? startedAt ?? .distantPast }
    var pendingItems: [ReviewChangeItem] { items.filter(\.pending) }
    var appliedItems: [ReviewChangeItem] { items.filter(\.applied) }
    var rejectedItems: [ReviewChangeItem] { items.filter(\.rejected) }
    var approvablePendingItems: [ReviewChangeItem] { pendingItems.filter(\.canApprove) }
    var readyPendingItems: [ReviewChangeItem] { pendingItems.filter { $0.preflight?.status == .ready } }
    var warningItems: [ReviewChangeItem] { items.filter(\.warning) }
    var blockedItems: [ReviewChangeItem] { items.filter(\.blocked) }

    var fileCount: Int { items.count }
    var pendingCount: Int { pendingItems.count }
    var appliedCount: Int { appliedItems.count }
    var rejectedCount: Int { rejectedItems.count }
    var warningCount: Int { warningItems.count }
    var blockedCount: Int { blockedItems.count }
    var hasOutcome: Bool { appliedCount + rejectedCount > 0 }
    var isFinished: Bool { pendingCount == 0 }
    var canBulkReview: Bool { pendingCount > 0 }
    var canSendLeadContext: Bool { parentSessionID != nil && hasOutcome }
    var canSendFinishedLeadContext: Bool { canSendLeadContext && isFinished }
    var needsLeadContext: Bool { syncState == .needsLeadSync || syncState == .changedSinceSent }

    var leadContextFingerprint: String {
        let issueText = items
            .flatMap { item in
                (item.preflight?.issues ?? []).map { "\(item.change.filePath):\($0.severity.rawValue):\($0.title)" }
            }
            .sorted()
            .joined(separator: "|")
        let files = items
            .map { "\($0.change.filePath):\($0.change.status.uppercased())" }
            .sorted()
            .joined(separator: "|")
        return [
            "source=\(sessionID.map(String.init) ?? id)",
            "target=\(parentSessionID.map(String.init) ?? "none")",
            "role=\(roleText)",
            "agent=\(agentName)",
            "workspace=\(workspaceName)",
            "pending=\(pendingCount)",
            "applied=\(appliedCount)",
            "rejected=\(rejectedCount)",
            "blocked=\(blockedCount)",
            "warning=\(warningCount)",
            "files=\(files)",
            "issues=\(issueText)"
        ].joined(separator: "\n")
    }

    var searchBlob: String {
        ([taskTitle, rootTitle, agentName, workspaceName, roleText]
            + items.map(\.change.filePath))
            .joined(separator: " ")
            .lowercased()
    }
}

struct ReviewProjectionSnapshot: Equatable {
    let groups: [ReviewTaskGroup]
    let summary: ReviewQueueSummary
    let workspaceFacets: [ReviewFacetOption]
    let leadFacets: [ReviewFacetOption]
    let sessionFacets: [ReviewFacetOption]
    let agentFacets: [ReviewFacetOption]
    let roleFacets: [ReviewRoleFacetOption]

    func filteredGroups(using filters: ReviewFilters) -> [ReviewTaskGroup] {
        let searchTerms = filters.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .map(String.init)

        return groups.filter { group in
            includesStatus(group, filters.status)
                && includesSafety(group, filters.safety)
                && includesSync(group, filters.sync)
                && filters.workspaceID.map { group.workspaceID == $0 } ?? true
                && filters.rootSessionID.map { group.rootSessionID == $0 } ?? true
                && filters.sessionID.map { group.sessionID == $0 } ?? true
                && filters.role.map { group.role == $0 } ?? true
                && filters.agentID.map { group.agentID == $0 } ?? true
                && searchTerms.allSatisfy { group.searchBlob.contains($0) }
        }
    }

    private func includesStatus(_ group: ReviewTaskGroup, _ filter: ReviewStatusFilter) -> Bool {
        switch filter {
        case .all:
            true
        case .pending:
            group.pendingCount > 0 || group.needsLeadContext
        case .applied:
            group.appliedCount > 0
        case .rejected:
            group.rejectedCount > 0
        }
    }

    private func includesSafety(_ group: ReviewTaskGroup, _ filter: ReviewSafetyFilter) -> Bool {
        switch filter {
        case .all:
            true
        case .ready:
            group.readyPendingItems.count > 0
        case .warning:
            group.warningCount > 0
        case .blocked:
            group.blockedCount > 0
        }
    }

    private func includesSync(_ group: ReviewTaskGroup, _ filter: ReviewSyncFilter) -> Bool {
        switch filter {
        case .all:
            true
        case .needsLeadSync:
            group.syncState == .needsLeadSync
        case .sent:
            group.syncState == .sent
        case .changedSinceSent:
            group.syncState == .changedSinceSent
        }
    }
}

enum ReviewProjection {
    static func make(
        sessions: [Session],
        agents: [Agent],
        workspaces: [Workspace],
        changeSets: [ChangeSet],
        fileChanges: [FileChange],
        preflightResults: [Int64: ChangePreflightResult],
        handoffs: [ReviewContextHandoff]
    ) -> ReviewProjectionSnapshot {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let changeSetsByID = Dictionary(uniqueKeysWithValues: changeSets.map { ($0.id, $0) })
        let latestHandoffBySourceTarget = latestHandoffsBySourceTarget(handoffs)
        let rootIDBySessionID = sessions.reduce(into: [Int64: Int64]()) { result, session in
            result[session.id] = rootSessionID(for: session, sessionsByID: sessionsByID)
        }

        let items = fileChanges.map { change in
            let changeSet = changeSetsByID[change.changeSetID]
            let session = changeSet.flatMap { sessionsByID[$0.sessionID] }
            let rootSessionID = session.flatMap { rootIDBySessionID[$0.id] }
            let rootSession = rootSessionID.flatMap { sessionsByID[$0] }
            let agent = session.flatMap { agentsByID[$0.agentID] }
            let workspaceID = changeSet?.workspaceID ?? session?.workspaceID
            let workspace = workspaceID.flatMap { workspacesByID[$0] }
            let sessionTitle = displayTitle(for: session)
            let rootTitle = displayTitle(for: rootSession)
            let role = session?.orchestrationRole
            return ReviewChangeItem(
                change: change,
                changeSet: changeSet,
                session: session,
                preflight: preflightResults[change.id],
                rootSessionID: rootSessionID,
                parentSessionID: session?.parentSessionID,
                agentID: session?.agentID,
                agentName: agent?.name ?? "Unknown Agent",
                workspaceID: workspaceID,
                workspaceName: workspace?.name ?? "No workspace",
                role: role,
                roleText: role?.title ?? (session?.hasParentProvenance == true ? "Sub-Agent Session" : "Lead Session"),
                sessionTitle: sessionTitle,
                rootTitle: rootTitle,
                createdAt: changeSet?.createdAt
            )
        }

        let groupedItems = Dictionary(grouping: items) { item in
            item.sessionID.map { "session-\($0)" } ?? "change-set-\(item.change.changeSetID)"
        }

        let groups = groupedItems.map { key, values in
            let sortedItems = values.sorted {
                if $0.sortDate != $1.sortDate {
                    return $0.sortDate > $1.sortDate
                }
                return $0.change.filePath.localizedCaseInsensitiveCompare($1.change.filePath) == .orderedAscending
            }
            let first = sortedItems[0]
            let latestHandoff = latestHandoffBySourceTarget[sourceTargetKey(
                sourceSessionID: first.sessionID,
                targetSessionID: first.parentSessionID
            )]
            let preliminary = ReviewTaskGroup(
                id: key,
                sessionID: first.sessionID,
                parentSessionID: first.parentSessionID,
                rootSessionID: first.rootSessionID,
                agentID: first.agentID,
                workspaceID: first.workspaceID,
                role: first.role,
                taskTitle: first.sessionTitle,
                rootTitle: first.rootTitle,
                agentName: first.agentName,
                workspaceName: first.workspaceName,
                roleText: first.roleText,
                startedAt: first.session?.startedAt,
                latestHandoff: latestHandoff,
                syncState: .notApplicable,
                items: sortedItems
            )
            return preliminary.replacingSyncState(syncState(for: preliminary, latestHandoff: latestHandoff))
        }
        .sorted(by: sortGroups)

        return ReviewProjectionSnapshot(
            groups: groups,
            summary: summary(for: groups),
            workspaceFacets: facets(
                groups: groups,
                id: \.workspaceID,
                title: \.workspaceName,
                subtitle: { _ in nil }
            ),
            leadFacets: facets(
                groups: groups,
                id: \.rootSessionID,
                title: \.rootTitle,
                subtitle: { group in group.rootSessionID.map { "Session #\($0)" } }
            ),
            sessionFacets: facets(
                groups: groups,
                id: \.sessionID,
                title: \.taskTitle,
                subtitle: { group in group.sessionID.map { "Session #\($0)" } }
            ),
            agentFacets: facets(
                groups: groups,
                id: \.agentID,
                title: \.agentName,
                subtitle: { _ in nil }
            ),
            roleFacets: roleFacets(groups: groups)
        )
    }

    private static func displayTitle(for session: Session?) -> String {
        guard let session else { return "Missing session" }
        let summary = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "Session #\(session.id)" : summary
    }

    private static func rootSessionID(for session: Session, sessionsByID: [Int64: Session]) -> Int64 {
        var current = session
        var seen = Set<Int64>()
        while let parentID = current.parentSessionID, let parent = sessionsByID[parentID], !seen.contains(parentID) {
            seen.insert(current.id)
            current = parent
        }
        return current.id
    }

    private static func latestHandoffsBySourceTarget(_ handoffs: [ReviewContextHandoff]) -> [String: ReviewContextHandoff] {
        handoffs.reduce(into: [:]) { result, handoff in
            let key = sourceTargetKey(sourceSessionID: handoff.sourceSessionID, targetSessionID: handoff.targetSessionID)
            if let current = result[key], current.createdAt >= handoff.createdAt {
                return
            }
            result[key] = handoff
        }
    }

    private static func syncState(for group: ReviewTaskGroup, latestHandoff: ReviewContextHandoff?) -> ReviewLeadSyncState {
        guard group.parentSessionID != nil, group.hasOutcome else {
            return .notApplicable
        }
        guard group.isFinished else {
            return .waitingForReview
        }
        guard let latestHandoff else {
            return .needsLeadSync
        }
        return latestHandoff.payloadHash == ReviewContextPayload.hash(for: group)
            ? .sent
            : .changedSinceSent
    }

    private static func sortGroups(_ lhs: ReviewTaskGroup, _ rhs: ReviewTaskGroup) -> Bool {
        let lhsRank = groupRank(lhs)
        let rhsRank = groupRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.sortDate != rhs.sortDate {
            return lhs.sortDate > rhs.sortDate
        }
        return lhs.taskTitle.localizedCaseInsensitiveCompare(rhs.taskTitle) == .orderedAscending
    }

    private static func groupRank(_ group: ReviewTaskGroup) -> Int {
        if group.blockedCount > 0 { return 0 }
        if group.warningCount > 0 { return 1 }
        if group.pendingCount > 0 { return 2 }
        if group.syncState == .needsLeadSync || group.syncState == .changedSinceSent { return 3 }
        return 4
    }

    private static func summary(for groups: [ReviewTaskGroup]) -> ReviewQueueSummary {
        groups.reduce(into: ReviewQueueSummary()) { summary, group in
            summary.taskCount += 1
            summary.fileCount += group.fileCount
            summary.pendingCount += group.pendingCount
            summary.appliedCount += group.appliedCount
            summary.rejectedCount += group.rejectedCount
            summary.blockedCount += group.blockedCount
            summary.warningCount += group.warningCount
            if group.syncState == .needsLeadSync || group.syncState == .changedSinceSent {
                summary.needsLeadSyncCount += 1
            }
        }
    }

    private static func facets(
        groups: [ReviewTaskGroup],
        id: KeyPath<ReviewTaskGroup, Int64?>,
        title: KeyPath<ReviewTaskGroup, String>,
        subtitle: (ReviewTaskGroup) -> String?
    ) -> [ReviewFacetOption] {
        let grouped = Dictionary(grouping: groups) { group in
            group[keyPath: id]
        }
        return grouped.compactMap { optionalID, groups in
            guard let id = optionalID, let first = groups.first else { return nil }
            return ReviewFacetOption(
                id: id,
                title: first[keyPath: title],
                subtitle: subtitle(first),
                count: groups.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func roleFacets(groups: [ReviewTaskGroup]) -> [ReviewRoleFacetOption] {
        Dictionary(grouping: groups.compactMap(\.role)) { $0 }
            .map { role, values in ReviewRoleFacetOption(role: role, count: values.count) }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static func sourceTargetKey(sourceSessionID: Int64?, targetSessionID: Int64?) -> String {
        "\(sourceSessionID.map(String.init) ?? "nil")-\(targetSessionID.map(String.init) ?? "nil")"
    }
}

private extension ReviewTaskGroup {
    func replacingSyncState(_ syncState: ReviewLeadSyncState) -> ReviewTaskGroup {
        ReviewTaskGroup(
            id: id,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            rootSessionID: rootSessionID,
            agentID: agentID,
            workspaceID: workspaceID,
            role: role,
            taskTitle: taskTitle,
            rootTitle: rootTitle,
            agentName: agentName,
            workspaceName: workspaceName,
            roleText: roleText,
            startedAt: startedAt,
            latestHandoff: latestHandoff,
            syncState: syncState,
            items: items
        )
    }
}
