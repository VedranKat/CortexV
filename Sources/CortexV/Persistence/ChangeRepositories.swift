import Foundation

struct ChangeSetRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [ChangeSet] {
        try database.query("""
            SELECT id, session_id, workspace_id, status, created_at
            FROM change_sets
            ORDER BY created_at DESC, id DESC
            """, map: map)
    }

    func findBySessionID(_ sessionID: Int64) throws -> [ChangeSet] {
        try database.query("""
            SELECT id, session_id, workspace_id, status, created_at
            FROM change_sets
            WHERE session_id = ?
            ORDER BY created_at DESC, id DESC
            """, values: [.int(sessionID)], map: map)
    }

    func find(id: Int64) throws -> ChangeSet {
        let rows = try database.query(
            "SELECT id, session_id, workspace_id, status, created_at FROM change_sets WHERE id = ?",
            values: [.int(id)],
            map: map
        )
        guard let changeSet = rows.first else { throw SQLiteError.notFound("Change set not found: \(id)") }
        return changeSet
    }

    func insert(sessionID: Int64, workspaceID: Int64?, status: String = "PENDING") throws -> ChangeSet {
        let id = try database.insert("""
            INSERT INTO change_sets (session_id, workspace_id, status, created_at)
            VALUES (?, ?, ?, ?)
            """, values: [
                .int(sessionID),
                workspaceID.map(SQLiteValue.int) ?? .null,
                .text(status.isEmpty ? "PENDING" : status),
                .date(Date())
            ])
        return try find(id: id)
    }

    func updateStatus(id: Int64, status: String) throws {
        try database.execute("UPDATE change_sets SET status = ? WHERE id = ?", values: [.text(status), .int(id)])
    }

    private func map(_ row: SQLiteStatement) throws -> ChangeSet {
        ChangeSet(
            id: row.int64(0),
            sessionID: row.int64(1),
            workspaceID: row.optionalInt64(2),
            status: row.text(3),
            createdAt: row.date(4)
        )
    }
}

struct FileChangeRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [FileChange] {
        try database.query("""
            SELECT fc.id, fc.change_set_id, fc.file_path, fc.old_content, fc.base_content_exists, fc.new_content, fc.diff_text, fc.status
            FROM file_changes fc
            JOIN change_sets cs ON cs.id = fc.change_set_id
            ORDER BY cs.created_at DESC, fc.id DESC
            """, map: map)
    }

    func findBySessionID(_ sessionID: Int64) throws -> [FileChange] {
        try database.query("""
            SELECT fc.id, fc.change_set_id, fc.file_path, fc.old_content, fc.base_content_exists, fc.new_content, fc.diff_text, fc.status
            FROM file_changes fc
            JOIN change_sets cs ON cs.id = fc.change_set_id
            WHERE cs.session_id = ?
            ORDER BY cs.created_at DESC, fc.id DESC
            """, values: [.int(sessionID)], map: map)
    }

    func findByChangeSetID(_ changeSetID: Int64) throws -> [FileChange] {
        try database.query("""
            SELECT id, change_set_id, file_path, old_content, base_content_exists, new_content, diff_text, status
            FROM file_changes
            WHERE change_set_id = ?
            ORDER BY id ASC
            """, values: [.int(changeSetID)], map: map)
    }

    func find(id: Int64) throws -> FileChange {
        let rows = try database.query("""
            SELECT id, change_set_id, file_path, old_content, base_content_exists, new_content, diff_text, status
            FROM file_changes
            WHERE id = ?
            """, values: [.int(id)], map: map)
        guard let fileChange = rows.first else { throw SQLiteError.notFound("File change not found: \(id)") }
        return fileChange
    }

    func insert(
        changeSetID: Int64,
        filePath: String,
        oldContent: String,
        baseContentExists: Bool,
        newContent: String,
        diffText: String,
        status: String = "PENDING"
    ) throws -> FileChange {
        let id = try database.insert("""
            INSERT INTO file_changes (change_set_id, file_path, old_content, base_content_exists, new_content, diff_text, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, values: [
                .int(changeSetID),
                .text(filePath),
                .text(oldContent),
                .bool(baseContentExists),
                .text(newContent),
                .text(diffText),
                .text(status.isEmpty ? "PENDING" : status)
            ])
        return try find(id: id)
    }

    func updateStatus(id: Int64, status: String) throws {
        try database.execute("UPDATE file_changes SET status = ? WHERE id = ?", values: [.text(status), .int(id)])
    }

    private func map(_ row: SQLiteStatement) throws -> FileChange {
        FileChange(
            id: row.int64(0),
            changeSetID: row.int64(1),
            filePath: row.text(2),
            oldContent: row.text(3),
            baseContentExists: row.bool(4),
            newContent: row.text(5),
            diffText: row.text(6),
            status: row.text(7)
        )
    }
}
