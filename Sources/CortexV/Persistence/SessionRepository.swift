import Foundation

struct SessionRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [Session] {
        try database.query("""
            SELECT id, agent_id, workspace_id, status, started_at, ended_at, summary
            FROM sessions
            ORDER BY started_at DESC
            """, map: map)
    }

    func find(id: Int64) throws -> Session {
        let rows = try database.query("""
            SELECT id, agent_id, workspace_id, status, started_at, ended_at, summary
            FROM sessions
            WHERE id = ?
            """, values: [.int(id)], map: map)
        guard let session = rows.first else { throw SQLiteError.notFound("Session not found: \(id)") }
        return session
    }

    func insert(agentID: Int64, workspaceID: Int64?, status: SessionStatus, summary: String) throws -> Session {
        let id = try database.insert("""
            INSERT INTO sessions (agent_id, workspace_id, status, started_at, ended_at, summary)
            VALUES (?, ?, ?, ?, ?, ?)
            """, values: [
                .int(agentID),
                workspaceID.map(SQLiteValue.int) ?? .null,
                .text(status.rawValue),
                .date(Date()),
                .null,
                .text(summary)
            ])
        return try find(id: id)
    }

    func updateSummary(id: Int64, summary: String) throws -> Session {
        try database.execute("UPDATE sessions SET summary = ? WHERE id = ?", values: [.text(summary), .int(id)])
        return try find(id: id)
    }

    func delete(id: Int64) throws {
        try database.transaction { transaction in
            try transaction.execute("DELETE FROM file_changes WHERE change_set_id IN (SELECT id FROM change_sets WHERE session_id = ?)", values: [.int(id)])
            try transaction.execute("DELETE FROM change_sets WHERE session_id = ?", values: [.int(id)])
            try transaction.execute("DELETE FROM tool_calls WHERE session_id = ?", values: [.int(id)])
            try transaction.execute("DELETE FROM messages WHERE session_id = ?", values: [.int(id)])
            try transaction.execute("DELETE FROM sessions WHERE id = ?", values: [.int(id)])
        }
    }

    private func map(_ row: SQLiteStatement) throws -> Session {
        Session(
            id: row.int64(0),
            agentID: row.int64(1),
            workspaceID: row.optionalInt64(2),
            status: SessionStatus(rawValue: row.text(3)) ?? .active,
            startedAt: row.date(4),
            endedAt: row.optionalDate(5),
            summary: row.text(6)
        )
    }
}
