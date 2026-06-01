import Foundation

struct PersistenceContainer {
    let database: SQLiteDatabase
    let agents: AgentRepository
    let agentTemplates: AgentTemplateRepository
    let workspaces: WorkspaceRepository
    let sessions: SessionRepository
    let messages: MessageRepository
    let toolCalls: ToolCallRepository
    let changeSets: ChangeSetRepository
    let fileChanges: FileChangeRepository
    let reviewContextHandoffs: ReviewContextHandoffRepository

    init(database: SQLiteDatabase = SQLiteDatabase()) throws {
        self.database = database
        try SchemaInitializer(database: database).initialize()
        self.agents = AgentRepository(database: database)
        self.agentTemplates = AgentTemplateRepository(database: database)
        self.workspaces = WorkspaceRepository(database: database)
        self.sessions = SessionRepository(database: database)
        self.messages = MessageRepository(database: database)
        self.toolCalls = ToolCallRepository(database: database)
        self.changeSets = ChangeSetRepository(database: database)
        self.fileChanges = FileChangeRepository(database: database)
        self.reviewContextHandoffs = ReviewContextHandoffRepository(database: database)
    }
}
