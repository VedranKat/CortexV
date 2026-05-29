import Foundation

struct SchemaInitializer {
    let database: SQLiteDatabase

    func initialize() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS agents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                description TEXT,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                system_prompt TEXT NOT NULL,
                temperature REAL NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """)
        try ensureColumn(table: "agents", column: "base_url", definition: "TEXT NOT NULL DEFAULT 'https://api.openai.com/v1'")
        try ensureColumn(table: "agents", column: "api_key", definition: "TEXT NOT NULL DEFAULT ''")
        try ensureColumn(table: "agents", column: "kind", definition: "TEXT NOT NULL DEFAULT 'STANDARD'")

        try database.execute("""
            CREATE TABLE IF NOT EXISTS workspaces (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                root_path TEXT NOT NULL,
                include_patterns TEXT NOT NULL,
                exclude_patterns TEXT NOT NULL,
                allow_read INTEGER NOT NULL,
                allow_write INTEGER NOT NULL,
                git_enabled INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS agent_workspaces (
                agent_id INTEGER NOT NULL,
                workspace_id INTEGER NOT NULL,
                PRIMARY KEY (agent_id, workspace_id),
                FOREIGN KEY (agent_id) REFERENCES agents(id),
                FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS agent_orchestration_members (
                lead_agent_id INTEGER NOT NULL,
                child_agent_id INTEGER NOT NULL,
                role TEXT NOT NULL,
                handoff_prompt TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (lead_agent_id, child_agent_id, role),
                FOREIGN KEY (lead_agent_id) REFERENCES agents(id),
                FOREIGN KEY (child_agent_id) REFERENCES agents(id)
            )
            """)
        try migrateOrchestrationMemberPrimaryKey()
        try database.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                agent_id INTEGER NOT NULL,
                workspace_id INTEGER,
                parent_session_id INTEGER,
                orchestration_role TEXT,
                status TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                detached_at TEXT,
                summary TEXT
            )
            """)
        try ensureColumn(table: "sessions", column: "parent_session_id", definition: "INTEGER")
        try ensureColumn(table: "sessions", column: "orchestration_role", definition: "TEXT")
        try ensureColumn(table: "sessions", column: "detached_at", definition: "TEXT")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp TEXT NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS tool_calls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                tool_name TEXT NOT NULL,
                arguments_json TEXT,
                result_json TEXT,
                status TEXT NOT NULL,
                timestamp TEXT NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS change_sets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                workspace_id INTEGER,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
        try ensureColumn(table: "change_sets", column: "workspace_id", definition: "INTEGER")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS file_changes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                change_set_id INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                old_content TEXT,
                base_content_exists INTEGER NOT NULL DEFAULT 1,
                new_content TEXT,
                diff_text TEXT,
                status TEXT NOT NULL
            )
            """)
        let addedBaseContentExists = try ensureColumn(table: "file_changes", column: "base_content_exists", definition: "INTEGER NOT NULL DEFAULT 1")
        if addedBaseContentExists {
            try migrateLegacyFileChangeBaseContentFlags()
        }
    }

    @discardableResult
    private func ensureColumn(table: String, column: String, definition: String) throws -> Bool {
        let columns = try database.query("PRAGMA table_info('\(table)')") { row in
            row.text(1)
        }
        if !columns.contains(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) {
            try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
            return true
        }
        return false
    }

    private func migrateLegacyFileChangeBaseContentFlags() throws {
        try database.execute("""
            UPDATE file_changes
            SET base_content_exists = 0
            WHERE status = 'PENDING'
                AND (old_content IS NULL OR old_content = '')
            """)
    }

    private func migrateOrchestrationMemberPrimaryKey() throws {
        let primaryKeyColumns = try database.query("PRAGMA table_info('agent_orchestration_members')") { row -> String? in
            row.int64(5) > 0 ? row.text(1) : nil
        }.compactMap { $0 }
        guard primaryKeyColumns == ["lead_agent_id", "child_agent_id"] else { return }

        try database.transaction { transaction in
            try transaction.execute("ALTER TABLE agent_orchestration_members RENAME TO agent_orchestration_members_old")
            try transaction.execute("""
                CREATE TABLE agent_orchestration_members (
                    lead_agent_id INTEGER NOT NULL,
                    child_agent_id INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    handoff_prompt TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (lead_agent_id, child_agent_id, role),
                    FOREIGN KEY (lead_agent_id) REFERENCES agents(id),
                    FOREIGN KEY (child_agent_id) REFERENCES agents(id)
                )
                """)
            try transaction.execute("""
                INSERT OR IGNORE INTO agent_orchestration_members (lead_agent_id, child_agent_id, role, handoff_prompt, created_at, updated_at)
                SELECT lead_agent_id, child_agent_id, role, handoff_prompt, created_at, updated_at
                FROM agent_orchestration_members_old
                """)
            try transaction.execute("DROP TABLE agent_orchestration_members_old")
        }
    }
}
