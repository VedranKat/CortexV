import Foundation

struct SessionRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [Session] {
        try database.query("""
            SELECT id, agent_id, workspace_id, parent_session_id, orchestration_role, status, started_at, ended_at, detached_at, summary
            FROM sessions
            ORDER BY started_at DESC
            """, map: map)
    }

    func find(id: Int64) throws -> Session {
        let rows = try database.query("""
            SELECT id, agent_id, workspace_id, parent_session_id, orchestration_role, status, started_at, ended_at, detached_at, summary
            FROM sessions
            WHERE id = ?
            """, values: [.int(id)], map: map)
        guard let session = rows.first else { throw SQLiteError.notFound("Session not found: \(id)") }
        return session
    }

    func findChildren(parentSessionID: Int64) throws -> [Session] {
        try database.query("""
            SELECT id, agent_id, workspace_id, parent_session_id, orchestration_role, status, started_at, ended_at, detached_at, summary
            FROM sessions
            WHERE parent_session_id = ?
            ORDER BY started_at DESC, id DESC
            """, values: [.int(parentSessionID)], map: map)
    }

    func insert(
        agentID: Int64,
        workspaceID: Int64?,
        parentSessionID: Int64? = nil,
        orchestrationRole: OrchestrationRole? = nil,
        status: SessionStatus,
        summary: String
    ) throws -> Session {
        let id = try database.insert("""
            INSERT INTO sessions (agent_id, workspace_id, parent_session_id, orchestration_role, status, started_at, ended_at, detached_at, summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [
                .int(agentID),
                workspaceID.map(SQLiteValue.int) ?? .null,
                parentSessionID.map(SQLiteValue.int) ?? .null,
                orchestrationRole.map { .text($0.rawValue) } ?? .null,
                .text(status.rawValue),
                .date(Date()),
                .null,
                .null,
                .text(summary)
            ])
        return try find(id: id)
    }

    func updateSummary(id: Int64, summary: String) throws -> Session {
        try database.execute("UPDATE sessions SET summary = ? WHERE id = ?", values: [.text(summary), .int(id)])
        return try find(id: id)
    }

    func updateStatus(id: Int64, status: SessionStatus) throws -> Session {
        try database.execute("""
            UPDATE sessions
            SET status = ?,
                ended_at = ?
            WHERE id = ?
            """, values: [
                .text(status.rawValue),
                status == .active ? .null : .date(Date()),
                .int(id)
            ])
        return try find(id: id)
    }

    func detach(id: Int64) throws -> Session {
        let session = try find(id: id)
        guard session.parentSessionID != nil else { return session }
        try database.execute("""
            UPDATE sessions
            SET detached_at = ?,
                status = ?,
                ended_at = NULL
            WHERE id = ?
            """, values: [
                .date(Date()),
                .text(SessionStatus.active.rawValue),
                .int(id)
            ])
        return try find(id: id)
    }

    func delete(id: Int64) throws {
        let childIDs = try database.query(
            "SELECT id FROM sessions WHERE parent_session_id = ? AND detached_at IS NULL",
            values: [.int(id)]
        ) { row in
            row.int64(0)
        }
        for childID in childIDs {
            try delete(id: childID)
        }

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
            parentSessionID: row.optionalInt64(3),
            orchestrationRole: row.optionalText(4).flatMap(OrchestrationRole.init(rawValue:)),
            status: SessionStatus(rawValue: row.text(5)) ?? .active,
            startedAt: row.date(6),
            endedAt: row.optionalDate(7),
            detachedAt: row.optionalDate(8),
            summary: row.text(9)
        )
    }
}
