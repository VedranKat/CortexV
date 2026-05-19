import Foundation

enum LLMError: LocalizedError {
    case missingAPIKey
    case missingBaseURL
    case missingModel
    case providerFailed(status: Int, body: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Provider API key is missing for this agent."
        case .missingBaseURL: "Provider base URL is missing for this agent."
        case .missingModel: "Provider model is missing for this agent."
        case .providerFailed(let status, let body): "Provider request failed: HTTP \(status)\n\(body)"
        case .invalidResponse: "Provider response did not include agent text or tool calls."
        }
    }
}

final class OpenAICompatibleClient: LLMClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateTurn(
        settings: ProviderSettings,
        model: String,
        systemPrompt: String,
        conversation: [ConversationItem],
        tools: [ToolDefinition],
        temperature: Double
    ) async throws -> LLMResponse {
        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let baseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { throw LLMError.missingBaseURL }

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? settings.defaultModel : model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedModel.isEmpty else { throw LLMError.missingModel }

        var messages: [[String: Any]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        messages.append(contentsOf: conversation.map(messageDictionary))

        var body: [String: Any] = [
            "model": resolvedModel,
            "temperature": temperature,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(toolDictionary)
            body["tool_choice"] = "auto"
        }

        let url = URL(string: normalizeBaseURL(baseURL) + "/chat/completions")!
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.providerFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let choices = json?["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw LLMError.invalidResponse
        }

        let content = extractContent(message["content"])
        let toolCalls = extractToolCalls(message["tool_calls"])
        if !toolCalls.isEmpty {
            return LLMResponse(content: content, toolCalls: toolCalls)
        }
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LLMResponse(content: content, toolCalls: [])
        }
        throw LLMError.invalidResponse
    }

    private func messageDictionary(_ item: ConversationItem) -> [String: Any] {
        if item.role.caseInsensitiveCompare("tool") == .orderedSame {
            return [
                "role": "tool",
                "content": item.content,
                "tool_call_id": item.toolCallID ?? ""
            ]
        }
        if item.role.caseInsensitiveCompare("assistant") == .orderedSame, !item.toolCalls.isEmpty {
            return [
                "role": "assistant",
                "content": item.content,
                "tool_calls": item.toolCalls.map(serializedToolCall)
            ]
        }
        return ["role": item.role, "content": item.content]
    }

    private func toolDictionary(_ tool: ToolDefinition) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.inputSchema
            ]
        ]
    }

    private func serializedToolCall(_ toolCall: ToolCallRequest) -> [String: Any] {
        [
            "id": toolCall.id,
            "type": "function",
            "function": [
                "name": toolCall.name,
                "arguments": toolCall.argumentsJSON.isEmpty ? "{}" : toolCall.argumentsJSON
            ]
        ]
    }

    private func extractContent(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        guard let items = value as? [[String: Any]] else {
            return ""
        }
        return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func extractToolCalls(_ value: Any?) -> [ToolCallRequest] {
        guard let calls = value as? [[String: Any]] else {
            return []
        }
        return calls.compactMap { call in
            guard
                let function = call["function"] as? [String: Any],
                let name = function["name"] as? String,
                !name.isEmpty
            else {
                return nil
            }
            let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(name)-call"
            let arguments = function["arguments"] as? String ?? "{}"
            return ToolCallRequest(id: id, name: name, argumentsJSON: arguments)
        }
    }

    private func normalizeBaseURL(_ baseURL: String) -> String {
        var normalized = baseURL
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
