import XCTest
@testable import CortexV

final class ReviewWorkbenchTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testProjectionGroupsBySubAgentSessionAndFiltersByFacets() throws {
        let fixture = try makeFixture()
        try write("Sources/Feature.swift", "old\n", in: fixture.workspaceRoot)
        let proposal = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.workerSession.id,
            workspaceID: fixture.workspace.id,
            relativePath: "Sources/Feature.swift",
            newContent: "new\n"
        )
        let snapshot = try makeSnapshot(fixture)

        XCTAssertEqual(snapshot.groups.count, 1)
        let group = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(group.sessionID, fixture.workerSession.id)
        XCTAssertEqual(group.parentSessionID, fixture.leadSession.id)
        XCTAssertEqual(group.rootSessionID, fixture.leadSession.id)
        XCTAssertEqual(group.role, .worker)
        XCTAssertEqual(group.pendingCount, 1)
        XCTAssertEqual(group.items.first?.id, proposal.id)

        var filters = ReviewFilters()
        filters.workspaceID = fixture.workspace.id
        filters.role = .worker
        filters.searchText = "feature"
        XCTAssertEqual(snapshot.filteredGroups(using: filters).map(\.id), [group.id])

        filters.role = .reviewer
        XCTAssertTrue(snapshot.filteredGroups(using: filters).isEmpty)
    }

    func testLeadContextServiceSendsCompactMessageAndSkipsDuplicatePayload() throws {
        let fixture = try makeFixture()
        let proposal = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.workerSession.id,
            workspaceID: fixture.workspace.id,
            relativePath: "Created.md",
            newContent: "created\n"
        )
        _ = try fixture.reviewService.approveFileChange(proposal.id)

        var snapshot = try makeSnapshot(fixture)
        var group = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(group.syncState, .needsLeadSync)

        let service = ReviewContextService(persistence: fixture.persistence)
        let sent = try service.sendLeadUpdate(for: group)
        XCTAssertEqual(sent.status, .sent)

        let duplicate = try service.sendLeadUpdate(for: group)
        XCTAssertEqual(duplicate.status, .skippedDuplicate)

        let messages = try fixture.persistence.messages.findBySessionID(fixture.leadSession.id)
            .filter { $0.role == "context" }
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content.contains("Review update: Session #\(fixture.workerSession.id)"))
        XCTAssertTrue(messages[0].content.contains("Files: Created.md (applied)"))
        XCTAssertFalse(messages[0].content.contains("diff --git"))

        snapshot = try makeSnapshot(fixture)
        group = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(group.syncState, .sent)
    }

    func testBulkApproveChecksDuplicateTargetsOutsideSelectedBatch() throws {
        let fixture = try makeFixture()
        try write("README.md", "old\n", in: fixture.workspaceRoot)
        let first = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.workerSession.id,
            workspaceID: fixture.workspace.id,
            relativePath: "README.md",
            newContent: "first\n"
        )
        let second = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.workerSession.id,
            workspaceID: fixture.workspace.id,
            relativePath: "README.md",
            newContent: "second\n"
        )

        XCTAssertThrowsError(try fixture.reviewService.approveFileChanges([first.id]))
        XCTAssertTrue(try fixture.persistence.fileChanges.find(id: first.id).pending)
        XCTAssertTrue(try fixture.persistence.fileChanges.find(id: second.id).pending)
    }

    func testProjectionMarksFinishedChangedSinceSentWhenOutcomeChangesAfterHandoff() throws {
        let fixture = try makeFixture()
        let first = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.workerSession.id,
            workspaceID: fixture.workspace.id,
            relativePath: "First.md",
            newContent: "first\n"
        )
        _ = try fixture.reviewService.approveFileChange(first.id)

        var snapshot = try makeSnapshot(fixture)
        var group = try XCTUnwrap(snapshot.groups.first)
        _ = try ReviewContextService(persistence: fixture.persistence).sendLeadUpdate(for: group)

        let second = try fixture.reviewService.proposeFileWrite(
            sessionID: fixture.workerSession.id,
            workspaceID: fixture.workspace.id,
            relativePath: "Second.md",
            newContent: "second\n"
        )
        _ = try fixture.reviewService.rejectFileChange(second.id)

        snapshot = try makeSnapshot(fixture)
        group = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(group.syncState, .changedSinceSent)

        let defaultVisible = snapshot.filteredGroups(using: ReviewFilters())
        XCTAssertEqual(defaultVisible.map(\.id), [group.id])
    }

    private func makeSnapshot(_ fixture: Fixture) throws -> ReviewProjectionSnapshot {
        let fileChanges = try fixture.persistence.fileChanges.findAll()
        let preflights = try fixture.preflightService.preflight(fileChanges)
        return ReviewProjection.make(
            sessions: try fixture.persistence.sessions.findAll(),
            agents: try fixture.persistence.agents.findAll(),
            workspaces: try fixture.persistence.workspaces.findAll(),
            changeSets: try fixture.persistence.changeSets.findAll(),
            fileChanges: fileChanges,
            preflightResults: preflights,
            handoffs: try fixture.persistence.reviewContextHandoffs.findAll()
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexVReviewTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let persistence = try PersistenceContainer(database: SQLiteDatabase(path: root.appendingPathComponent("db.sqlite").path))
        let workspace = try persistence.workspaces.insert(
            name: "Project",
            rootPath: workspaceRoot.path,
            includePatterns: "**/*",
            excludePatterns: "",
            allowRead: true,
            allowWrite: true,
            gitEnabled: false
        )
        let leadAgent = try persistence.agents.insert(
            name: "Lead",
            description: "",
            baseURL: "https://example.invalid/v1",
            apiKey: "",
            model: "test-model",
            systemPrompt: AgentPromptDefaults.orchestrator,
            temperature: 0.2,
            status: .enabled,
            kind: .orchestrator
        )
        let workerAgent = try persistence.agents.insert(
            name: "Worker",
            description: "",
            baseURL: "https://example.invalid/v1",
            apiKey: "",
            model: "test-model",
            systemPrompt: AgentPromptDefaults.standard,
            temperature: 0.2,
            status: .enabled,
            kind: .standard
        )
        try persistence.agents.replaceWorkspaceBindings(agentID: leadAgent.id, workspaceIDs: [workspace.id])
        try persistence.agents.replaceWorkspaceBindings(agentID: workerAgent.id, workspaceIDs: [workspace.id])

        let leadSession = try persistence.sessions.insert(
            agentID: leadAgent.id,
            workspaceID: workspace.id,
            status: .active,
            summary: "Lead Task"
        )
        let workerSession = try persistence.sessions.insert(
            agentID: workerAgent.id,
            workspaceID: workspace.id,
            parentSessionID: leadSession.id,
            orchestrationRole: .worker,
            status: .completed,
            summary: "Worker Task"
        )

        let fileSystem = FileSystemService()
        return Fixture(
            workspaceRoot: workspaceRoot,
            persistence: persistence,
            workspace: workspace,
            leadSession: leadSession,
            workerSession: workerSession,
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
    let leadSession: Session
    let workerSession: Session
    let preflightService: ChangePreflightService
    let reviewService: ChangeReviewService
}
