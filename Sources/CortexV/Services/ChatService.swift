import Foundation

@MainActor
struct ChatService {
    private let maxToolRounds = 12
    private let duplicateToolNotice = "Tool notice: This exact tool call already ran in this turn. Reuse the existing result instead of repeating it."
    private let proposalCreatedMessage = "I created one or more file change proposals. Open the Changes view to review the diff and approve or reject them."
    private let duplicateStopMessage = "I stopped because the model kept repeating the same tool call instead of moving forward. Review the current Activity and Changes views, then continue from there."
    private let safetyLimitMessage = "I stopped because the tool loop hit its safety limit. Review the current Activity and Changes views, then continue with a fresh follow-up message."
    private let noWritePermissionMessage = "I can inspect this workspace, but I cannot propose file edits because no writable workspace is available for this agent. Enable write access on a bound workspace and try again."
    private let duplicateDelegationPrefix = "Tool notice: Similar delegated work already exists."

    let persistence: PersistenceContainer
    let toolExecutionService: ToolExecutionService
    let llmClient: LLMClient

    func generateAssistantReply(sessionID: Int64) async throws {
        _ = try await generateReply(sessionID: sessionID, allowDelegation: true)
    }

    @discardableResult
    private func generateReply(
        sessionID: Int64,
        allowDelegation: Bool,
        scopedWorkspaceIDs: Set<Int64>? = nil,
        delegationRole: OrchestrationRole? = nil,
        handoffPrompt: String? = nil
    ) async throws -> String {
        let session = try persistence.sessions.find(id: sessionID)
        let agent = try persistence.agents.find(id: session.agentID)
        let persistedMessages = try persistence.messages.findBySessionID(sessionID)
        let latestUser = latestUserMessage(persistedMessages)
        var conversation = persistedMessages.map { conversationItem(for: $0) }
        var tools = try toolExecutionService.availableToolsForSession(sessionID, limitingToWorkspaceIDs: scopedWorkspaceIDs)
        if let delegationRole, delegationRole != .worker {
            tools.removeAll { $0.name == "propose_file_write" }
        }
        let delegationMembers = allowDelegation ? try usableDelegationMembers(for: agent) : []
        if allowDelegation {
            if agent.orchestrator, delegationMembers.contains(where: { $0.role == .worker }) {
                tools.removeAll { $0.name == "propose_file_write" }
            }
            tools.append(contentsOf: try delegationTools(for: agent, members: delegationMembers))
        }

        let editRequest = isEditRequest(latestUser)
        let canProposeWrites = tools.contains { $0.name == "propose_file_write" }
        let canDelegate = tools.contains { $0.name == "delegate_to_child_agent" }
        let shouldRequireWriteAccess = delegationRole == nil || delegationRole == .worker
        if editRequest && shouldRequireWriteAccess && !canProposeWrites && !canDelegate {
            _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: noWritePermissionMessage)
            return noWritePermissionMessage
        }

