import Foundation

enum AgentStatus: String, Codable, CaseIterable, Identifiable {
    case enabled = "ENABLED"
    case disabled = "DISABLED"

    var id: String { rawValue }
}

enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case standard = "STANDARD"
    case orchestrator = "ORCHESTRATOR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .orchestrator: "Orchestrator"
        }
    }
}

enum AgentTemplatePropagationField: String, Codable, CaseIterable, Identifiable {
    case baseURL
    case apiKey
    case defaultModel
    case systemPrompt
    case temperature
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baseURL: "Base URL"
        case .apiKey: "API Key"
        case .defaultModel: "Default Model"
        case .systemPrompt: "System Prompt"
        case .temperature: "Temperature"
        case .kind: "Kind"
        }
    }

    var systemImage: String {
        switch self {
        case .baseURL: "link"
        case .apiKey: "key"
        case .defaultModel: "cpu"
        case .systemPrompt: "text.quote"
        case .temperature: "thermometer.medium"
        case .kind: "person.2"
        }
    }
}

enum AgentPromptDefaults {
    static let standard = "You are a helpful coding agent."

    static let orchestrator = """
    You are the lead orchestrator for Cortex V.

    Your job is to turn an ambiguous user goal into a small, inspectable workflow. Coordinate the work; do not try to be every specialist.

    Default operating rhythm:
    - First understand the user's goal and current state. Use direct tools only for lightweight orientation; for broad repo mapping, delegate to a Scout.
    - Use Scouts for read-only codebase mapping, file discovery, dependency summaries, and risk discovery.
    - Use Log Readers for build output, diagnostics, stack traces, test logs, and "what went wrong" questions.
    - Use Bounded Workers for narrow file changes. Give exact scope, relevant context, and expected output. Avoid asking one worker to "do everything" when a smaller slice will work.
    - Use Reviewers before claiming a multi-file implementation is ready, or after worker proposals are created or applied.
    - For short contextual follow-ups like "change it to 3.5.9", infer the target from recent conversation when it is obvious and delegate the concrete edit to a Bounded Worker.
    - Synthesize child results into a clear answer with current state, blockers, and next action. Mention uncertainty instead of smoothing it over.
    - Keep the lead session clean. Summarize durable findings from child runs; do not paste full child transcripts.
    - If pending Changes already cover the requested scope, tell the user to review them instead of launching duplicate workers.
    """

    static func systemPrompt(for kind: AgentKind) -> String {
        switch kind {
        case .standard:
            return standard
        case .orchestrator:
            return orchestrator
        }
    }
}

struct AgentTemplate: Identifiable, Equatable {
    var id: Int64
    var name: String
    var description: String
    var baseURL: String
    var apiKey: String
    var defaultModel: String
    var systemPrompt: String
    var temperature: Double
    var kind: AgentKind
    var createdAt: Date
    var updatedAt: Date

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum OrchestrationRole: String, Codable, CaseIterable, Identifiable {
    case scout = "SCOUT"
    case logReader = "LOG_READER"
    case worker = "BOUNDED_WORKER"
    case reviewer = "REVIEWER"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scout: "Scout"
        case .logReader: "Log Reader"
        case .worker: "Bounded Worker"
        case .reviewer: "Reviewer"
        }
    }

    var systemImage: String {
        switch self {
        case .scout: "binoculars"
        case .logReader: "doc.text.magnifyingglass"
        case .worker: "hammer"
        case .reviewer: "checkmark.shield"
        }
    }

    var defaultHandoffPrompt: String {
        switch self {
        case .scout:
            "Read only. Map the smallest relevant part of the repo. Start with glob/path discovery, then grep exact symbols or text, then read only narrow line ranges once targets are known. Return concise findings with file paths, line refs, confidence levels, risks, and the next likely read or edit target."
        case .logReader:
            "Read only. Inspect logs, build output, or runtime traces. Return failures, likely causes, and the exact evidence."
        case .worker:
            "Work in a bounded scope. Make only the requested changes, list touched files, and stop before broad refactors."
        case .reviewer:
            "Review only. Check the proposed change for bugs, regressions, missing tests, and unsafe assumptions. Return findings first."
        }
    }
}

enum SessionStatus: String, Codable, CaseIterable, Identifiable {
    case active = "ACTIVE"
    case completed = "COMPLETED"
    case failed = "FAILED"

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
    var kind: AgentKind
    var templateID: Int64? = nil
    var createdAt: Date
    var updatedAt: Date

    var enabled: Bool { status == .enabled }
    var orchestrator: Bool { kind == .orchestrator }
}

struct OrchestrationMember: Identifiable, Equatable {
    var leadAgentID: Int64
    var childAgentID: Int64
    var role: OrchestrationRole
    var handoffPrompt: String

    var id: String { "\(leadAgentID)-\(childAgentID)-\(role.rawValue)" }
    var effectivePrompt: String {
        let trimmed = handoffPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.defaultHandoffPrompt : trimmed
    }
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
    var parentSessionID: Int64?
    var orchestrationRole: OrchestrationRole?
    var status: SessionStatus
    var startedAt: Date
    var endedAt: Date?
    var detachedAt: Date?
    var summary: String

    var hasParentProvenance: Bool { parentSessionID != nil }
    var attachedChildRun: Bool { parentSessionID != nil && detachedAt == nil }
    var detachedChildRun: Bool { parentSessionID != nil && detachedAt != nil }
    var childRun: Bool { attachedChildRun }
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
    var baseContentExists: Bool
    var newContent: String
    var diffText: String
    var status: String

    var pending: Bool { status.caseInsensitiveCompare("PENDING") == .orderedSame }
    var applied: Bool { status.caseInsensitiveCompare("APPLIED") == .orderedSame }
    var rejected: Bool { status.caseInsensitiveCompare("REJECTED") == .orderedSame }
}

struct ReviewContextHandoff: Identifiable, Equatable {
    var id: Int64
    var sourceSessionID: Int64
    var targetSessionID: Int64
    var status: String
    var payloadHash: String
    var sentAt: Date?
    var createdAt: Date
}
