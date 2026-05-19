import Foundation

struct MessageRepository {
    let database: SQLiteDatabase

    func findBySessionID(_ sessionID: Int64) throws -> [Message] {
        try database.query("""
            SELECT id, session_id, role, content, timestamp
            FROM messages
            WHERE session_id = ?
            ORDER BY timestamp ASC, id ASC
            """, values: [.int(sessionID)], map: map)
    }

    func find(id: Int64) throws -> Message {
        let rows = try database.query(
            "SELECT id, session_id, role, content, timestamp FROM messages WHERE id = ?",
            values: [.int(id)],
            map: map
        )
        guard let message = rows.first else { throw SQLiteError.notFound("Message not found: \(id)") }
        return message
    }

    func insert(sessionID: Int64, role: String, content: String) throws -> Message {
        let id = try database.insert("""
            INSERT INTO messages (session_id, role, content, timestamp)
            VALUES (?, ?, ?, ?)
            """, values: [.int(sessionID), .text(role), .text(content), .date(Date())])
        return try find(id: id)
    }

    private func map(_ row: SQLiteStatement) throws -> Message {
        Message(
            id: row.int64(0),
            sessionID: row.int64(1),
            role: row.text(2),
            content: row.text(3),
            timestamp: row.date(4)
        )
    }
}
