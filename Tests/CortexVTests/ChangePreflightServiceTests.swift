import XCTest
@testable import CortexV

final class ChangePreflightServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testPreflightBlocksWhenFileChangedOnDisk() throws {
        let fixture = try makeFixture()
        try write("README.md", "Original\n", in: fixture.workspaceRoot)
        let proposal = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.session.id,
            workspaceID: fixture.workspace.id,
            relativePath: "README.md",
            newContent: "Updated\n"
        )

        var result = try fixture.preflightService.preflight(proposal)
        XCTAssertEqual(result.status, .ready)

        try write("README.md", "Changed elsewhere\n", in: fixture.workspaceRoot)
        result = try fixture.preflightService.preflight(proposal)

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.issues.contains { $0.title == "File changed on disk" })
        XCTAssertThrowsError(try fixture.reviewService.approveFileChange(proposal.id))
    }

    func testPreflightBlocksWhenNewFileNowExists() throws {
        let fixture = try makeFixture()
        let proposal = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.session.id,
            workspaceID: fixture.workspace.id,
            relativePath: "Created.md",
            newContent: "Created by proposal\n"
        )
        XCTAssertFalse(proposal.baseContentExists)

        try write("Created.md", "Created elsewhere\n", in: fixture.workspaceRoot)
        let result = try fixture.preflightService.preflight(proposal)

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.issues.contains { $0.title == "New file now exists" })
    }

    func testPreflightBlocksDuplicatePendingTargets() throws {
        let fixture = try makeFixture()
        try write("README.md", "Original\n", in: fixture.workspaceRoot)
        let first = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.session.id,
            workspaceID: fixture.workspace.id,
            relativePath: "README.md",
            newContent: "First\n"
        )
        _ = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.session.id,
            workspaceID: fixture.workspace.id,
            relativePath: "README.md",
            newContent: "Second\n"
        )

        let result = try fixture.preflightService.preflight(first)

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.issues.contains { $0.title == "Another pending proposal targets this file" })
    }

    func testPreflightWarnsForLargeDeletion() throws {
        let fixture = try makeFixture()
        let oldContent = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        try write("Large.txt", oldContent, in: fixture.workspaceRoot)
        let proposal = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.session.id,
            workspaceID: fixture.workspace.id,
            relativePath: "Large.txt",
            newContent: "short\n"
        )

        let result = try fixture.preflightService.preflight(proposal)

        XCTAssertEqual(result.status, .warning)
        XCTAssertTrue(result.canApprove)
        XCTAssertTrue(result.issues.contains { $0.title == "Large deletion" })
    }

    func testMigrationTreatsLegacyBlankBasePendingProposalAsNewFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let database = SQLiteDatabase(path: root.appendingPathComponent("legacy.sqlite").path)
        try database.execute("""
            CREATE TABLE change_sets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                workspace_id INTEGER,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE file_changes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                change_set_id INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                old_content TEXT,
                new_content TEXT,
                diff_text TEXT,
                status TEXT NOT NULL
            )
            """)
        try database.execute("""
            INSERT INTO change_sets (id, session_id, workspace_id, status, created_at)
            VALUES (?, ?, ?, ?, ?)
            """, values: [.int(1), .int(1), .null, .text("PENDING"), .text("2026-01-01T00:00:00Z")])
        try database.execute("""
            INSERT INTO file_changes (id, change_set_id, file_path, old_content, new_content, diff_text, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, values: [.int(1), .int(1), .text("Created.md"), .text(""), .text("Created by proposal\n"), .text("+ Created by proposal"), .text("PENDING")])

        try SchemaInitializer(database: database).initialize()

        let flags = try database.query("SELECT base_content_exists FROM file_changes WHERE id = 1") { row in
            row.bool(0)
        }
        XCTAssertEqual(flags, [false])
    }

    private func makeFixture(allowWrite: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexVTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let persistence = try PersistenceContainer(database: SQLiteDatabase(path: root.appendingPathComponent("db.sqlite").path))
        let workspace = try persistence.workspaces.insert(
            name: "Fixture",
            rootPath: workspaceRoot.path,
            includePatterns: "**/*",
            excludePatterns: "",
            allowRead: true,
            allowWrite: allowWrite,
            gitEnabled: false
        )
        let agent = try persistence.agents.insert(
            name: "Agent",
            description: "",
            baseURL: "https://example.invalid/v1",
            apiKey: "",
            model: "test-model",
            systemPrompt: AgentPromptDefaults.standard,
            temperature: 0.2,
            status: .enabled,
            kind: .standard
        )
        try persistence.agents.replaceWorkspaceBindings(agentID: agent.id, workspaceIDs: [workspace.id])
        let session = try persistence.sessions.insert(
            agentID: agent.id,
            workspaceID: workspace.id,
            status: .active,
            summary: ""
        )
        let fileSystem = FileSystemService()
        return Fixture(
            workspaceRoot: workspaceRoot,
            persistence: persistence,
            workspace: workspace,
            session: session,
            preflightService: ChangePreflightService(persistence: persistence, fileSystemService: fileSystem),
            reviewService: ChangeReviewService(
                persistence: persistence,
                fileSystemService: fileSystem,
                diffService: DiffService()
            )
        )
    }

    private func write(_ relativePath: String, _ content: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct Fixture {
    let workspaceRoot: URL
    let persistence: PersistenceContainer
    let workspace: Workspace
    let session: Session
    let preflightService: ChangePreflightService
    let reviewService: ChangeReviewService
}
