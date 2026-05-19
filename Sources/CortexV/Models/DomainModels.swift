import Foundation

enum AgentStatus: String, Codable, CaseIterable, Identifiable {
    case enabled = "ENABLED"
    case disabled = "DISABLED"

    var id: String { rawValue }
}

enum SessionStatus: String, Codable, CaseIterable, Identifiable {
    case active = "ACTIVE"
    case completed = "COMPLETED"

    var id: String { rawValue }
}

struct Agent: Identifiable, Equatable {
    var id: Int64
    var name: String
    var description: String
    var baseURL: String
    var apiKey: String
    var model: String
    var systemPrompt: String
    var temperature: Double
    var status: AgentStatus
    var createdAt: Date
    var updatedAt: Date

    var enabled: Bool { status == .enabled }
}

struct Workspace: Identifiable, Equatable {
    var id: Int64
    var name: String
    var rootPath: String
    var includePatterns: String
    var excludePatterns: String
    var allowRead: Bool
    var allowWrite: Bool
    var gitEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
}

struct AgentWorkspaceBinding: Equatable {
    var agentID: Int64
    var workspaceID: Int64
}

struct Session: Identifiable, Equatable {
    var id: Int64
    var agentID: Int64
    var workspaceID: Int64?
    var status: SessionStatus
    var startedAt: Date
    var endedAt: Date?
    var summary: String
}

struct Message: Identifiable, Equatable {
    var id: Int64
    var sessionID: Int64
    var role: String
    var content: String
    var timestamp: Date
}

struct ToolCall: Identifiable, Equatable {
    var id: Int64
    var sessionID: Int64
    var toolName: String
    var argumentsJSON: String
    var resultJSON: String
    var status: String
    var timestamp: Date

    var successful: Bool { status.caseInsensitiveCompare("SUCCESS") == .orderedSame }
}

struct ChangeSet: Identifiable, Equatable {
    var id: Int64
    var sessionID: Int64
    var workspaceID: Int64?
    var status: String
    var createdAt: Date

    var pending: Bool { status.caseInsensitiveCompare("PENDING") == .orderedSame }
}

struct FileChange: Identifiable, Equatable {
    var id: Int64
    var changeSetID: Int64
    var filePath: String
    var oldContent: String
    var newContent: String
    var diffText: String
    var status: String

    var pending: Bool { status.caseInsensitiveCompare("PENDING") == .orderedSame }
}
