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
    var workspaceIDs: Set<Int64>

    var identity: String { id.map(String.init) ?? "new" }

    static func new() -> AgentDraft {
        AgentDraft(
            id: nil,
            name: "New Agent",
            description: "Desktop coding agent",
            baseURL: "",
            apiKey: "",
            model: "",
            systemPrompt: "You are a helpful coding agent.",
            temperature: 0.2,
            status: .enabled,
            workspaceIDs: []
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
        workspaceIDs: Set<Int64>
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
        self.workspaceIDs = workspaceIDs
    }

    init(agent: Agent, workspaceIDs: [Int64]) {
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
            workspaceIDs: Set(workspaceIDs)
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