        var executedSignatures = Set<String>()
        var delegationClaimsThisTurn: [DelegationClaim] = []
        var duplicateOnlyRounds = 0
        var reviewableChangesAvailableThisTurn = false
        for _ in 0..<maxToolRounds {
            let response = try await llmClient.generateTurn(
                settings: ProviderSettings(baseURL: agent.baseURL, apiKey: agent.apiKey, defaultModel: agent.model),
                model: agent.model,
                systemPrompt: try mergeSystemPrompt(
                    agent: agent,
                    session: session,
                    tools: tools,
                    allowDelegation: allowDelegation,
                    delegationRole: delegationRole,
                    handoffPrompt: handoffPrompt
                ),
                conversation: conversation,
                tools: tools,
                temperature: agent.temperature
            )

            if response.hasToolCalls {
                var duplicateSeen = false
                var ranNonDuplicateTool = false
                conversation.append(.assistantToolCalls(content: response.content, toolCalls: response.toolCalls))

                for toolCall in response.toolCalls {
                    let signature = "\(toolCall.name)|\(toolCall.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines))"
                    if executedSignatures.contains(signature) {
                        duplicateSeen = true
                        _ = try persistence.toolCalls.insert(sessionID: sessionID, toolName: toolCall.name, argumentsJSON: toolCall.argumentsJSON, resultJSON: duplicateToolNotice, status: "SKIPPED")
                        conversation.append(.toolResult(toolCallID: toolCall.id, content: duplicateToolNotice))
                        continue
                    }
                    executedSignatures.insert(signature)
                    ranNonDuplicateTool = true

                    let result: String
                    if allowDelegation, toolCall.name == "delegate_to_child_agent" {
                        do {
                            let prepared = try prepareDelegation(parentSession: session, leadAgent: agent, toolCall: toolCall)
                            if let conflict = try delegationConflictMessage(for: prepared, claimsThisTurn: delegationClaimsThisTurn) {
                                result = conflict
                            } else {
                                let execution = try await executeDelegation(prepared)
                                delegationClaimsThisTurn.append(execution.claim)
                                result = execution.result
                            }
                        } catch {
                            result = "Tool error: \(error.localizedDescription)"
                        }
                    } else {
                        result = toolExecutionService.executeToolCall(sessionID: sessionID, toolCall: toolCall, limitingToWorkspaceIDs: scopedWorkspaceIDs)
                    }
                    _ = try persistence.toolCalls.insert(
                        sessionID: sessionID,
                        toolName: toolCall.name,
                        argumentsJSON: toolCall.argumentsJSON,
                        resultJSON: result,
                        status: result.hasPrefix("Tool error:") ? "FAILURE" : "SUCCESS"
                    )
                    conversation.append(.toolResult(toolCallID: toolCall.id, content: result))
                    if toolCall.name == "propose_file_write", !result.hasPrefix("Tool error:") {
                        reviewableChangesAvailableThisTurn = true
                    }
                    if toolCall.name == "delegate_to_child_agent",
                       !result.hasPrefix("Tool error:") {
                        if delegationResultMentionsReviewableChanges(result) {
                            reviewableChangesAvailableThisTurn = true
                        }
                    }
                }

                if duplicateSeen && !ranNonDuplicateTool {
                    duplicateOnlyRounds += 1
                } else {
                    duplicateOnlyRounds = 0
                }
                if duplicateOnlyRounds >= 2 {
                    _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: duplicateStopMessage)
                    return duplicateStopMessage
                }
                continue
            }

