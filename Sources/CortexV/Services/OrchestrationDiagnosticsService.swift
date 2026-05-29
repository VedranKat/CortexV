import Foundation

enum OrchestrationDiagnosticsError: LocalizedError {
    case missingWorkspace
    case notOrchestrator

    var errorDescription: String? {
        switch self {
        case .missingWorkspace:
            "Select a session with a bound workspace before exporting diagnostics."
        case .notOrchestrator:
            "Diagnostics can only be exported for orchestrator sessions."
        }
    }
}

struct OrchestrationDiagnosticsService {
    let persistence: PersistenceContainer

    func exportReport(for selectedSessionID: Int64) throws -> URL {
        let root = try rootSession(startingAt: selectedSessionID)
        let rootAgent = try persistence.agents.find(id: root.agentID)
        guard rootAgent.orchestrator else {
            throw OrchestrationDiagnosticsError.notOrchestrator
        }
        let sessions = try collectSessionTree(rootID: root.id)
        let workspace = try reportWorkspace(root: root, sessions: sessions)
        let directory = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            .appendingPathComponent("cortexv-diagnostics", isDirectory: true)
            .appendingPathComponent("orchestration-runs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("session-\(root.id)-\(Self.fileTimestamp.string(from: Date())).md")
        try renderReport(root: root, selectedSessionID: selectedSessionID, sessions: sessions, workspace: workspace)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
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
            if lhs.startedAt == rhs.startedAt {
                return lhs.id < rhs.id
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    private func reportWorkspace(root: Session, sessions: [Session]) throws -> Workspace {
        if let workspaceID = root.workspaceID {
            return try persistence.workspaces.find(id: workspaceID)
        }
        if let workspaceID = sessions.compactMap(\.workspaceID).first {
            return try persistence.workspaces.find(id: workspaceID)
        }
        throw OrchestrationDiagnosticsError.missingWorkspace
    }

    private func renderReport(root: Session, selectedSessionID: Int64, sessions: [Session], workspace: Workspace) throws -> String {
        var lines: [String] = []
        let generatedAt = Self.displayTimestamp.string(from: Date())
        let rootAgent = try persistence.agents.find(id: root.agentID)

        lines.append("# Cortex V Orchestration Diagnostics")
        lines.append("")
        lines.append("- Generated: \(generatedAt)")
        lines.append("- Selected session: #\(selectedSessionID)")
        lines.append("- Root session: #\(root.id)")
        lines.append("- Root agent: \(rootAgent.name) (\(rootAgent.kind.title))")
        lines.append("- Workspace: \(workspace.name)")
        lines.append("- Workspace path: \(workspace.rootPath)")
        lines.append("- Diagnostics folder: `cortexv-diagnostics/orchestration-runs`")
        lines.append("")
        lines.append("> This report is a temporary local debugging artifact. Obvious API keys, bearer tokens, passwords, and secrets are redacted.")
        lines.append("")

        lines.append("## Session Tree")
        lines.append("")
        for session in sessions {
            lines.append("- \(try sessionTreeLine(session, rootID: root.id))")
        }
        lines.append("")

        lines.append("## Delegation Calls")
        lines.append("")
        let delegationCalls = try sessions.flatMap { session in
            try persistence.toolCalls.findBySessionID(session.id)
                .filter { $0.toolName == "delegate_to_child_agent" }
                .map { (session, $0) }
        }
        if delegationCalls.isEmpty {
            lines.append("No delegation calls recorded.")
        } else {
            for (session, toolCall) in delegationCalls {
                lines.append(try renderDelegationCall(session: session, toolCall: toolCall))
                lines.append("")
            }
        }
        lines.append("")

        lines.append("## Pinned Context Sent To Lead")
        lines.append("")
        let contextMessages = try persistence.messages.findBySessionID(root.id)
            .filter { $0.role.caseInsensitiveCompare("context") == .orderedSame }
        if contextMessages.isEmpty {
            lines.append("No pinned context messages recorded.")
        } else {
            for message in contextMessages {
                lines.append("### \(Self.displayTimestamp.string(from: message.timestamp))")
                lines.append(fenced(redact(message.content)))
                lines.append("")
            }
        }
        lines.append("")

        for session in sessions {
            lines.append(try renderSessionSection(session, rootID: root.id))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func sessionTreeLine(_ session: Session, rootID: Int64) throws -> String {
        let agent = try persistence.agents.find(id: session.agentID)
        let workspace = try session.workspaceID.map { try persistence.workspaces.find(id: $0).name } ?? "No workspace"
        let type = session.id == rootID ? "Lead" : sessionType(session)
        let detached = session.detachedAt.map { ", detached \(Self.displayTimestamp.string(from: $0))" } ?? ""
        return "#\(session.id) \(type) - \(agent.name), \(workspace), \(session.status.rawValue.capitalized), started \(Self.displayTimestamp.string(from: session.startedAt))\(detached)"
    }

    private func renderDelegationCall(session: Session, toolCall: ToolCall) throws -> String {
        let arguments = parseJSON(toolCall.argumentsJSON)
        let objective = clean(arguments["objective"] as? String) ?? "No objective recorded"
        let role = clean(arguments["role"] as? String) ?? "Role selected by lead/model"
        let childID = childSessionID(from: toolCall.resultJSON)
        let childLabel = try childID.map { id -> String in
            let childSession = try persistence.sessions.find(id: id)
            let childAgent = try persistence.agents.find(id: childSession.agentID)
            return "#\(id), \(childAgent.name), \(childSession.status.rawValue.capitalized)"
        } ?? "No sub-agent session id found in result"

        return """
        ### Delegation Tool Call #\(toolCall.id)

        - Lead/session making call: #\(session.id)
        - Timestamp: \(Self.displayTimestamp.string(from: toolCall.timestamp))
        - Status: \(toolCall.status)
        - Requested role: \(role)
        - Objective: \(objective)
        - Resulting sub-agent session: \(childLabel)

        Arguments:
        \(fenced(redact(prettyJSON(toolCall.argumentsJSON)), language: "json"))

        Result:
        \(fenced(redact(toolCall.resultJSON)))
        """
    }

    private func renderSessionSection(_ session: Session, rootID: Int64) throws -> String {
        let agent = try persistence.agents.find(id: session.agentID)
        let workspaceName = try session.workspaceID.map { try persistence.workspaces.find(id: $0).name } ?? "No workspace"
        let messages = try persistence.messages.findBySessionID(session.id)
        let toolCalls = try persistence.toolCalls.findBySessionID(session.id)
        let changeSets = try persistence.changeSets.findBySessionID(session.id)
        let fileChanges = try persistence.fileChanges.findBySessionID(session.id)
        let changeSetsByID = Dictionary(uniqueKeysWithValues: changeSets.map { ($0.id, $0) })

        var lines: [String] = []
        lines.append("## Session #\(session.id) - \(session.id == rootID ? "Lead" : sessionType(session))")
        lines.append("")
        lines.append("- Agent: \(agent.name)")
        lines.append("- Agent kind: \(agent.kind.title)")
        lines.append("- Role: \(session.orchestrationRole?.title ?? "None")")
        lines.append("- Workspace: \(workspaceName)")
        lines.append("- Status: \(session.status.rawValue.capitalized)")
        lines.append("- Started: \(Self.displayTimestamp.string(from: session.startedAt))")
        if let endedAt = session.endedAt {
            lines.append("- Ended: \(Self.displayTimestamp.string(from: endedAt))")
        }
        if let detachedAt = session.detachedAt {
            lines.append("- Detached: \(Self.displayTimestamp.string(from: detachedAt))")
            lines.append("- Detachment rule: lead does not receive this transcript unless a summary is sent as pinned context.")
        }
        lines.append("- Summary: \(session.summary.isEmpty ? "None" : session.summary)")
        lines.append("")

        lines.append("### Messages")
        lines.append("")
        if messages.isEmpty {
            lines.append("No messages recorded.")
        } else {
            for message in messages {
                lines.append("#### \(Self.displayTimestamp.string(from: message.timestamp)) - \(message.role)")
                lines.append(fenced(redact(message.content)))
                lines.append("")
            }
        }
        lines.append("")

        lines.append("### Tool Calls")
        lines.append("")
        if toolCalls.isEmpty {
            lines.append("No tool calls recorded.")
        } else {
            for toolCall in toolCalls {
                lines.append("#### \(Self.displayTimestamp.string(from: toolCall.timestamp)) - \(toolCall.toolName) (\(toolCall.status))")
                lines.append("Arguments:")
                lines.append(fenced(redact(prettyJSON(toolCall.argumentsJSON)), language: "json"))
                lines.append("Result:")
                lines.append(fenced(redact(toolCall.resultJSON)))
                lines.append("")
            }
        }
        lines.append("")

        lines.append("### File Change Proposals")
        lines.append("")
        if fileChanges.isEmpty {
            lines.append("No file change proposals recorded.")
        } else {
            for fileChange in fileChanges {
                let workspace = try changeSetsByID[fileChange.changeSetID]?.workspaceID.map { try persistence.workspaces.find(id: $0).name } ?? "Unknown workspace"
                lines.append("#### \(fileChange.filePath) (\(fileChange.status))")
                lines.append("- Change set: #\(fileChange.changeSetID)")
                lines.append("- Workspace: \(workspace)")
                lines.append("")
                lines.append(fenced(redact(fileChange.diffText.isEmpty ? "No diff preview available." : fileChange.diffText), language: "diff"))
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func sessionType(_ session: Session) -> String {
        let role = session.orchestrationRole?.title ?? "Sub-Agent Session"
        return session.detachedChildRun ? "Detached \(role)" : role
    }

    private func parseJSON(_ json: String) -> [String: Any] {
        let data = Data(json.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func prettyJSON(_ json: String) -> String {
        let data = Data(json.utf8)
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return json.isEmpty ? "{}" : json
        }
        return pretty
    }

    private func childSessionID(from result: String) -> Int64? {
        let pattern = #"Sub-agent session #([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        guard let match = regex.firstMatch(in: result, range: range),
              let idRange = Range(match.range(at: 1), in: result)
        else {
            return nil
        }
        return Int64(String(result[idRange]))
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fenced(_ text: String, language: String = "text") -> String {
        let fence = text.contains("```") ? "````" : "```"
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    private func redact(_ text: String) -> String {
        var output = text
        output = replace(pattern: #"(?i)(authorization\s*[:=]\s*bearer\s+)[A-Za-z0-9._~+/\-=]+"#, in: output, with: "$1[REDACTED]")
        output = replace(pattern: #"(?i)((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,;]+"#, in: output, with: "$1[REDACTED]")
        output = replace(pattern: #"sk-[A-Za-z0-9_-]{12,}"#, in: output, with: "[REDACTED_KEY]")
        return output
    }

    private func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static let displayTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
