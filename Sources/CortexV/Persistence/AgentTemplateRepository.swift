import Foundation

struct AgentTemplateRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [AgentTemplate] {
        try database.query("""
            SELECT id, name, description, base_url, api_key, default_model, system_prompt, temperature, kind, created_at, updated_at
            FROM agent_templates
            ORDER BY name COLLATE NOCASE
            """, map: map)
    }

    func find(id: Int64) throws -> AgentTemplate {
        let rows = try database.query("""
            SELECT id, name, description, base_url, api_key, default_model, system_prompt, temperature, kind, created_at, updated_at
            FROM agent_templates
            WHERE id = ?
            """, values: [.int(id)], map: map)
        guard let template = rows.first else { throw SQLiteError.notFound("Agent template not found: \(id)") }
        return template
    }

    func insert(
        name: String,
        description: String,
        baseURL: String,
        apiKey: String,
        defaultModel: String,
        systemPrompt: String,
        temperature: Double,
        kind: AgentKind
    ) throws -> AgentTemplate {
        let now = Date()
        let id = try database.insert("""
            INSERT INTO agent_templates (name, description, base_url, api_key, default_model, system_prompt, temperature, kind, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [
                .text(name),
                .text(description),
                .text(baseURL),
                .text(apiKey),
                .text(defaultModel),
                .text(systemPrompt),
                .double(temperature),
                .text(kind.rawValue),
                .date(now),
                .date(now)
            ])
        return try find(id: id)
    }

    func update(_ template: AgentTemplate) throws -> AgentTemplate {
        try database.execute("""
            UPDATE agent_templates
            SET name = ?,
                description = ?,
                base_url = ?,
                api_key = ?,
                default_model = ?,
                system_prompt = ?,
                temperature = ?,
                kind = ?,
                updated_at = ?
            WHERE id = ?
            """, values: [
                .text(template.name),
                .text(template.description),
                .text(template.baseURL),
                .text(template.apiKey),
                .text(template.defaultModel),
                .text(template.systemPrompt),
                .double(template.temperature),
                .text(template.kind.rawValue),
                .date(Date()),
                .int(template.id)
            ])
        return try find(id: template.id)
    }

    func deleteDetachingAgents(id: Int64) throws {
        try database.transaction { transaction in
            try transaction.execute("UPDATE agents SET template_id = NULL WHERE template_id = ?", values: [.int(id)])
            try transaction.execute("DELETE FROM agent_templates WHERE id = ?", values: [.int(id)])
        }
    }

    @discardableResult
    func apply(_ template: AgentTemplate, fields: Set<AgentTemplatePropagationField>, to agentIDs: [Int64]) throws -> Int {
        guard !fields.isEmpty, !agentIDs.isEmpty else { return 0 }
        let agentRepository = AgentRepository(database: database)
        let agents = try agentIDs
            .map { try agentRepository.find(id: $0) }
            .filter { $0.templateID == template.id }

        try database.transaction { transaction in
            for agent in agents {
                let updated = applying(template, fields: fields, to: agent)
                try updateAgent(updated, transaction: transaction)
                if fields.contains(.kind), updated.kind != .orchestrator {
                    try transaction.execute("DELETE FROM agent_orchestration_members WHERE lead_agent_id = ?", values: [.int(updated.id)])
                }
            }
        }

        return agents.count
    }

    private func applying(_ template: AgentTemplate, fields: Set<AgentTemplatePropagationField>, to agent: Agent) -> Agent {
        var updated = agent
        if fields.contains(.baseURL) {
            updated.baseURL = template.baseURL
        }
        if fields.contains(.apiKey) {
            updated.apiKey = template.apiKey
        }
        if fields.contains(.defaultModel) {
            updated.model = template.defaultModel
        }
        if fields.contains(.systemPrompt) {
            updated.systemPrompt = template.systemPrompt
        }
        if fields.contains(.temperature) {
            updated.temperature = template.temperature
        }
        if fields.contains(.kind) {
            updated.kind = template.kind
        }
        return updated
    }

    private func updateAgent(_ agent: Agent, transaction: SQLiteTransaction) throws {
        try transaction.execute("""
            UPDATE agents
            SET name = ?,
                description = ?,
                provider = ?,
                base_url = ?,
                api_key = ?,
                model = ?,
                system_prompt = ?,
                temperature = ?,
                status = ?,
                kind = ?,
                template_id = ?,
                updated_at = ?
            WHERE id = ?
            """, values: [
                .text(agent.name),
                .text(agent.description),
                .text("OpenAI-compatible"),
                .text(agent.baseURL),
                .text(agent.apiKey),
                .text(agent.model),
                .text(agent.systemPrompt),
                .double(agent.temperature),
                .text(agent.status.rawValue),
                .text(agent.kind.rawValue),
                agent.templateID.map(SQLiteValue.int) ?? .null,
                .date(Date()),
                .int(agent.id)
            ])
    }

    private func map(_ row: SQLiteStatement) throws -> AgentTemplate {
        AgentTemplate(
            id: row.int64(0),
            name: row.text(1),
            description: row.text(2),
            baseURL: row.text(3),
            apiKey: row.text(4),
            defaultModel: row.text(5),
            systemPrompt: row.text(6),
            temperature: row.double(7),
            kind: AgentKind(rawValue: row.text(8)) ?? .standard,
            createdAt: row.date(9),
            updatedAt: row.date(10)
        )
    }
}
