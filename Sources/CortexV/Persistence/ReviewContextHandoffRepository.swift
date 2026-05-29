import Foundation

struct ReviewContextHandoffRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [ReviewContextHandoff] {
        try database.query("""
            SELECT id, source_session_id, target_session_id, status, payload_hash, sent_at, created_at
            FROM review_context_handoffs
            ORDER BY created_at DESC, id DESC
            """, map: map)
    }

    func findBySourceSessionID(_ sourceSessionID: Int64) throws -> [ReviewContextHandoff] {
        try database.query("""
            SELECT id, source_session_id, target_session_id, status, payload_hash, sent_at, created_at
            FROM review_context_handoffs
            WHERE source_session_id = ?
            ORDER BY created_at DESC, id DESC
            """, values: [.int(sourceSessionID)], map: map)
    }

    func findLatest(sourceSessionID: Int64, targetSessionID: Int64) throws -> ReviewContextHandoff? {
        try database.query("""
            SELECT id, source_session_id, target_session_id, status, payload_hash, sent_at, created_at
            FROM review_context_handoffs
            WHERE source_session_id = ?
                AND target_session_id = ?
            ORDER BY created_at DESC, id DESC
            LIMIT 1
            """, values: [.int(sourceSessionID), .int(targetSessionID)], map: map)
        .first
    }

    func insert(
        sourceSessionID: Int64,
        targetSessionID: Int64,
        status: String = "SENT",
        payloadHash: String,
        sentAt: Date? = Date()
    ) throws -> ReviewContextHandoff {
        let createdAt = Date()
        let id = try database.insert("""
            INSERT INTO review_context_handoffs (source_session_id, target_session_id, status, payload_hash, sent_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, values: [
                .int(sourceSessionID),
                .int(targetSessionID),
                .text(status.isEmpty ? "SENT" : status),
                .text(payloadHash),
                sentAt.map(SQLiteValue.date) ?? .null,
                .date(createdAt)
            ])
        return try find(id: id)
    }

    private func find(id: Int64) throws -> ReviewContextHandoff {
        let rows = try database.query("""
            SELECT id, source_session_id, target_session_id, status, payload_hash, sent_at, created_at
            FROM review_context_handoffs
            WHERE id = ?
            """, values: [.int(id)], map: map)
        guard let handoff = rows.first else { throw SQLiteError.notFound("Review context handoff not found: \(id)") }
        return handoff
    }

    private func map(_ row: SQLiteStatement) throws -> ReviewContextHandoff {
        ReviewContextHandoff(
            id: row.int64(0),
            sourceSessionID: row.int64(1),
            targetSessionID: row.int64(2),
            status: row.text(3),
            payloadHash: row.text(4),
            sentAt: row.optionalDate(5),
            createdAt: row.date(6)
        )
    }
}
