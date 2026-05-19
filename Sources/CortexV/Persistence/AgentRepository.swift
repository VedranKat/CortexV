import Foundation

struct AgentRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [Agent] {
        try database.query("""
            SELECT id, name, description, base_url, api_key, model, system_prompt, temperature, status, created_at, updated_at
            FROM agents
            ORDER BY updated_at DESC
            """, map: map)
    }

    func find(id: Int64) throws -> Agent {
        let rows = try database.query("""
            SELECT id, name, description, base_url, api_key, model, system_prompt, temperature, status, created_at, updated_at
            FROM agents
            WHERE id = ?
            """, values: [.int(id)], map: map)
        guard let agent = rows.first else { throw SQLiteError.notFound("Agent not found: \(id)") }
        return agent
    }

    func insert(
        name: String,
        description: String,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        temperature: Double,
        status: AgentStatus
    ) throws -> Agent {
        let now = Date()
        let id = try database.insert("""
            INSERT INTO agents (name, description, provider, base_url, api_key, model, system_prompt, temperature, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [
                .text(name),
                .text(description),
                .text("OpenAI-compatible"),
                .text(baseURL),
                .text(apiKey),
                .text(model),
                .text(systemPrompt),
                .double(temperature),
                .text(status.rawValue),
                .date(now),
                .date(now)
            ])
        return try find(id: id)
    }

    func update(_ agent: Agent) throws -> Agent {
        try database.execute("""
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
                .date(Date()),
                .int(agent.id)
            ])
        return try find(id: agent.id)
    }

    func findWorkspaceIDs(agentID: Int64) throws -> [Int64] {
        try database.query(
            "SELECT workspace_id FROM agent_workspaces WHERE agent_id = ? ORDER BY workspace_id",
            values: [.int(agentID)]
        ) { row in
            row.int64(0)
        }
    }

    func replaceWorkspaceBindings(agentID: Int64, workspaceIDs: [Int64]) throws {
        try database.transaction { transaction in
            try transaction.execute("DELETE FROM agent_workspaces WHERE agent_id = ?", values: [.int(agentID)])
            for workspaceID in workspaceIDs {
                try transaction.execute(
                    "INSERT INTO agent_workspaces (agent_id, workspace_id) VALUES (?, ?)",
                    values: [.int(agentID), .int(workspaceID)]
                )
            }
        }
    }

    func delete(id: Int64) throws {
        try database.transaction { transaction in
            try transaction.execute("DELETE FROM file_changes WHERE change_set_id IN (SELECT id FROM change_sets WHERE session_id IN (SELECT id FROM sessions WHERE agent_id = ?))", values: [.int(id)])
            try transaction.execute("DELETE FROM change_sets WHERE session_id IN (SELECT id FROM sessions WHERE agent_id = ?)", values: [.int(id)])
            try transaction.execute("DELETE FROM tool_calls WHERE session_id IN (SELECT id FROM sessions WHERE agent_id = ?)", values: [.int(id)])
            try transaction.execute("DELETE FROM messages WHERE session_id IN (SELECT id FROM sessions WHERE agent_id = ?)", values: [.int(id)])
            try transaction.execute("DELETE FROM sessions WHERE agent_id = ?", values: [.int(id)])
            try transaction.execute("DELETE FROM agent_workspaces WHERE agent_id = ?", values: [.int(id)])
            try transaction.execute("DELETE FROM agents WHERE id = ?", values: [.int(id)])
        }
    }

    private func map(_ row: SQLiteStatement) throws -> Agent {
        Agent(
            id: row.int64(0),
            name: row.text(1),
            description: row.text(2),
            baseURL: row.text(3),
            apiKey: row.text(4),
            model: row.text(5),
            systemPrompt: row.text(6),
            temperature: row.double(7),
            status: AgentStatus(rawValue: row.text(8)) ?? .disabled,
            createdAt: row.date(9),
            updatedAt: row.date(10)
        )
    }
}