            let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply.isEmpty, reviewableChangesAvailableThisTurn {
                _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: proposalCreatedMessage)
                return proposalCreatedMessage
            }
            guard !reply.isEmpty else {
                throw ToolExecutionError.message("The agent returned no final text.")
            }
            if mentionsProposalWithoutTool(reply), !reviewableChangesAvailableThisTurn {
                let message = "I inspected the file, but I have not actually created a change proposal yet. Please ask me again if you want me to try the proposal step once more."
                _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: message)
                return message
            }
            _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: reply)
            return reply
        }

        let finalMessage = reviewableChangesAvailableThisTurn ? proposalCreatedMessage : safetyLimitMessage
        _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: finalMessage)
        return finalMessage
    }

    func generateSessionTitle(sessionID: Int64) async throws -> String {
        let session = try persistence.sessions.find(id: sessionID)
        let agent = try persistence.agents.find(id: session.agentID)
        let messages = try persistence.messages.findBySessionID(sessionID)
        guard let firstUserMessage = messages.first(where: { $0.role.caseInsensitiveCompare("user") == .orderedSame }) else {
            return ""
        }
        let firstAssistantMessage = messages.first(where: { $0.role.caseInsensitiveCompare("assistant") == .orderedSame })

        var conversation = [
            ConversationItem.text(role: "user", content: "User's first message:\n\(firstUserMessage.content)")
        ]
        if let firstAssistantMessage {
            conversation.append(.text(role: "user", content: "Agent's first reply:\n\(firstAssistantMessage.content)"))
        }
        conversation.append(.text(role: "user", content: "Create a concise 3-7 word title for this session. Return only the title, with no quotes and no punctuation at the end."))

        let response = try await llmClient.generateTurn(
            settings: ProviderSettings(baseURL: agent.baseURL, apiKey: agent.apiKey, defaultModel: agent.model),
            model: agent.model,
            systemPrompt: "You write short, specific conversation titles for a desktop AI agent app.",
            conversation: conversation,
            tools: [],
            temperature: 0.2
        )

        return cleanTitle(response.content)
    }

    private func mergeSystemPrompt(
        agent: Agent,
        session: Session,
        tools: [ToolDefinition],
        allowDelegation: Bool,
        delegationRole: OrchestrationRole?,
        handoffPrompt: String?
    ) throws -> String {
        let guidance = """
        You can inspect the workspace with tools, but use them deliberately.
        Never repeat the same tool call with the same arguments once you already have its result.
        When the user asks for file changes, inspect only what you need, then call propose_file_write with the full replacement content for every file that should be created or changed.
        Do not keep calling read_file on the same target file after you already have its content.
        Never tell the user that you created, proposed, or prepared file changes unless you actually called propose_file_write successfully in this turn.
        After all required propose_file_write calls succeed, stop calling tools and tell the user to review the Changes view.
        When you have enough information, stop calling tools and answer the user directly.
        """
        var sections = basePromptSections(for: agent)
        if !tools.isEmpty {
            sections.append(guidance)
        }
        if let delegationRole {
            sections.append(childAgentGuidance(role: delegationRole, handoffPrompt: handoffPrompt))
        }
        if allowDelegation, let orchestrationGuidance = try orchestrationGuidance(for: agent, session: session) {
            sections.append(orchestrationGuidance)
        }
        return sections.joined(separator: "\n\n")
    }

    private func basePromptSections(for agent: Agent) -> [String] {
        let stored = agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if agent.orchestrator {
            if stored.isEmpty || stored == AgentPromptDefaults.standard || stored == AgentPromptDefaults.orchestrator {
                return [AgentPromptDefaults.orchestrator]
            }
            return [
                stored,
                "Cortex V default orchestrator behavior:\n\(AgentPromptDefaults.orchestrator)"
            ]
        }
        return [stored.isEmpty ? AgentPromptDefaults.standard : stored]
    }

    private func orchestrationGuidance(for agent: Agent, session: Session) throws -> String? {
        guard agent.orchestrator else { return nil }
        let members = try persistence.agents.findOrchestrationMembers(leadAgentID: agent.id)
        guard !members.isEmpty else { return nil }

        let childLines = try members.map { member in
            let child = try persistence.agents.find(id: member.childAgentID)
            let sharedWorkspaces = try sharedWorkspaceNames(leadAgentID: agent.id, childAgentID: member.childAgentID)
            return "- \(member.role.title): \(child.name). Shared workspace: \(sharedWorkspaces). Handoff: \(member.effectivePrompt)"
        }

        var guidance = """
        Runtime orchestration context:
        - Sub-agent results are returned as tool results and recorded as visible sub-agent sessions.
        - Treat existing sub-agent sessions and change proposals as a work ledger.
        - The `cortexv-diagnostics` folder is a local debugging artifact, not project source. Do not inspect it unless the user explicitly asks about diagnostics.

        Assigned sub-agents:
        \(childLines.joined(separator: "\n"))
        """
        if let childContext = try childRunContext(for: session) {
            guidance += "\n\n" + childContext
        }
        if let detachedContext = try detachedChildRunContext(for: session) {
            guidance += "\n\n" + detachedContext
        }
        return guidance
    }

    private func childRunContext(for session: Session) throws -> String? {
        let childRuns = try persistence.sessions.findChildren(parentSessionID: session.id)
        guard !childRuns.isEmpty else { return nil }

        let lines = try childRuns.sorted { $0.startedAt > $1.startedAt }.prefix(12).map { childRun in
            let child = try persistence.agents.find(id: childRun.agentID)
            let workspace = try childRun.workspaceID.map { try persistence.workspaces.find(id: $0).name } ?? "No workspace"
            let role = childRun.orchestrationRole?.title ?? "Sub-Agent Session"
            let changes = try persistence.fileChanges.findBySessionID(childRun.id)
            let changeSummary = fileChangeLedgerSummary(changes)
            let title = childRun.summary.isEmpty ? "Delegated task" : childRun.summary
            return "- #\(childRun.id): \(role), \(child.name), \(workspace), \(childRun.status.rawValue.capitalized), \(title). \(changeSummary)"
        }

        return """
        Existing sub-agent work for this lead:
        \(lines.joined(separator: "\n"))

        Use this ledger before delegating. Reuse results that already exist, review pending proposals, or ask for a narrow retry only after the previous scope has been rejected or resolved.
        """
    }

    private func detachedChildRunContext(for session: Session) throws -> String? {
        let detachedRuns = try persistence.sessions.findChildren(parentSessionID: session.id)
            .filter(\.detachedChildRun)
        guard !detachedRuns.isEmpty else { return nil }

        let lines = try detachedRuns.map { childRun in
            let agent = try persistence.agents.find(id: childRun.agentID)
            let role = childRun.orchestrationRole?.title ?? "Sub-Agent Session"
            return "- #\(childRun.id): \(role), \(agent.name), \(childRun.summary.isEmpty ? "Detached sub-agent session" : childRun.summary)"
        }

        return """
        Detached sub-agent sessions from this lead:
        \(lines.joined(separator: "\n"))

        These sessions keep provenance to this lead but are now standalone. Do not assume control over their future messages unless the user explicitly brings their contents back into this lead session.
        """
    }

    private func childAgentGuidance(role: OrchestrationRole, handoffPrompt: String?) -> String {
        let handoff = handoffPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHandoff = handoff?.isEmpty == false ? handoff! : role.defaultHandoffPrompt
        return """
        You are running as a \(role.title) sub-agent inside an orchestrated Cortex V session.
        Follow this role handoff: \(effectiveHandoff)
        Do not delegate further. Stay within the shared workspace tools made available for this sub-agent session.
        Return a concise result the lead agent can use directly.
        """
    }

    private func delegationTools(for agent: Agent, members: [OrchestrationMember]) throws -> [ToolDefinition] {
        guard agent.orchestrator else { return [] }
        guard !members.isEmpty else { return [] }
        let childDescriptions = try members.map { member in
            let child = try persistence.agents.find(id: member.childAgentID)
            let sharedWorkspaces = try sharedWorkspaceNames(leadAgentID: agent.id, childAgentID: member.childAgentID)
            return "\(member.childAgentID)=\(child.name) [\(member.role.title), shared: \(sharedWorkspaces)]"
        }.joined(separator: "; ")

        return [
            ToolDefinition(
                name: "delegate_to_child_agent",
                description: "Run one configured sub-agent on a bounded subtask, then return its result to the lead. Use this for repo scouting, log reading, bounded implementation, and review. For BOUNDED_WORKER, delegate one narrow implementation slice and do not repeat the same agent/role/workspace scope while proposals already exist. Available sub-agents: \(childDescriptions)",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "childAgentId": ["type": "integer", "description": "Optional exact sub-agent id. Prefer this when you know which sub-agent should run."],
                        "role": ["type": "string", "description": "Optional role when childAgentId is omitted. One of SCOUT, LOG_READER, BOUNDED_WORKER, REVIEWER."],
                        "workspaceId": ["type": "integer", "description": "Optional shared workspace id for this sub-agent session."],
                        "objective": ["type": "string", "description": "The bounded job for the sub-agent."],
                        "context": ["type": "string", "description": "Relevant context from the lead conversation."],
                        "expectedOutput": ["type": "string", "description": "The format or kind of result the lead needs back."]
                    ],
                    "required": ["objective"],
                    "additionalProperties": false
                ]
            )
        ]
    }

    private func prepareDelegation(parentSession: Session, leadAgent: Agent, toolCall: ToolCallRequest) throws -> PreparedDelegation {
        let args = try parseArguments(toolCall.argumentsJSON)
        let members = try usableDelegationMembers(for: leadAgent)
        let member = try resolveDelegationMember(
            members: members,
            childAgentID: optionalInt(args["childAgentId"]),
            roleText: optionalText(args["role"])
        )
        let child = try persistence.agents.find(id: member.childAgentID)
        guard child.enabled else {
            throw ToolExecutionError.message("\(child.name) is disabled.")
        }
        let sharedWorkspaceIDs = try sharedWorkspaceIDs(leadAgentID: leadAgent.id, childAgentID: child.id)
        guard !sharedWorkspaceIDs.isEmpty else {
            throw ToolExecutionError.message("\(child.name) no longer shares a workspace with \(leadAgent.name).")
        }

        let requestedWorkspaceID = optionalInt(args["workspaceId"])
        let workspaceID: Int64
        if let requestedWorkspaceID {
            guard sharedWorkspaceIDs.contains(requestedWorkspaceID) else {
                throw ToolExecutionError.message("Workspace #\(requestedWorkspaceID) is not shared by \(leadAgent.name) and \(child.name).")
            }
            workspaceID = requestedWorkspaceID
        } else if let parentWorkspaceID = parentSession.workspaceID, sharedWorkspaceIDs.contains(parentWorkspaceID) {
            workspaceID = parentWorkspaceID
        } else {
            workspaceID = sharedWorkspaceIDs.sorted().first!
        }

        let objective = try requiredText(args["objective"], name: "objective")
        let context = optionalText(args["context"])
        let expectedOutput = optionalText(args["expectedOutput"])
        let scope = delegationScope(objective: objective, context: context, expectedOutput: expectedOutput)

        return PreparedDelegation(
            parentSession: parentSession,
            leadAgent: leadAgent,
            member: member,
            child: child,
            sharedWorkspaceIDs: sharedWorkspaceIDs,
            workspaceID: workspaceID,
            objective: objective,
            context: context,
            expectedOutput: expectedOutput,
            scope: scope
        )
    }

    private func executeDelegation(_ prepared: PreparedDelegation) async throws -> DelegationExecution {
        let childPrompt = childPrompt(
            leadAgent: prepared.leadAgent,
            role: prepared.member.role,
            objective: prepared.objective,
            context: prepared.context,
            expectedOutput: prepared.expectedOutput,
            handoffPrompt: prepared.member.effectivePrompt
        )
        let childSession = try persistence.sessions.insert(
            agentID: prepared.child.id,
            workspaceID: prepared.workspaceID,
            parentSessionID: prepared.parentSession.id,
            orchestrationRole: prepared.member.role,
            status: .active,
            summary: childSessionSummary(role: prepared.member.role, objective: prepared.objective)
        )
        _ = try persistence.messages.insert(sessionID: childSession.id, role: "user", content: childPrompt)
        let reply: String
        do {
            reply = try await generateReply(
                sessionID: childSession.id,
                allowDelegation: false,
                scopedWorkspaceIDs: prepared.sharedWorkspaceIDs,
                delegationRole: prepared.member.role,
                handoffPrompt: prepared.member.effectivePrompt
            )
            _ = try persistence.sessions.updateStatus(id: childSession.id, status: .completed)
        } catch {
            let message = "Sub-agent session failed: \(error.localizedDescription)"
            _ = try? persistence.messages.insert(sessionID: childSession.id, role: "assistant", content: message)
            _ = try? persistence.sessions.updateStatus(id: childSession.id, status: .failed)
            throw ToolExecutionError.message(message)
        }

        let result = """
        Sub-agent session #\(childSession.id) completed.
        Agent: \(prepared.child.name)
        Role: \(prepared.member.role.title)
        Workspace: \(try persistence.workspaces.find(id: prepared.workspaceID).name)

        Result:
        \(reply)
        """

        let claim = DelegationClaim(
            sessionID: childSession.id,
            childAgentID: prepared.child.id,
            role: prepared.member.role,
            workspaceID: prepared.workspaceID,
            scope: prepared.scope,
            summary: childSession.summary
        )
        return DelegationExecution(result: result, claim: claim)
    }

    private func delegationConflictMessage(for prepared: PreparedDelegation, claimsThisTurn: [DelegationClaim]) throws -> String? {
        if let claim = claimsThisTurn.first(where: { claim in
            claim.childAgentID == prepared.child.id
                && claim.role == prepared.member.role
                && claim.workspaceID == prepared.workspaceID
                && scopesOverlap(claim.scope, prepared.scope)
        }) {
            return """
            \(duplicateDelegationPrefix) Session #\(claim.sessionID) already ran \(prepared.member.role.title) on \(prepared.child.name) for overlapping scope in this assistant turn.
            Reuse that result instead of launching another sub-agent. Existing scope: \(claim.scope.displayText).
            """
        }

        guard prepared.member.role == .worker else { return nil }

        let childRuns = try persistence.sessions.findChildren(parentSessionID: prepared.parentSession.id)
            .filter {
                $0.agentID == prepared.child.id
                    && $0.workspaceID == prepared.workspaceID
                    && $0.orchestrationRole == prepared.member.role
            }

        for childRun in childRuns {
            let fileChanges = try persistence.fileChanges.findBySessionID(childRun.id)
            let pendingChanges = fileChanges.filter(\.pending)
            let pendingScope = DelegationScope(filePaths: Set(pendingChanges.map(\.filePath)), tokens: normalizedTokens(from: [childRun.summary]))

            if !pendingChanges.isEmpty,
               prepared.scope.filePaths.isEmpty || scopesOverlap(pendingScope, prepared.scope) {
                return """
                \(duplicateDelegationPrefix) Session #\(childRun.id) already has pending \(prepared.member.role.title) proposals from \(prepared.child.name) for \(pendingScope.displayText).
                Do not start another worker for the same scope. Ask the user to review Changes, delegate a reviewer, or retry only after those proposals are resolved.
                """
            }
        }

        return nil
    }

    private func usableDelegationMembers(for agent: Agent) throws -> [OrchestrationMember] {
        try persistence.agents.findOrchestrationMembers(leadAgentID: agent.id).filter { member in
            guard let child = try? persistence.agents.find(id: member.childAgentID), child.enabled else {
                return false
            }
            guard let sharedIDs = try? sharedWorkspaceIDs(leadAgentID: agent.id, childAgentID: member.childAgentID) else {
                return false
            }
            return !sharedIDs.isEmpty
        }
    }

    private func resolveDelegationMember(members: [OrchestrationMember], childAgentID: Int64?, roleText: String) throws -> OrchestrationMember {
        let requestedRole: OrchestrationRole?
        if roleText.isEmpty {
            requestedRole = nil
        } else if let role = parseRole(roleText) {
            requestedRole = role
        } else {
            throw ToolExecutionError.message("Unknown orchestration role '\(roleText)'.")
        }

        if let childAgentID {
            var matches = members.filter { $0.childAgentID == childAgentID }
            if let requestedRole {
                matches = matches.filter { $0.role == requestedRole }
            }
            guard !matches.isEmpty else {
                throw ToolExecutionError.message("Sub-agent #\(childAgentID) is not configured, enabled, and workspace-compatible for this orchestrator.")
            }
            guard matches.count == 1 else {
                let roles = matches.map(\.role.title).joined(separator: ", ")
                throw ToolExecutionError.message("Sub-agent #\(childAgentID) has multiple configured roles. Choose one role: \(roles).")
            }
            return matches[0]
        }
        if let requestedRole {
            let matches = members.filter { $0.role == requestedRole }
            guard !matches.isEmpty else {
                throw ToolExecutionError.message("No configured sub-agent is available for role \(requestedRole.title).")
            }
            guard matches.count == 1 else {
                let ids = matches.map { String($0.childAgentID) }.joined(separator: ", ")
                throw ToolExecutionError.message("Role \(requestedRole.title) is ambiguous. Choose one childAgentId: \(ids).")
            }
            return matches[0]
        }
        guard members.count == 1, let onlyMember = members.first else {
            throw ToolExecutionError.message("Choose a childAgentId or role for delegation.")
        }
        return onlyMember
    }

    private func parseRole(_ value: String) -> OrchestrationRole? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "WORKER":
            return .worker
        case "LOGREADER", "LOG_READER":
            return .logReader
        case "REVIEW":
            return .reviewer
        default:
            break
        }
        return OrchestrationRole(rawValue: normalized)
            ?? OrchestrationRole.allCases.first { $0.title.uppercased().replacingOccurrences(of: " ", with: "_") == normalized }
    }

    private func childPrompt(leadAgent: Agent, role: OrchestrationRole, objective: String, context: String, expectedOutput: String, handoffPrompt: String) -> String {
        var sections = [
            "Lead agent: \(leadAgent.name)",
            "Role: \(role.title)",
            "Objective:\n\(objective)",
            "Role handoff:\n\(handoffPrompt)"
        ]
        if !context.isEmpty {
            sections.append("Context from lead:\n\(context)")
        }
        if !expectedOutput.isEmpty {
            sections.append("Expected output:\n\(expectedOutput)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func childSessionSummary(role: OrchestrationRole, objective: String) -> String {
        let cleaned = cleanTitle(objective)
        let title = cleaned.isEmpty ? "Delegated task" : cleaned
        return "\(role.title): \(title)"
    }

    private func sharedWorkspaceNames(leadAgentID: Int64, childAgentID: Int64) throws -> String {
        let sharedIDs = try sharedWorkspaceIDs(leadAgentID: leadAgentID, childAgentID: childAgentID)
        guard !sharedIDs.isEmpty else { return "none" }
        let names = try sharedIDs.map { try persistence.workspaces.find(id: $0).name }.sorted()
        return names.joined(separator: ", ")
    }

    private func sharedWorkspaceIDs(leadAgentID: Int64, childAgentID: Int64) throws -> Set<Int64> {
        let leadWorkspaceIDs = Set(try persistence.agents.findWorkspaceIDs(agentID: leadAgentID))
        let childWorkspaceIDs = Set(try persistence.agents.findWorkspaceIDs(agentID: childAgentID))
        return leadWorkspaceIDs.intersection(childWorkspaceIDs)
    }

    private func fileChangeLedgerSummary(_ changes: [FileChange]) -> String {
        guard !changes.isEmpty else { return "No file proposals recorded." }
        let pending = changes.filter(\.pending)
        let applied = changes.filter { $0.status.caseInsensitiveCompare("APPLIED") == .orderedSame }
        let rejected = changes.filter { $0.status.caseInsensitiveCompare("REJECTED") == .orderedSame }
        let uniquePaths = Array(Set(changes.map(\.filePath))).sorted()
        let paths = uniquePaths.prefix(8).joined(separator: ", ")
        let overflow = uniquePaths.count > 8 ? ", ..." : ""
        return "Proposals: \(pending.count) pending, \(applied.count) applied, \(rejected.count) rejected. Files: \(paths)\(overflow)."
    }

    private func delegationScope(objective: String, context: String, expectedOutput: String) -> DelegationScope {
        let texts = [objective, context, expectedOutput]
        return DelegationScope(
            filePaths: extractFilePaths(from: texts),
            tokens: normalizedTokens(from: texts)
        )
    }

    private func scopesOverlap(_ lhs: DelegationScope, _ rhs: DelegationScope) -> Bool {
        if !lhs.filePaths.isEmpty, !rhs.filePaths.isEmpty {
            return !lhs.filePaths.intersection(rhs.filePaths).isEmpty
        }

        let intersection = lhs.tokens.intersection(rhs.tokens)
        guard intersection.count >= 4 else { return false }
        let union = lhs.tokens.union(rhs.tokens)
        guard !union.isEmpty else { return false }
        return Double(intersection.count) / Double(union.count) >= 0.48
    }

    private func extractFilePaths(from texts: [String]) -> Set<String> {
        let combined = texts.joined(separator: "\n")
        let pattern = #"[A-Za-z0-9_.@-]+(?:/[A-Za-z0-9_.@-]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(combined.startIndex..<combined.endIndex, in: combined)
        return Set(regex.matches(in: combined, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: combined) else { return nil }
            return cleanExtractedPath(String(combined[matchRange]))
        })
    }

    private func cleanExtractedPath(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n`\"'()[]{}<>.,;:"))
            .replacingOccurrences(of: "\\", with: "/")
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.hasPrefix("cortexv-diagnostics/"),
              trimmed != "cortexv-diagnostics"
        else {
            return nil
        }
        return trimmed
    }

    private func normalizedTokens(from texts: [String]) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "from", "that", "this", "into", "onto", "then", "than",
            "all", "any", "one", "two", "use", "using", "make", "create", "write", "basic",
            "simple", "file", "files", "class", "these", "those", "need", "needs", "requested",
            "expected", "output", "role", "context", "objective", "already", "exists", "remaining"
        ]
        let combined = texts.joined(separator: " ").lowercased()
        return Set(combined.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    private func latestUserMessage(_ messages: [Message]) -> String {
        messages.last { $0.role.caseInsensitiveCompare("user") == .orderedSame }?.content ?? ""
    }

    private func conversationItem(for message: Message) -> ConversationItem {
        if message.role.caseInsensitiveCompare("context") == .orderedSame {
            return .text(role: "user", content: "Pinned orchestration context:\n\(message.content)")
        }
        return .text(role: message.role, content: message.content)
    }

    private func isEditRequest(_ content: String) -> Bool {
        let normalized = content.lowercased()
        return ["update ", "change ", "edit ", "modify ", "replace ", "refactor ", "fix ", "set ", "bump ", "rename ", "remove ", "add ", "upgrade ", "downgrade ", "rewrite ", "patch ", "implement ", "create ", "write ", "change the version", "update the version", "downgrade the version", "upgrade the version"].contains { normalized.contains($0) }
    }

    private func mentionsProposalWithoutTool(_ reply: String) -> Bool {
        let normalized = reply.lowercased()
        return [
            "changes view",
            "created a change proposal",
            "prepared a change proposal",
            "proposed the change",
            "approve the change"
        ].contains { normalized.contains($0) }
    }

    private func delegationResultMentionsReviewableChanges(_ result: String) -> Bool {
        let normalized = result.lowercased()
        return [
            "change proposal",
            "file change proposal",
            "proposed file",
            "proposed for creation",
            "proposals are ready",
            "review the changes view",
            "open the changes view",
            "pending proposals"
        ].contains { normalized.contains($0) }
    }

    private func cleanTitle(_ value: String) -> String {
        var title = value
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? value
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_# "))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".?!:;,- "))

        if title.count > 64 {
            title = String(title.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
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

    private func optionalInt(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private struct PreparedDelegation {
    let parentSession: Session
    let leadAgent: Agent
    let member: OrchestrationMember
    let child: Agent
    let sharedWorkspaceIDs: Set<Int64>
    let workspaceID: Int64
    let objective: String
    let context: String
    let expectedOutput: String
    let scope: DelegationScope
}

private struct DelegationExecution {
    let result: String
    let claim: DelegationClaim
}

private struct DelegationClaim {
    let sessionID: Int64
    let childAgentID: Int64
    let role: OrchestrationRole
    let workspaceID: Int64
    let scope: DelegationScope
    let summary: String
}

private struct DelegationScope {
    let filePaths: Set<String>
    let tokens: Set<String>

    var displayText: String {
        if !filePaths.isEmpty {
            let sorted = filePaths.sorted()
            let visible = sorted.prefix(8).joined(separator: ", ")
            return sorted.count > 8 ? "\(visible), ..." : visible
        }
        if !tokens.isEmpty {
            let sorted = tokens.sorted()
            let visible = sorted.prefix(8).joined(separator: ", ")
            return sorted.count > 8 ? "\(visible), ..." : visible
        }
        return "the requested task"
    }
}
