import Foundation

struct WorkspaceRepository {
    let database: SQLiteDatabase

    func findAll() throws -> [Workspace] {
        try database.query("""
            SELECT id, name, root_path, include_patterns, exclude_patterns, allow_read, allow_write, git_enabled, created_at, updated_at
            FROM workspaces
            ORDER BY updated_at DESC
            """, map: map)
    }

    func find(id: Int64) throws -> Workspace {
        let rows = try database.query("""
            SELECT id, name, root_path, include_patterns, exclude_patterns, allow_read, allow_write, git_enabled, created_at, updated_at
            FROM workspaces
            WHERE id = ?
            """, values: [.int(id)], map: map)
        guard let workspace = rows.first else { throw SQLiteError.notFound("Workspace not found: \(id)") }
        return workspace
    }

    func insert(
        name: String,
        rootPath: String,
        includePatterns: String,
        excludePatterns: String,
        allowRead: Bool,
        allowWrite: Bool,
        gitEnabled: Bool
    ) throws -> Workspace {
        let now = Date()
        let id = try database.insert("""
            INSERT INTO workspaces (name, root_path, include_patterns, exclude_patterns, allow_read, allow_write, git_enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [
                .text(name),
                .text(rootPath),
                .text(includePatterns),
                .text(excludePatterns),
                .bool(allowRead),
                .bool(allowWrite),
                .bool(gitEnabled),
                .date(now),
                .date(now)
            ])
        return try find(id: id)
    }

    func update(_ workspace: Workspace) throws -> Workspace {
        try database.execute("""
            UPDATE workspaces
            SET name = ?,
                root_path = ?,
                include_patterns = ?,
                exclude_patterns = ?,
                allow_read = ?,
                allow_write = ?,
                git_enabled = ?,
                updated_at = ?
            WHERE id = ?
            """, values: [
                .text(workspace.name),
                .text(workspace.rootPath),
                .text(workspace.includePatterns),
                .text(workspace.excludePatterns),
                .bool(workspace.allowRead),
                .bool(workspace.allowWrite),
                .bool(workspace.gitEnabled),
                .date(Date()),
                .int(workspace.id)
            ])
        return try find(id: workspace.id)
    }

    func delete(id: Int64) throws {
        try database.transaction { transaction in
            try transaction.execute("UPDATE sessions SET workspace_id = NULL WHERE workspace_id = ?", values: [.int(id)])
            try transaction.execute("DELETE FROM agent_workspaces WHERE workspace_id = ?", values: [.int(id)])
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
            try transaction.execute("DELETE FROM workspaces WHERE id = ?", values: [.int(id)])
        }
    }

    private func map(_ row: SQLiteStatement) throws -> Workspace {
        Workspace(
            id: row.int64(0),
            name: row.text(1),
            rootPath: row.text(2),
            includePatterns: row.text(3),
            excludePatterns: row.text(4),
            allowRead: row.bool(5),
            allowWrite: row.bool(6),
            gitEnabled: row.bool(7),
            createdAt: row.date(8),
            updatedAt: row.date(9)
        )
    }
}
