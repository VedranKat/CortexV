import Foundation

struct OrchestrationRunMap: Equatable {
    let rootSessionID: Int64
    let selectedSessionID: Int64
    let nodes: [OrchestrationRunNode]
    let summary: OrchestrationRunSummary

    var shouldShow: Bool {
        summary.childRuns > 0 || nodes.first?.agentKind == .orchestrator || nodes.contains { $0.detached }
    }
}

struct OrchestrationRunNode: Identifiable, Equatable {
    let id: Int64
    let parentSessionID: Int64?
    let depth: Int
    let title: String
    let agentName: String
    let agentKind: AgentKind
    let roleTitle: String
    let roleSymbol: String
    let workspaceName: String
    let status: SessionStatus
    let detached: Bool
    let startedAt: Date
    let messagesCount: Int
    let toolCallsCount: Int
    let pendingChanges: Int
    let appliedChanges: Int
    let rejectedChanges: Int
    let blockedChanges: Int
    let warningChanges: Int
    let issues: [OrchestrationRunIssue]

    var issueCount: Int { issues.count }
}

struct OrchestrationRunIssue: Identifiable, Equatable {
    var id: String { "\(severity)-\(title)-\(detail)" }
    let severity: Severity
    let title: String
    let detail: String

    enum Severity: String, Equatable {
        case warning
        case blocked
    }
}

struct OrchestrationRunSummary: Equatable {
    let childRuns: Int
    let detachedRuns: Int
    let pendingChanges: Int
    let appliedChanges: Int
    let blockedChanges: Int
    let failedToolCalls: Int
}

struct OrchestrationRunMapService {
    let persistence: PersistenceContainer

    func runMap(for selectedSessionID: Int64, preflightResults: [Int64: ChangePreflightResult]) throws -> OrchestrationRunMap {
        let root = try rootSession(startingAt: selectedSessionID)
        let sessions = try collectSessionTree(rootID: root.id)
        let depthByID = depthMap(sessions: sessions, rootID: root.id)
        let nodes = try sessions.map { session in
            try node(
                session: session,
                rootID: root.id,
                selectedSessionID: selectedSessionID,
                depth: depthByID[session.id] ?? 0,
                preflightResults: preflightResults
            )
        }

        let summary = OrchestrationRunSummary(
            childRuns: nodes.filter { $0.parentSessionID != nil }.count,
            detachedRuns: nodes.filter(\.detached).count,
            pendingChanges: nodes.map(\.pendingChanges).reduce(0, +),
            appliedChanges: nodes.map(\.appliedChanges).reduce(0, +),
            blockedChanges: nodes.map(\.blockedChanges).reduce(0, +),
            failedToolCalls: nodes.flatMap(\.issues).filter { $0.title == "Failed tool call" }.count
        )

        return OrchestrationRunMap(
            rootSessionID: root.id,
            selectedSessionID: selectedSessionID,
            nodes: nodes,
            summary: summary
        )
    }

    private func node(
        session: Session,
        rootID: Int64,
        selectedSessionID: Int64,
        depth: Int,
        preflightResults: [Int64: ChangePreflightResult]
    ) throws -> OrchestrationRunNode {
        let agent = try persistence.agents.find(id: session.agentID)
        let workspaceName = try session.workspaceID.map { try persistence.workspaces.find(id: $0).name } ?? "No workspace"
        let messages = try persistence.messages.findBySessionID(session.id)
        let toolCalls = try persistence.toolCalls.findBySessionID(session.id)
        let changes = try persistence.fileChanges.findBySessionID(session.id)
        let pending = changes.filter(\.pending)
        let applied = changes.filter { $0.status.caseInsensitiveCompare("APPLIED") == .orderedSame }
        let rejected = changes.filter { $0.status.caseInsensitiveCompare("REJECTED") == .orderedSame }
        let blocked = pending.filter { preflightResults[$0.id]?.status == .blocked }
        let warnings = pending.filter { preflightResults[$0.id]?.status == .warning }

        return OrchestrationRunNode(
            id: session.id,
            parentSessionID: session.parentSessionID,
            depth: depth,
            title: title(for: session, rootID: rootID),
            agentName: agent.name,
            agentKind: agent.kind,
            roleTitle: roleTitle(for: session, rootID: rootID),
            roleSymbol: session.orchestrationRole?.systemImage ?? (session.id == rootID ? "person.2.wave.2" : "arrow.triangle.branch"),
            workspaceName: workspaceName,
            status: session.status,
            detached: session.detachedChildRun,
            startedAt: session.startedAt,
            messagesCount: messages.count,
            toolCallsCount: toolCalls.count,
            pendingChanges: pending.count,
            appliedChanges: applied.count,
            rejectedChanges: rejected.count,
            blockedChanges: blocked.count,
            warningChanges: warnings.count,
            issues: issues(session: session, messages: messages, toolCalls: toolCalls, blockedChanges: blocked.count, warningChanges: warnings.count)
        )
    }

