import Foundation

struct AgentRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [Agent] {
        try database.query("""
            SELECT id, name, description, base_url, api_key, model, system_prompt, temperature, status, kind, created_at, updated_at
            FROM agents
            ORDER BY updated_at DESC
            """, map: map)
    }

    func find(id: Int64) throws -> Agent {
        let rows = try database.query("""
            SELECT id, name, description, base_url, api_key, model, system_prompt, temperature, status, kind, created_at, updated_at
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
        status: AgentStatus,
        kind: AgentKind
    ) throws -> Agent {
        let now = Date()
        let id = try database.insert("""
            INSERT INTO agents (name, description, provider, base_url, api_key, model, system_prompt, temperature, status, kind, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                .text(kind.rawValue),
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
                kind = ?,
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
            try cleanupStaleOrchestrationMembers(transaction: transaction)
        }
    }

    func findOrchestrationMembers(leadAgentID: Int64) throws -> [OrchestrationMember] {
        try database.query("""
            SELECT lead_agent_id, child_agent_id, role, handoff_prompt
            FROM agent_orchestration_members
            WHERE lead_agent_id = ?
            ORDER BY role, child_agent_id
            """, values: [.int(leadAgentID)], map: mapOrchestrationMember)
    }

    func findAllOrchestrationMembers() throws -> [OrchestrationMember] {
        try database.query("""
            SELECT lead_agent_id, child_agent_id, role, handoff_prompt
            FROM agent_orchestration_members
            ORDER BY lead_agent_id, role, child_agent_id
            """, map: mapOrchestrationMember)
    }

    func replaceOrchestrationMembers(leadAgentID: Int64, members: [OrchestrationMember]) throws {
        try database.transaction { transaction in
            let now = Date()
            try transaction.execute("DELETE FROM agent_orchestration_members WHERE lead_agent_id = ?", values: [.int(leadAgentID)])
            for member in members {
                try transaction.execute("""
                    INSERT INTO agent_orchestration_members (lead_agent_id, child_agent_id, role, handoff_prompt, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, values: [
                        .int(leadAgentID),
                        .int(member.childAgentID),
                        .text(member.role.rawValue),
                        .text(member.handoffPrompt),
                        .date(now),
                        .date(now)
                    ])
            }
        }
    }

    func delete(id: Int64) throws {
        let sessionIDs = try sessionTreeIDs(startingWith: database.query(
            "SELECT id FROM sessions WHERE agent_id = ?",
            values: [.int(id)]
        ) { row in
            row.int64(0)
        })

        try database.transaction { transaction in
            try transaction.execute("DELETE FROM agent_orchestration_members WHERE lead_agent_id = ? OR child_agent_id = ?", values: [.int(id), .int(id)])
            for sessionID in sessionIDs {
                try transaction.execute("DELETE FROM file_changes WHERE change_set_id IN (SELECT id FROM change_sets WHERE session_id = ?)", values: [.int(sessionID)])
                try transaction.execute("DELETE FROM change_sets WHERE session_id = ?", values: [.int(sessionID)])
                try transaction.execute("DELETE FROM tool_calls WHERE session_id = ?", values: [.int(sessionID)])
                try transaction.execute("DELETE FROM messages WHERE session_id = ?", values: [.int(sessionID)])
            }
            for sessionID in sessionIDs.sorted(by: >) {
                try transaction.execute("DELETE FROM sessions WHERE id = ?", values: [.int(sessionID)])
            }
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
            kind: AgentKind(rawValue: row.text(9)) ?? .standard,
            createdAt: row.date(10),
            updatedAt: row.date(11)
        )
    }

    private func mapOrchestrationMember(_ row: SQLiteStatement) throws -> OrchestrationMember {
        OrchestrationMember(
            leadAgentID: row.int64(0),
            childAgentID: row.int64(1),
            role: OrchestrationRole(rawValue: row.text(2)) ?? .scout,
            handoffPrompt: row.text(3)
        )
    }

    private func sessionTreeIDs(startingWith rootIDs: [Int64]) throws -> Set<Int64> {
        var result = Set(rootIDs)
        var frontier = rootIDs
        while !frontier.isEmpty {
            var next: [Int64] = []
            for sessionID in frontier {
                let childIDs = try database.query(
                    "SELECT id FROM sessions WHERE parent_session_id = ? AND detached_at IS NULL",
                    values: [.int(sessionID)]
                ) { row in
                    row.int64(0)
                }
                for childID in childIDs where !result.contains(childID) {
                    result.insert(childID)
                    next.append(childID)
                }
            }
            frontier = next
        }
        return result
    }

    private func cleanupStaleOrchestrationMembers(transaction: SQLiteTransaction) throws {
        try transaction.execute("""
            DELETE FROM agent_orchestration_members
            WHERE NOT EXISTS (
                SELECT 1
                FROM agent_workspaces lead_ws
                JOIN agent_workspaces child_ws
                    ON child_ws.workspace_id = lead_ws.workspace_id
                WHERE lead_ws.agent_id = agent_orchestration_members.lead_agent_id
                    AND child_ws.agent_id = agent_orchestration_members.child_agent_id
            )
            """)
    }
}
