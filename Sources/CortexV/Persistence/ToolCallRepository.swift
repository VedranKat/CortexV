import Foundation

struct ToolCallRepository {
    let database: SQLiteDatabase

    func findBySessionID(_ sessionID: Int64) throws -> [ToolCall] {
        try database.query("""
            SELECT id, session_id, tool_name, arguments_json, result_json, status, timestamp
            FROM tool_calls
            WHERE session_id = ?
            ORDER BY timestamp ASC, id ASC
            """, values: [.int(sessionID)], map: map)
    }

    func find(id: Int64) throws -> ToolCall {
        let rows = try database.query(
            "SELECT id, session_id, tool_name, arguments_json, result_json, status, timestamp FROM tool_calls WHERE id = ?",
            values: [.int(id)],
            map: map
        )
        guard let toolCall = rows.first else { throw SQLiteError.notFound("Tool call not found: \(id)") }
        return toolCall
    }

    func insert(sessionID: Int64, toolName: String, argumentsJSON: String, resultJSON: String, status: String) throws -> ToolCall {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "SUCCESS" : status
        let id = try database.insert("""
            INSERT INTO tool_calls (session_id, tool_name, arguments_json, result_json, status, timestamp)
            VALUES (?, ?, ?, ?, ?, ?)
            """, values: [
                .int(sessionID),
                .text(toolName),
                .text(argumentsJSON),
                .text(resultJSON),
                .text(normalizedStatus),
                .date(Date())
            ])
        return try find(id: id)
    }

    private func map(_ row: SQLiteStatement) throws -> ToolCall {
        ToolCall(
            id: row.int64(0),
            sessionID: row.int64(1),
            toolName: row.text(2),
            argumentsJSON: row.text(3),
            resultJSON: row.text(4),
            status: row.text(5),
            timestamp: row.date(6)
        )
    }
}
