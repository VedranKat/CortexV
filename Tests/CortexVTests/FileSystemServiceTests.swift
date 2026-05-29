import XCTest
@testable import CortexV

final class FileSystemServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testGlobFilesFindsReadableFilesAndRespectsWorkspaceExcludes() throws {
        let fixture = try makeFixture(excludePatterns: "Secrets/**")
        try write("Sources/App.swift", "struct App {}\n", in: fixture.root)
        try write("Sources/App.md", "# App\n", in: fixture.root)
        try write("Secrets/Token.swift", "let token = \"secret\"\n", in: fixture.root)

        let output = try fixture.service.globFiles(
            workspace: fixture.workspace,
            pattern: "*.swift",
            relativeDirectory: nil
        )

        XCTAssertTrue(output.contains("Sources/App.swift"))
        XCTAssertFalse(output.contains("Sources/App.md"))
        XCTAssertFalse(output.contains("Secrets/Token.swift"))
    }

    func testGrepFilesReturnsLineNumbersAndSupportsIncludeFilter() throws {
        let fixture = try makeFixture()
        try write("Sources/App.swift", """
        struct AppRoot {}
        let delegateToChild = true
        """, in: fixture.root)
        try write("Notes.md", "delegateToChild should not appear with the Swift include filter\n", in: fixture.root)

        let output = try fixture.service.grepFiles(
            workspace: fixture.workspace,
            pattern: "delegatetochild",
            relativePath: nil,
            includePattern: "**/*.swift",
            caseSensitive: false
        )

        XCTAssertTrue(output.contains("Sources/App.swift:2: let delegateToChild = true"))
        XCTAssertFalse(output.contains("Notes.md"))
    }

    func testReadFileRangeReturnsFreshBoundedLineWindow() throws {
        let fixture = try makeFixture()
        try write("Sources/App.swift", """
        alpha
        beta
        gamma
        delta
        epsilon
        """, in: fixture.root)

        var output = try fixture.service.readFileRange(
            workspace: fixture.workspace,
            relativePath: "Sources/App.swift",
            startLine: 2,
            lineCount: 2
        )

        XCTAssertTrue(output.contains("Lines: 2-3 of 5"))
        XCTAssertTrue(output.contains("2: beta"))
        XCTAssertTrue(output.contains("3: gamma"))
        XCTAssertFalse(output.contains("1: alpha"))

        try write("Sources/App.swift", """
        alpha
        changed
        gamma
        delta
        epsilon
        """, in: fixture.root)

        output = try fixture.service.readFileRange(
            workspace: fixture.workspace,
            relativePath: "Sources/App.swift",
            startLine: 2,
            lineCount: 1
        )

        XCTAssertTrue(output.contains("2: changed"))
        XCTAssertFalse(output.contains("2: beta"))
    }

    func testReadFileRangeRejectsOutOfBoundsAndExcludedPaths() throws {
        let fixture = try makeFixture(excludePatterns: "Secrets/**")
        try write("Sources/App.swift", "one\ntwo\n", in: fixture.root)
        try write("Secrets/Token.swift", "secret\n", in: fixture.root)

        XCTAssertThrowsError(try fixture.service.readFileRange(
            workspace: fixture.workspace,
            relativePath: "Sources/App.swift",
            startLine: 99,
            lineCount: 1
        ))

        XCTAssertThrowsError(try fixture.service.readFileRange(
            workspace: fixture.workspace,
            relativePath: "Secrets/Token.swift",
            startLine: 1,
            lineCount: 1
        ))
    }

    func testGrepFilesRejectsInvalidRegex() throws {
        let fixture = try makeFixture()
        try write("Sources/App.swift", "struct App {}\n", in: fixture.root)

        XCTAssertThrowsError(try fixture.service.grepFiles(
            workspace: fixture.workspace,
            pattern: "[",
            relativePath: nil,
            includePattern: nil,
            caseSensitive: false
        ))
    }

    private func makeFixture(excludePatterns: String = "") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexVFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let workspace = Workspace(
            id: 1,
            name: "Fixture",
            rootPath: root.path,
            includePatterns: "**/*",
            excludePatterns: excludePatterns,
            allowRead: true,
            allowWrite: true,
            gitEnabled: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        return Fixture(root: root, workspace: workspace, service: FileSystemService())
    }

    private func write(_ relativePath: String, _ content: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct Fixture {
    let root: URL
    let workspace: Workspace
    let service: FileSystemService
}
