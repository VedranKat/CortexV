import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: NavigationSection? = .sessions
    @Published var snapshot: DashboardSnapshot = .empty
    @Published var statusText = "Ready"
    @Published var pendingCommand: AppCommand?
    @Published var agents: [Agent] = []
    @Published var workspaces: [Workspace] = []
    @Published var sessions: [Session] = []
    @Published var agentWorkspaceIDs: [Int64: Set<Int64>] = [:]
    @Published var orchestrationMembersByLeadID: [Int64: [OrchestrationMember]] = [:]
    @Published var messages: [Message] = []
    @Published var toolCalls: [ToolCall] = []
    @Published var fileChanges: [FileChange] = []
    @Published var allChangeSets: [ChangeSet] = []
    @Published var allFileChanges: [FileChange] = []
    @Published var reviewContextHandoffs: [ReviewContextHandoff] = []
    @Published var changeSetsByID: [Int64: ChangeSet] = [:]
    @Published var preflightResultsByFileChangeID: [Int64: ChangePreflightResult] = [:]
    @Published var selectedRunMap: OrchestrationRunMap?
    @Published var selectedAgentID: Int64?
    @Published var selectedWorkspaceID: Int64?
    @Published var selectedSessionID: Int64?
    @Published var isSendingMessage = false

    private let persistence: PersistenceContainer?
    private let fileSystemService = FileSystemService()
    private let diffService = DiffService()

    init() {
        do {
            let persistence = try PersistenceContainer()
            self.persistence = persistence
            refreshAll(using: persistence)
            statusText = "Ready - using \(AppPaths.databaseFile.path)"
        } catch {
            self.persistence = nil
            statusText = error.localizedDescription
        }
    }

    func prepareNewSession() {
        selectedSection = .sessions
        selectedSessionID = nil
        reloadSelectedSessionDetails()
        pendingCommand = .newSession
        if agents.isEmpty {
            statusText = "Create an agent before opening a session."
        } else {
            statusText = "Choose an agent, then optionally bind a workspace."
        }
    }

    func requestSend() {
        selectedSection = .sessions
        pendingCommand = .sendMessage
        statusText = "Use the session composer to send a message."
    }

    func consumePendingCommand(_ command: AppCommand) {
        guard pendingCommand == command else { return }
        pendingCommand = nil
    }

    func refreshSnapshot() {
        guard let persistence else { return }
        refreshAll(using: persistence)
    }

    func agentDraft(for agent: Agent? = nil) -> AgentDraft {
        guard let agent, let persistence else {
            return .new()
        }
        do {
            return AgentDraft(
                agent: agent,
                workspaceIDs: try persistence.agents.findWorkspaceIDs(agentID: agent.id),
                orchestrationMembers: try persistence.agents.findOrchestrationMembers(leadAgentID: agent.id)
            )
        } catch {
            statusText = error.localizedDescription
            return AgentDraft(agent: agent, workspaceIDs: [], orchestrationMembers: [])
        }
    }

    func workspaceDraft(for workspace: Workspace? = nil) -> WorkspaceDraft {
        workspace.map(WorkspaceDraft.init(workspace:)) ?? .new()
    }

    @discardableResult
    func saveAgent(_ draft: AgentDraft) -> Bool {
        guard let persistence else { return false }
        guard validateAgentDraft(draft) else { return false }
        do {
            let saved: Agent
            if let id = draft.id {
                let existing = try persistence.agents.find(id: id)
                saved = try persistence.agents.update(Agent(
                    id: id,
                    name: normalizeName(draft.name, fallback: "Unnamed Agent"),
                    description: normalizeText(draft.description),
                    baseURL: normalizeText(draft.baseURL),
                    apiKey: draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: normalizeText(draft.model),
                    systemPrompt: normalizePrompt(draft.systemPrompt, kind: draft.kind),
                    temperature: clampedTemperature(draft.temperature),
                    status: draft.status,
                    kind: draft.kind,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt
                ))
            } else {
                saved = try persistence.agents.insert(
                    name: normalizeName(draft.name, fallback: "New Agent"),
                    description: normalizeText(draft.description),
                    baseURL: normalizeText(draft.baseURL),
                    apiKey: draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: normalizeText(draft.model),
                    systemPrompt: normalizePrompt(draft.systemPrompt, kind: draft.kind),
                    temperature: clampedTemperature(draft.temperature),
                    status: draft.status,
                    kind: draft.kind
                )
            }
            try persistence.agents.replaceWorkspaceBindings(agentID: saved.id, workspaceIDs: Array(draft.workspaceIDs).sorted())
            try persistence.agents.replaceOrchestrationMembers(
                leadAgentID: saved.id,
                members: orchestrationMembers(from: draft, leadAgentID: saved.id)
            )
            selectedAgentID = saved.id
            refreshAll(using: persistence)
            statusText = "Saved agent '\(saved.name)'."
            return true
        } catch {
            statusText = error.localizedDescription
            return false
        }
    }

    func deleteSelectedAgent() {
        guard let persistence, let selectedAgentID else { return }
        do {
            let agent = try persistence.agents.find(id: selectedAgentID)
            try persistence.agents.delete(id: selectedAgentID)
            self.selectedAgentID = nil
            refreshAll(using: persistence)
            statusText = "Deleted agent '\(agent.name)'."
        } catch {
            statusText = error.localizedDescription
        }
    }

    @discardableResult
    func saveWorkspace(_ draft: WorkspaceDraft) -> Bool {
        guard let persistence else { return false }
        do {
            let saved: Workspace
            if let id = draft.id {
                let existing = try persistence.workspaces.find(id: id)
                saved = try persistence.workspaces.update(Workspace(
                    id: id,
                    name: normalizeName(draft.name, fallback: "Unnamed Workspace"),
                    rootPath: normalizedRootPath(draft.rootPath),
                    includePatterns: normalizeName(draft.includePatterns, fallback: "**/*"),
                    excludePatterns: normalizeText(draft.excludePatterns),
                    allowRead: true,
                    allowWrite: draft.allowWrite,
                    gitEnabled: draft.gitEnabled,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt
                ))
            } else {
                saved = try persistence.workspaces.insert(
                    name: normalizeName(draft.name, fallback: "New Workspace"),
                    rootPath: normalizedRootPath(draft.rootPath),
                    includePatterns: normalizeName(draft.includePatterns, fallback: "**/*"),
                    excludePatterns: normalizeText(draft.excludePatterns),
                    allowRead: true,
                    allowWrite: draft.allowWrite,
                    gitEnabled: draft.gitEnabled
                )
            }
            selectedWorkspaceID = saved.id
            refreshAll(using: persistence)
            statusText = "Saved workspace '\(saved.name)'."
            return true
        } catch {
            statusText = error.localizedDescription
            return false
        }
    }

    func deleteSelectedWorkspace() {
        guard let persistence, let selectedWorkspaceID else { return }
        do {
            let workspace = try persistence.workspaces.find(id: selectedWorkspaceID)
            try persistence.workspaces.delete(id: selectedWorkspaceID)
            self.selectedWorkspaceID = nil
            refreshAll(using: persistence)
            statusText = "Deleted workspace '\(workspace.name)'."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func selectSession(id: Int64?) {
        selectedSessionID = id
        if let id,
           let session = sessions.first(where: { $0.id == id }) {
            selectedAgentID = session.agentID
            selectedWorkspaceID = session.workspaceID
        }
        reloadSelectedSessionDetails()
    }

    func createSession(agentID: Int64? = nil, workspaceID: Int64? = nil, useDefaultWorkspace: Bool = true) {
        guard let persistence else { return }
        do {
            let resolvedAgentID = agentID ?? selectedAgentID ?? agents.first?.id
            guard let resolvedAgentID else {
                statusText = "Create or select an agent before opening a session."
                return
            }
            let agent = try persistence.agents.find(id: resolvedAgentID)
            guard agent.enabled else {
                statusText = "Enable '\(agent.name)' before opening a session."
                return
            }
            let boundWorkspaceIDs = try persistence.agents.findWorkspaceIDs(agentID: resolvedAgentID)
            let resolvedWorkspaceID = workspaceID ?? (useDefaultWorkspace ? selectedWorkspaceIDForSession(boundIDs: boundWorkspaceIDs) : nil)
            let session = try persistence.sessions.insert(
                agentID: resolvedAgentID,
                workspaceID: resolvedWorkspaceID,
                status: .active,
                summary: ""
            )
            selectedSessionID = session.id
            selectedAgentID = resolvedAgentID
            selectedWorkspaceID = resolvedWorkspaceID
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Opened session #\(session.id) for '\(agent.name)'."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func deleteSelectedSession() {
        guard let persistence, let selectedSessionID else { return }
        do {
            try persistence.sessions.delete(id: selectedSessionID)
            self.selectedSessionID = nil
            messages = []
            toolCalls = []
            fileChanges = []
            allChangeSets = []
            allFileChanges = []
            reviewContextHandoffs = []
            changeSetsByID = [:]
            selectedRunMap = nil
            preflightResultsByFileChangeID = [:]
            refreshAll(using: persistence)
            statusText = "Deleted session #\(selectedSessionID)."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func detachSelectedSession() {
        guard let persistence, let selectedSessionID else { return }
        do {
            let detached = try persistence.sessions.detach(id: selectedSessionID)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Detached session #\(detached.id). It can now continue as a standalone chat."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func exportSelectedSessionDiagnostics() {
        guard let persistence, let selectedSessionID else { return }
        do {
            let url = try OrchestrationDiagnosticsService(persistence: persistence)
                .exportReport(for: selectedSessionID)
            statusText = "Exported diagnostics to \(url.path)."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func sendSelectedSessionSummaryToLead(_ summary: String) {
        guard let persistence, let selectedSessionID else { return }
        let normalized = normalizeText(summary)
        guard !normalized.isEmpty else {
            statusText = "Create or paste a summary before sending context to the lead."
            return
        }
        do {
            let session = try persistence.sessions.find(id: selectedSessionID)
            guard session.detachedChildRun, let parentSessionID = session.parentSessionID else {
                statusText = "Only detached sub-agent sessions can send summaries to a lead."
                return
            }
            let agent = try persistence.agents.find(id: session.agentID)
            let role = session.orchestrationRole?.title ?? "Sub-Agent Session"
            let content = """
            Received context from detached \(role) session #\(session.id) (\(agent.name)).
            Only this summary was sent; the lead does not receive the detached session transcript.

            \(normalized)
            """
            _ = try persistence.messages.insert(sessionID: parentSessionID, role: "context", content: content)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Sent summary from session #\(session.id) to lead session #\(parentSessionID)."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func sendUserMessage(_ content: String) {
        guard let persistence else { return }
        let normalized = normalizeText(content)
        guard !normalized.isEmpty else { return }
        do {
            guard let selectedSessionID else {
                statusText = "Create or select a session before sending a message."
                return
            }
            let selectedSession = try persistence.sessions.find(id: selectedSessionID)
            if selectedSession.attachedChildRun {
                statusText = "Attached sub-agent sessions are read-only. Detach this session to continue it as a standalone chat."
                return
            }
            let existingMessages = try persistence.messages.findBySessionID(selectedSessionID)
            _ = try persistence.messages.insert(sessionID: selectedSessionID, role: "user", content: normalized)
            let shouldGenerateTitle = existingMessages.isEmpty
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            isSendingMessage = true
            statusText = "Sending message to provider..."
            let chatService = makeChatService(persistence: persistence)
            Task { @MainActor in
                do {
                    try await chatService.generateAssistantReply(sessionID: selectedSessionID)
                    if shouldGenerateTitle {
                        try await updateGeneratedTitle(sessionID: selectedSessionID, chatService: chatService, persistence: persistence)
                    }
                    refreshAll(using: persistence)
                    reloadSelectedSessionDetails()
                    statusText = "Received provider response for session #\(selectedSessionID)."
                } catch {
                    refreshAll(using: persistence)
                    reloadSelectedSessionDetails()
                    statusText = error.localizedDescription
                }
                isSendingMessage = false
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    func approveFileChange(id: Int64) {
        guard let persistence else { return }
        do {
            let approved = try makeChangeReviewService(persistence: persistence).approveFileChange(id)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Applied approved change to '\(approved.filePath)'."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func approvePendingChanges(sessionID: Int64) {
        guard let persistence else { return }
        do {
            let approved = try makeChangeReviewService(persistence: persistence).approvePendingFileChanges(sessionID: sessionID)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Applied \(approved.count) pending file change\(approved.count == 1 ? "" : "s")."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func approveFileChanges(ids: [Int64]) {
        guard let persistence else { return }
        do {
            let approved = try makeChangeReviewService(persistence: persistence).approveFileChanges(ids)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Applied \(approved.count) selected file change\(approved.count == 1 ? "" : "s")."
        } catch {
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = error.localizedDescription
        }
    }

    func rejectFileChange(id: Int64) {
        guard let persistence else { return }
        do {
            let rejected = try makeChangeReviewService(persistence: persistence).rejectFileChange(id)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Rejected proposed change for '\(rejected.filePath)'."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func rejectFileChanges(ids: [Int64]) {
        guard let persistence else { return }
        do {
            let rejected = try makeChangeReviewService(persistence: persistence).rejectFileChanges(ids)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Rejected \(rejected.count) selected file change\(rejected.count == 1 ? "" : "s")."
        } catch {
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = error.localizedDescription
        }
    }

    func rejectPendingChanges(sessionID: Int64) {
        guard let persistence else { return }
        do {
            let rejected = try makeChangeReviewService(persistence: persistence).rejectPendingFileChanges(sessionID: sessionID)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Rejected \(rejected.count) pending file change\(rejected.count == 1 ? "" : "s")."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func sendLeadUpdate(for group: ReviewTaskGroup, allowDuplicate: Bool = false) {
        guard let persistence else { return }
        do {
            let result = try ReviewContextService(persistence: persistence)
                .sendLeadUpdate(for: group, allowDuplicate: allowDuplicate)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            switch result.status {
            case .sent:
                statusText = "Sent review context from session #\(result.sourceSessionID) to lead session #\(result.targetSessionID)."
            case .skippedDuplicate:
                statusText = "Lead session #\(result.targetSessionID) already has the latest review context for session #\(result.sourceSessionID)."
            }
        } catch {
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = error.localizedDescription
        }
    }

    func sendLeadUpdates(for groups: [ReviewTaskGroup], finishedOnly: Bool) {
        guard let persistence else { return }
        let candidates = groups.filter { group in
            let canSend = finishedOnly ? group.canSendFinishedLeadContext : group.canSendLeadContext
            return canSend && group.syncState != .sent
        }
        guard !candidates.isEmpty else {
            statusText = finishedOnly ? "No finished review tasks need lead context." : "No review tasks can send lead context."
            return
        }
        do {
            let service = ReviewContextService(persistence: persistence)
            var sentCount = 0
            var skippedCount = 0
            for group in candidates {
                let result = try service.sendLeadUpdate(for: group)
                switch result.status {
                case .sent:
                    sentCount += 1
                case .skippedDuplicate:
                    skippedCount += 1
                }
            }
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Sent \(sentCount) lead update\(sentCount == 1 ? "" : "s"); skipped \(skippedCount) duplicate\(skippedCount == 1 ? "" : "s")."
        } catch {
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = error.localizedDescription
        }
    }

    func sendAppliedChangeReviewRequest(sessionID: Int64) {
        guard let persistence else { return }
        do {
            let session = try persistence.sessions.find(id: sessionID)
            guard let parentSessionID = session.parentSessionID else {
                statusText = "Only sub-agent changes can be sent back to a lead for review."
                return
            }
            let appliedChanges = try persistence.fileChanges.findBySessionID(sessionID)
                .filter { $0.status.caseInsensitiveCompare("APPLIED") == .orderedSame }
            guard !appliedChanges.isEmpty else {
                statusText = "Apply at least one file change before asking the lead to review."
                return
            }
            let agent = try persistence.agents.find(id: session.agentID)
            let role = session.orchestrationRole?.title ?? "Sub-Agent Session"
            let fileList = appliedChanges
                .map { "- \($0.filePath)" }
                .joined(separator: "\n")
            let content = """
            Applied changes from \(role) session #\(session.id) (\(agent.name)).

            Files applied:
            \(fileList)

            Suggested next step: delegate a reviewer to inspect the applied workspace state, then decide whether to run build/tests or request fixes.
            """
            _ = try persistence.messages.insert(sessionID: parentSessionID, role: "context", content: content)
            refreshAll(using: persistence)
            reloadSelectedSessionDetails()
            statusText = "Sent applied-change review request to lead session #\(parentSessionID)."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func agentName(for id: Int64) -> String {
        agents.first { $0.id == id }?.name ?? "Agent #\(id)"
    }

    func workspaceName(for id: Int64?) -> String {
        guard let id else { return "Not bound" }
        return workspaces.first { $0.id == id }?.name ?? "Workspace #\(id)"
    }

    func sessionWorkspaceOptions(for agentID: Int64?) -> [Workspace] {
        guard let persistence, let agentID else { return [] }
        do {
            let ids = Set(try persistence.agents.findWorkspaceIDs(agentID: agentID))
            return workspaces.filter { ids.contains($0.id) }
        } catch {
            statusText = error.localizedDescription
            return []
        }
    }

    func sessionAgentOptions(for workspaceID: Int64?) -> [Agent] {
        let enabledAgents = agents.filter(\.enabled)
        guard let persistence, let workspaceID else { return enabledAgents }
        do {
            return try enabledAgents.filter { agent in
                let ids = try persistence.agents.findWorkspaceIDs(agentID: agent.id)
                return ids.contains(workspaceID)
            }
        } catch {
            statusText = error.localizedDescription
            return []
        }
    }

    func boundWorkspaces(for agentID: Int64?) -> [Workspace] {
        guard let persistence, let agentID else { return [] }
        do {
            let ids = Set(try persistence.agents.findWorkspaceIDs(agentID: agentID))
            return workspaces.filter { ids.contains($0.id) }
        } catch {
            statusText = error.localizedDescription
            return []
        }
    }

    func orchestrationMembers(for leadAgentID: Int64?) -> [OrchestrationMember] {
        guard let leadAgentID else { return [] }
        return orchestrationMembersByLeadID[leadAgentID] ?? []
    }

    private func refreshAll(using persistence: PersistenceContainer) {
        do {
            let loadedSessions = try persistence.sessions.findAll()
            let loadedAgents = try persistence.agents.findAll()
            let loadedChangeSets = try persistence.changeSets.findAll()
            let loadedFileChanges = try persistence.fileChanges.findAll()
            sessions = loadedSessions
            agents = loadedAgents
            workspaces = try persistence.workspaces.findAll()
            allChangeSets = loadedChangeSets
            allFileChanges = loadedFileChanges
            reviewContextHandoffs = try persistence.reviewContextHandoffs.findAll()
            preflightResultsByFileChangeID = try makePreflightService(persistence: persistence).preflight(loadedFileChanges)

            var workspaceMap: [Int64: Set<Int64>] = [:]
            for agent in loadedAgents {
                workspaceMap[agent.id] = Set(try persistence.agents.findWorkspaceIDs(agentID: agent.id))
            }
            agentWorkspaceIDs = workspaceMap
            orchestrationMembersByLeadID = Dictionary(
                grouping: try persistence.agents.findAllOrchestrationMembers(),
                by: \.leadAgentID
            )

            let pendingChanges = loadedFileChanges.filter(\.pending).count
            snapshot = DashboardSnapshot(
                sessionsCount: loadedSessions.filter { !$0.attachedChildRun }.count,
                agentsCount: loadedAgents.count,
                workspacesCount: workspaces.count,
                pendingChangesCount: pendingChanges
            )

            if let selectedSessionID {
                selectedRunMap = try OrchestrationRunMapService(persistence: persistence).runMap(
                    for: selectedSessionID,
                    preflightResults: preflightResultsByFileChangeID
                )
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func reloadSelectedSessionDetails() {
        guard let persistence, let selectedSessionID else {
            messages = []
            toolCalls = []
            fileChanges = []
            changeSetsByID = [:]
            selectedRunMap = nil
            return
        }
        do {
            messages = try persistence.messages.findBySessionID(selectedSessionID)
            toolCalls = try persistence.toolCalls.findBySessionID(selectedSessionID)
            fileChanges = try persistence.fileChanges.findBySessionID(selectedSessionID)
            let changeSets = try persistence.changeSets.findBySessionID(selectedSessionID)
            changeSetsByID = Dictionary(uniqueKeysWithValues: changeSets.map { ($0.id, $0) })
            preflightResultsByFileChangeID.merge(try makePreflightService(persistence: persistence).preflight(fileChanges)) { _, new in new }
            selectedRunMap = try OrchestrationRunMapService(persistence: persistence).runMap(
                for: selectedSessionID,
                preflightResults: preflightResultsByFileChangeID
            )
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func selectedWorkspaceIDForSession(boundIDs: [Int64]) -> Int64? {
        if let selectedWorkspaceID, boundIDs.contains(selectedWorkspaceID) {
            return selectedWorkspaceID
        }
        return boundIDs.first
    }

    private func makeChangeReviewService(persistence: PersistenceContainer) -> ChangeReviewService {
        ChangeReviewService(
            persistence: persistence,
            fileSystemService: fileSystemService,
            diffService: diffService
        )
    }

    private func makePreflightService(persistence: PersistenceContainer) -> ChangePreflightService {
        ChangePreflightService(
            persistence: persistence,
            fileSystemService: fileSystemService
        )
    }

    private func updateGeneratedTitle(sessionID: Int64, chatService: ChatService, persistence: PersistenceContainer) async throws {
        let session = try persistence.sessions.find(id: sessionID)
        guard session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = try await chatService.generateSessionTitle(sessionID: sessionID)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try persistence.sessions.updateSummary(id: sessionID, summary: title)
    }

    private func makeChatService(persistence: PersistenceContainer) -> ChatService {
        let changeReviewService = makeChangeReviewService(persistence: persistence)
        let toolExecutionService = ToolExecutionService(
            persistence: persistence,
            fileSystemService: fileSystemService,
            changeReviewService: changeReviewService
        )
        return ChatService(
            persistence: persistence,
            toolExecutionService: toolExecutionService,
            llmClient: OpenAICompatibleClient()
        )
    }

    private func normalizeName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizeText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizePrompt(_ value: String, kind: AgentKind) -> String {
        let trimmed = normalizeText(value)
        if trimmed.isEmpty {
            return AgentPromptDefaults.systemPrompt(for: kind)
        }
        if kind == .orchestrator && trimmed == AgentPromptDefaults.standard {
            return AgentPromptDefaults.orchestrator
        }
        return trimmed
    }

    private func clampedTemperature(_ value: Double) -> Double {
        min(2.0, max(0.0, value))
    }

    private func normalizedRootPath(_ value: String) -> String {
        let trimmed = normalizeName(value, fallback: FileManager.default.homeDirectoryForCurrentUser.path)
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func validateAgentDraft(_ draft: AgentDraft) -> Bool {
        guard draft.kind == .orchestrator else { return true }

        let members = draft.orchestrationMembers
        let roleAssignments = members.map { "\($0.childAgentID)-\($0.role.rawValue)" }
        guard Set(roleAssignments).count == roleAssignments.count else {
            statusText = "Each sub-agent can only be assigned once per role."
            return false
        }

        if !members.isEmpty && draft.workspaceIDs.isEmpty {
            statusText = "Bind the orchestrator to a workspace before adding sub-agents."
            return false
        }

        for member in members {
            if let draftID = draft.id, member.childAgentID == draftID {
                statusText = "An orchestrator cannot assign itself as a sub-agent."
                return false
            }
            guard agents.contains(where: { $0.id == member.childAgentID }) else {
                statusText = "One sub-agent no longer exists."
                return false
            }
            guard agents.first(where: { $0.id == member.childAgentID })?.enabled == true else {
                statusText = "Every sub-agent must be enabled."
                return false
            }
            let childWorkspaceIDs = agentWorkspaceIDs[member.childAgentID] ?? []
            guard !childWorkspaceIDs.intersection(draft.workspaceIDs).isEmpty else {
                statusText = "Every sub-agent must share at least one workspace with the orchestrator."
                return false
            }
        }

        return true
    }

    private func orchestrationMembers(from draft: AgentDraft, leadAgentID: Int64) -> [OrchestrationMember] {
        guard draft.kind == .orchestrator else { return [] }
        return draft.orchestrationMembers.map { member in
            OrchestrationMember(
                leadAgentID: leadAgentID,
                childAgentID: member.childAgentID,
                role: member.role,
                handoffPrompt: normalizeText(member.handoffPrompt)
            )
        }
    }
}

enum AppCommand: Equatable {
    case newSession
    case sendMessage
}
