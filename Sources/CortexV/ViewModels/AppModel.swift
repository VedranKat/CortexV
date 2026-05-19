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
    @Published var messages: [Message] = []
    @Published var toolCalls: [ToolCall] = []
    @Published var fileChanges: [FileChange] = []
    @Published var changeSetsByID: [Int64: ChangeSet] = [:]
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
            return AgentDraft(agent: agent, workspaceIDs: try persistence.agents.findWorkspaceIDs(agentID: agent.id))
        } catch {
            statusText = error.localizedDescription
            return AgentDraft(agent: agent, workspaceIDs: [])
        }
    }

    func workspaceDraft(for workspace: Workspace? = nil) -> WorkspaceDraft {
        workspace.map(WorkspaceDraft.init(workspace:)) ?? .new()
    }

    @discardableResult
    func saveAgent(_ draft: AgentDraft) -> Bool {
        guard let persistence else { return false }
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
                    systemPrompt: normalizePrompt(draft.systemPrompt),
                    temperature: clampedTemperature(draft.temperature),
                    status: draft.status,
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
                    systemPrompt: normalizePrompt(draft.systemPrompt),
                    temperature: clampedTemperature(draft.temperature),
                    status: draft.status
                )
            }
            try persistence.agents.replaceWorkspaceBindings(agentID: saved.id, workspaceIDs: Array(draft.workspaceIDs).sorted())
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
            changeSetsByID = [:]
            refreshAll(using: persistence)
            statusText = "Deleted session #\(selectedSessionID)."
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
        guard let persistence, let workspaceID else { return agents }
        do {
            return try agents.filter { agent in
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

    private func refreshAll(using persistence: PersistenceContainer) {
        do {
            sessions = try persistence.sessions.findAll()
            agents = try persistence.agents.findAll()
            workspaces = try persistence.workspaces.findAll()
            let pendingChanges = try sessions.reduce(0) { count, session in
                let changes = try persistence.fileChanges.findBySessionID(session.id)
                return count + changes.filter(\.pending).count
            }
            snapshot = DashboardSnapshot(
                sessionsCount: sessions.count,
                agentsCount: agents.count,
                workspacesCount: workspaces.count,
                pendingChangesCount: pendingChanges
            )
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
            return
        }
        do {
            messages = try persistence.messages.findBySessionID(selectedSessionID)
            toolCalls = try persistence.toolCalls.findBySessionID(selectedSessionID)
            fileChanges = try persistence.fileChanges.findBySessionID(selectedSessionID)
            let changeSets = try persistence.changeSets.findBySessionID(selectedSessionID)
            changeSetsByID = Dictionary(uniqueKeysWithValues: changeSets.map { ($0.id, $0) })
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

    private func normalizePrompt(_ value: String) -> String {
        let trimmed = normalizeText(value)
        return trimmed.isEmpty ? "You are a helpful coding agent." : trimmed
    }

    private func clampedTemperature(_ value: Double) -> Double {
        min(2.0, max(0.0, value))
    }

    private func normalizedRootPath(_ value: String) -> String {
        let trimmed = normalizeName(value, fallback: FileManager.default.homeDirectoryForCurrentUser.path)
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

enum AppCommand: Equatable {
    case newSession
    case sendMessage
}
