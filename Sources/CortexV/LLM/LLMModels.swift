import Foundation

struct ProviderSettings {
    var baseURL: String
    var apiKey: String
    var defaultModel: String

    static let defaults = ProviderSettings(
        baseURL: "https://api.openai.com/v1",
        apiKey: "",
        defaultModel: "gpt-4.1-mini"
    )
}

struct ConversationItem {
    var role: String
    var content: String
    var toolCallID: String?
    var toolCalls: [ToolCallRequest]

    static func text(role: String, content: String) -> ConversationItem {
        ConversationItem(role: role, content: content, toolCallID: nil, toolCalls: [])
    }

    static func assistantToolCalls(content: String, toolCalls: [ToolCallRequest]) -> ConversationItem {
        ConversationItem(role: "assistant", content: content, toolCallID: nil, toolCalls: toolCalls)
    }

    static func toolResult(toolCallID: String, content: String) -> ConversationItem {
        ConversationItem(role: "tool", content: content, toolCallID: toolCallID, toolCalls: [])
    }
}

struct ToolDefinition {
    var name: String
    var description: String
    var inputSchema: [String: Any]
}

struct ToolCallRequest: Equatable {
    var id: String
    var name: String
    var argumentsJSON: String
}

struct LLMResponse {
    var content: String
    var toolCalls: [ToolCallRequest]

    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

@MainActor
protocol LLMClient {
    func generateTurn(
        settings: ProviderSettings,
        model: String,
        systemPrompt: String,
        conversation: [ConversationItem],
        tools: [ToolDefinition],
        temperature: Double
    ) async throws -> LLMResponse
}
