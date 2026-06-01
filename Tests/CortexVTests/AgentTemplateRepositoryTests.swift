import XCTest
@testable import CortexV

final class AgentTemplateRepositoryTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testMigrationLinksExistingOpenRouterAgentsWithoutOverwritingSettings() throws {
        let root = try temporaryRoot()
        let database = SQLiteDatabase(path: root.appendingPathComponent("legacy.sqlite").path)
        try database.execute("""
            CREATE TABLE agents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                description TEXT,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                system_prompt TEXT NOT NULL,
                temperature REAL NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                base_url TEXT NOT NULL,
                api_key TEXT NOT NULL,
                kind TEXT NOT NULL
            )
            """)
        try insertLegacyAgent(
            database: database,
            id: 1,
            name: "Router Agent",
            baseURL: "HTTPS://OPENROUTER.AI/API/V1/",
            apiKey: "router-key",
            model: "anthropic/claude-sonnet-4",
            systemPrompt: "custom router prompt"
        )
        try insertLegacyAgent(
            database: database,
            id: 2,
            name: "Direct Agent",
            baseURL: "https://example.invalid/v1",
            apiKey: "direct-key",
            model: "direct-model",
            systemPrompt: "direct prompt"
        )

        let persistence = try PersistenceContainer(database: database)
        let templates = try persistence.agentTemplates.findAll()
        let agents = try persistence.agents.findAll()
        let routerAgent = try XCTUnwrap(agents.first { $0.id == 1 })
        let directAgent = try XCTUnwrap(agents.first { $0.id == 2 })
        let openRouterTemplate = try XCTUnwrap(templates.first { $0.name == "OpenRouter" })

        XCTAssertEqual(routerAgent.templateID, openRouterTemplate.id)
        XCTAssertNil(directAgent.templateID)
        XCTAssertEqual(routerAgent.apiKey, "router-key")
        XCTAssertEqual(routerAgent.model, "anthropic/claude-sonnet-4")
        XCTAssertEqual(routerAgent.systemPrompt, "custom router prompt")
        XCTAssertEqual(openRouterTemplate.apiKey, "router-key")
        XCTAssertEqual(openRouterTemplate.defaultModel, "anthropic/claude-sonnet-4")
    }

    func testTemplateApplyPushesOnlySelectedFieldsToLinkedAgents() throws {
        let persistence = try makePersistence()
        let template = try persistence.agentTemplates.insert(
            name: "OpenRouter",
            description: "",
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "new-key",
            defaultModel: "new-model",
            systemPrompt: "new prompt",
            temperature: 0.9,
            kind: .orchestrator
        )
        let agent = try persistence.agents.insert(
            name: "Worker",
            description: "",
            baseURL: "https://old.example/v1",
            apiKey: "old-key",
            model: "old-model",
            systemPrompt: "old prompt",
            temperature: 0.2,
            status: .enabled,
            kind: .standard,
            templateID: template.id
        )

        let appliedCount = try persistence.agentTemplates.apply(template, fields: [.baseURL, .apiKey], to: [agent.id])
        let updated = try persistence.agents.find(id: agent.id)

        XCTAssertEqual(appliedCount, 1)
        XCTAssertEqual(updated.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(updated.apiKey, "new-key")
        XCTAssertEqual(updated.model, "old-model")
        XCTAssertEqual(updated.systemPrompt, "old prompt")
        XCTAssertEqual(updated.temperature, 0.2)
        XCTAssertEqual(updated.kind, .standard)
    }

    func testDeletingTemplateDetachesAgentsAndPreservesCopiedSettings() throws {
        let persistence = try makePersistence()
        let template = try persistence.agentTemplates.insert(
            name: "OpenRouter",
            description: "",
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "template-key",
            defaultModel: "template-model",
            systemPrompt: AgentPromptDefaults.standard,
            temperature: 0.2,
            kind: .standard
        )
        let agent = try persistence.agents.insert(
            name: "Linked",
            description: "",
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "copied-key",
            model: "copied-model",
            systemPrompt: "copied prompt",
            temperature: 0.7,
            status: .enabled,
            kind: .standard,
            templateID: template.id
        )

        try persistence.agentTemplates.deleteDetachingAgents(id: template.id)
        let updated = try persistence.agents.find(id: agent.id)

        XCTAssertTrue(try persistence.agentTemplates.findAll().isEmpty)
        XCTAssertNil(updated.templateID)
        XCTAssertEqual(updated.apiKey, "copied-key")
        XCTAssertEqual(updated.model, "copied-model")
        XCTAssertEqual(updated.systemPrompt, "copied prompt")
        XCTAssertEqual(updated.temperature, 0.7)
    }

    private func makePersistence() throws -> PersistenceContainer {
        let root = try temporaryRoot()
        return try PersistenceContainer(database: SQLiteDatabase(path: root.appendingPathComponent("db.sqlite").path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexVAgentTemplateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func insertLegacyAgent(
        database: SQLiteDatabase,
        id: Int64,
        name: String,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String
    ) throws {
        try database.execute("""
            INSERT INTO agents (id, name, description, provider, model, system_prompt, temperature, status, created_at, updated_at, base_url, api_key, kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [
                .int(id),
                .text(name),
                .text(""),
                .text("OpenAI-compatible"),
                .text(model),
                .text(systemPrompt),
                .double(0.2),
                .text(AgentStatus.enabled.rawValue),
                .text("2026-01-01T00:00:00Z"),
                .text("2026-01-01T00:00:00Z"),
                .text(baseURL),
                .text(apiKey),
                .text(AgentKind.standard.rawValue)
            ])
    }
}
