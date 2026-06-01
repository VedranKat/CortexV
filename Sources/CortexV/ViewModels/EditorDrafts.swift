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
    var templateID: Int64?
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
            templateID: nil,
            workspaceIDs: [],
            orchestrationMembers: []
        )
    }

    static func new(template: AgentTemplate) -> AgentDraft {
        AgentDraft(
            id: nil,
            name: "\(template.name) Agent",
            description: template.description.isEmpty ? "Agent created from \(template.name)" : template.description,
            baseURL: template.baseURL,
            apiKey: template.apiKey,
            model: template.defaultModel,
            systemPrompt: template.systemPrompt,
            temperature: template.temperature,
            status: .enabled,
            kind: template.kind,
            templateID: template.id,
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
        templateID: Int64?,
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
        self.templateID = templateID
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
            templateID: agent.templateID,
            workspaceIDs: Set(workspaceIDs),
            orchestrationMembers: orchestrationMembers.map(OrchestrationMemberDraft.init(member:))
        )
    }
}

struct AgentTemplateDraft: Identifiable, Equatable {
    var id: Int64?
    var name: String
    var description: String
    var baseURL: String
    var apiKey: String
    var defaultModel: String
    var systemPrompt: String
    var temperature: Double
    var kind: AgentKind

    var identity: String { id.map(String.init) ?? "new" }

    static func new() -> AgentTemplateDraft {
        AgentTemplateDraft(
            id: nil,
            name: "OpenRouter",
            description: "OpenAI-compatible routing through OpenRouter.",
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "",
            defaultModel: "",
            systemPrompt: AgentPromptDefaults.standard,
            temperature: 0.2,
            kind: .standard
        )
    }

    init(
        id: Int64?,
        name: String,
        description: String,
        baseURL: String,
        apiKey: String,
        defaultModel: String,
        systemPrompt: String,
        temperature: Double,
        kind: AgentKind
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.kind = kind
    }

    init(template: AgentTemplate) {
        self.init(
            id: template.id,
            name: template.name,
            description: template.description,
            baseURL: template.baseURL,
            apiKey: template.apiKey,
            defaultModel: template.defaultModel,
            systemPrompt: template.systemPrompt,
            temperature: template.temperature,
            kind: template.kind
        )
    }

    init(agent: Agent) {
        self.init(
            id: nil,
            name: Self.templateName(from: agent),
            description: agent.description,
            baseURL: agent.baseURL,
            apiKey: agent.apiKey,
            defaultModel: agent.model,
            systemPrompt: agent.systemPrompt,
            temperature: agent.temperature,
            kind: agent.kind
        )
    }

    private static func templateName(from agent: Agent) -> String {
        let trimmed = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Template" : "\(trimmed) Template"
    }
}

struct AgentTemplatePropagationDraft: Identifiable, Equatable {
    var id = UUID()
    var templateID: Int64
    var fields: Set<AgentTemplatePropagationField>
    var agentIDs: Set<Int64>
    var candidateAgentIDs: [Int64]

    static func new(templateID: Int64, candidateAgentIDs: [Int64]) -> AgentTemplatePropagationDraft {
        AgentTemplatePropagationDraft(
            templateID: templateID,
            fields: Set(AgentTemplatePropagationField.allCases),
            agentIDs: Set(candidateAgentIDs),
            candidateAgentIDs: candidateAgentIDs
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