    private func issues(
        session: Session,
        messages: [Message],
        toolCalls: [ToolCall],
        blockedChanges: Int,
        warningChanges: Int
    ) -> [OrchestrationRunIssue] {
        var result: [OrchestrationRunIssue] = []
        let failedCalls = toolCalls.filter { !$0.successful && $0.status.caseInsensitiveCompare("SKIPPED") != .orderedSame }
        if !failedCalls.isEmpty {
            result.append(OrchestrationRunIssue(
                severity: .warning,
                title: "Failed tool call",
                detail: "\(failedCalls.count) tool call\(failedCalls.count == 1 ? "" : "s") failed in this session."
            ))
        }
        if blockedChanges > 0 {
            result.append(OrchestrationRunIssue(
                severity: .blocked,
                title: "Blocked changes",
                detail: "\(blockedChanges) pending proposal\(blockedChanges == 1 ? "" : "s") failed preflight."
            ))
        }
        if warningChanges > 0 {
            result.append(OrchestrationRunIssue(
                severity: .warning,
                title: "Change warnings",
                detail: "\(warningChanges) pending proposal\(warningChanges == 1 ? "" : "s") need extra review."
            ))
        }
        if session.detachedChildRun {
            result.append(OrchestrationRunIssue(
                severity: .warning,
                title: "Detached from lead",
                detail: "The lead does not receive this transcript unless a summary is sent back."
            ))
        }
        if messages.contains(where: stalledRunMessage) {
            result.append(OrchestrationRunIssue(
                severity: .warning,
                title: "Run stalled",
                detail: "The assistant stopped because a tool loop repeated or hit the safety limit."
            ))
        }
        return result
    }

    private func stalledRunMessage(_ message: Message) -> Bool {
        guard message.role.caseInsensitiveCompare("assistant") == .orderedSame else { return false }
        let normalized = message.content.lowercased()
        return normalized.contains("i stopped because the model kept repeating")
            || normalized.contains("tool loop hit its safety limit")
            || normalized.contains("provider request failed")
    }

    private func title(for session: Session, rootID: Int64) -> String {
        if !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.summary
        }
        return session.id == rootID ? "Lead Session" : "Delegated task"
    }

    private func roleTitle(for session: Session, rootID: Int64) -> String {
        if session.id == rootID {
            return "Lead"
        }
        return session.orchestrationRole?.title ?? "Sub-Agent"
    }

    private func rootSession(startingAt sessionID: Int64) throws -> Session {
        var session = try persistence.sessions.find(id: sessionID)
        var seen = Set<Int64>()
        while let parentSessionID = session.parentSessionID, !seen.contains(parentSessionID) {
            seen.insert(session.id)
            session = try persistence.sessions.find(id: parentSessionID)
        }
        return session
    }

    private func collectSessionTree(rootID: Int64) throws -> [Session] {
        var result: [Session] = []
        var frontier = [try persistence.sessions.find(id: rootID)]
        var seen = Set<Int64>()

        while !frontier.isEmpty {
            let session = frontier.removeFirst()
            guard !seen.contains(session.id) else { continue }
            seen.insert(session.id)
            result.append(session)
            frontier.append(contentsOf: try persistence.sessions.findChildren(parentSessionID: session.id))
        }

        return result.sorted { lhs, rhs in
            if lhs.parentSessionID == rhs.parentSessionID {
                if lhs.startedAt == rhs.startedAt {
                    return lhs.id < rhs.id
                }
                return lhs.startedAt < rhs.startedAt
            }
            let lhsParent = lhs.parentSessionID ?? 0
            let rhsParent = rhs.parentSessionID ?? 0
            if lhsParent != rhsParent {
                return lhsParent < rhsParent
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    private func depthMap(sessions: [Session], rootID: Int64) -> [Int64: Int] {
        var depths = [rootID: 0]
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for session in sessions {
            depths[session.id] = depth(for: session, sessionsByID: sessionsByID, memo: &depths)
        }
        return depths
    }

    private func depth(for session: Session, sessionsByID: [Int64: Session], memo: inout [Int64: Int]) -> Int {
        if let value = memo[session.id] {
            return value
        }
        guard let parentID = session.parentSessionID,
              let parent = sessionsByID[parentID]
        else {
            memo[session.id] = 0
            return 0
        }
        let value = depth(for: parent, sessionsByID: sessionsByID, memo: &memo) + 1
        memo[session.id] = value
        return value
    }
}
