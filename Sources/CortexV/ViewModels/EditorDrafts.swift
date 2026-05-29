import Foundation

struct AgentDraft: Identifiable, Equatable {
    var id: Int64?
    var name: String
    var description: String
    var baseURL: String
    var apiKey: String
    var model: String
    var systemPrompt: String
    var temperature: Double
    var status: AgentStatus
    var kind: AgentKind
    var workspaceIDs: Set<Int64>
    var orchestrationMembers: [OrchestrationMemberDraft]

    var identity: String { id.map(String.init) ?? "new" }

    static func new() -> AgentDraft {
        AgentDraft(
            id: nil,
            name: "New Agent",
            description: "Desktop coding agent",
            baseURL: "",
            apiKey: "",
            model: "",
            systemPrompt: AgentPromptDefaults.standard,
            temperature: 0.2,
            status: .enabled,
            kind: .standard,
            workspaceIDs: [],
            orchestrationMembers: []
        )
    }

    init(
        id: Int64?,
        name: String,
        description: String,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        temperature: Double,
        status: AgentStatus,
        kind: AgentKind,
        workspaceIDs: Set<Int64>,
        orchestrationMembers: [OrchestrationMemberDraft]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.status = status
        self.kind = kind
        self.workspaceIDs = workspaceIDs
        self.orchestrationMembers = orchestrationMembers
    }

    init(agent: Agent, workspaceIDs: [Int64], orchestrationMembers: [OrchestrationMember]) {
        self.init(
            id: agent.id,
            name: agent.name,
            description: agent.description,
            baseURL: agent.baseURL,
            apiKey: agent.apiKey,
            model: agent.model,
            systemPrompt: agent.systemPrompt,
            temperature: agent.temperature,
            status: agent.status,
            kind: agent.kind,
            workspaceIDs: Set(workspaceIDs),
            orchestrationMembers: orchestrationMembers.map(OrchestrationMemberDraft.init(member:))
        )
    }
}

struct OrchestrationMemberDraft: Identifiable, Equatable {
    var id = UUID()
    var childAgentID: Int64
    var role: OrchestrationRole
    var handoffPrompt: String

    var effectivePrompt: String {
        let trimmed = handoffPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.defaultHandoffPrompt : trimmed
    }

    init(childAgentID: Int64, role: OrchestrationRole = .scout, handoffPrompt: String = "") {
        self.childAgentID = childAgentID
        self.role = role
        self.handoffPrompt = handoffPrompt
    }

    init(member: OrchestrationMember) {
        self.init(
            childAgentID: member.childAgentID,
            role: member.role,
            handoffPrompt: member.handoffPrompt
        )
    }
}

struct WorkspaceDraft: Identifiable, Equatable {
    var id: Int64?
    var name: String
    var rootPath: String
    var includePatterns: String
    var excludePatterns: String
    var allowRead: Bool
    var allowWrite: Bool
    var gitEnabled: Bool

    var identity: String { id.map(String.init) ?? "new" }

    static func new(defaultRoot: String = FileManager.default.homeDirectoryForCurrentUser.path) -> WorkspaceDraft {
        WorkspaceDraft(
            id: nil,
            name: "New Workspace",
            rootPath: defaultRoot,
            includePatterns: "**/*",
            excludePatterns: ".git/**,target/**,build/**",
            allowRead: true,
            allowWrite: false,
            gitEnabled: true
        )
    }

    init(
        id: Int64?,
        name: String,
        rootPath: String,
        includePatterns: String,
        excludePatterns: String,
        allowRead: Bool,
        allowWrite: Bool,
        gitEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.includePatterns = includePatterns
        self.excludePatterns = excludePatterns
        self.allowRead = allowRead
        self.allowWrite = allowWrite
        self.gitEnabled = gitEnabled
    }

    init(workspace: Workspace) {
        self.init(
            id: workspace.id,
            name: workspace.name,
            rootPath: workspace.rootPath,
            includePatterns: workspace.includePatterns,
            excludePatterns: workspace.excludePatterns,
            allowRead: workspace.allowRead,
            allowWrite: workspace.allowWrite,
            gitEnabled: workspace.gitEnabled
        )
    }
}
