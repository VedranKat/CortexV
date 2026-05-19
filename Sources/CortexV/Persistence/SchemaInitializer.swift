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
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                agent_id INTEGER NOT NULL,
                workspace_id INTEGER,
                status TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                summary TEXT
            )
            """)
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
                new_content TEXT,
                diff_text TEXT,
                status TEXT NOT NULL
            )
            """)
    }

    private func ensureColumn(table: String, column: String, definition: String) throws {
        let columns = try database.query("PRAGMA table_info('\(table)')") { row in
            row.text(1)
        }
        if !columns.contains(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) {
            try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        }
    }
}
