import Foundation

@MainActor
struct ChatService {
    private let maxToolRounds = 8
    private let duplicateToolNotice = "Tool notice: This exact tool call already ran in this turn. Reuse the existing result instead of repeating it."
    private let proposalCreatedMessage = "I created one or more file change proposals. Open the Changes view to review the diff and approve or reject them."
    private let duplicateStopMessage = "I stopped because the model kept repeating the same tool call instead of moving forward. Review the current Activity and Changes views, then continue from there."
    private let safetyLimitMessage = "I stopped because the tool loop hit its safety limit. Review the current Activity and Changes views, then continue with a fresh follow-up message."
    private let noWritePermissionMessage = "I can inspect this workspace, but I cannot propose file edits because no writable workspace is available for this agent. Enable write access on a bound workspace and try again."

    let persistence: PersistenceContainer
    let toolExecutionService: ToolExecutionService
    let llmClient: LLMClient

    func generateAssistantReply(sessionID: Int64) async throws {
        let session = try persistence.sessions.find(id: sessionID)
        let agent = try persistence.agents.find(id: session.agentID)
        let persistedMessages = try persistence.messages.findBySessionID(sessionID)
        var conversation = persistedMessages.map { ConversationItem.text(role: $0.role, content: $0.content) }
        let tools = try toolExecutionService.availableToolsForSession(sessionID)

        let editRequest = isEditRequest(latestUserMessage(persistedMessages))
        let canProposeWrites = tools.contains { $0.name == "propose_file_write" }
        if editRequest && !canProposeWrites {
            _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: noWritePermissionMessage)
            return
        }

        var executedSignatures = Set<String>()
        for _ in 0..<maxToolRounds {
            let response = try await llmClient.generateTurn(
                settings: ProviderSettings(baseURL: agent.baseURL, apiKey: agent.apiKey, defaultModel: agent.model),
                model: agent.model,
                systemPrompt: mergeSystemPrompt(agent.systemPrompt, tools: tools),
                conversation: conversation,
                tools: tools,
                temperature: agent.temperature
            )

            if response.hasToolCalls {
                var duplicateSeen = false
                var proposalCreated = false
                conversation.append(.assistantToolCalls(content: response.content, toolCalls: response.toolCalls))

                for toolCall in response.toolCalls {
                    let signature = "\(toolCall.name)|\(toolCall.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines))"
                    if executedSignatures.contains(signature) {
                        duplicateSeen = true
                        _ = try persistence.toolCalls.insert(sessionID: sessionID, toolName: toolCall.name, argumentsJSON: toolCall.argumentsJSON, resultJSON: duplicateToolNotice, status: "SKIPPED")
                        conversation.append(.toolResult(toolCallID: toolCall.id, content: duplicateToolNotice))
                        continue
                    }
                    executedSignatures.insert(signature)

                    let result = toolExecutionService.executeToolCall(sessionID: sessionID, toolCall: toolCall)
                    _ = try persistence.toolCalls.insert(
                        sessionID: sessionID,
                        toolName: toolCall.name,
                        argumentsJSON: toolCall.argumentsJSON,
                        resultJSON: result,
                        status: result.hasPrefix("Tool error:") ? "FAILURE" : "SUCCESS"
                    )
                    conversation.append(.toolResult(toolCallID: toolCall.id, content: result))
                    if toolCall.name == "propose_file_write", !result.hasPrefix("Tool error:") {
                        proposalCreated = true
                    }
                }

                if proposalCreated {
                    _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: proposalCreatedMessage)
                    return
                }
                if duplicateSeen {
                    _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: duplicateStopMessage)
                    return
                }
                continue
            }

            let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else {
                throw ToolExecutionError.message("The agent returned no final text.")
            }
            if mentionsProposalWithoutTool(reply) {
                _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: "I inspected the file, but I have not actually created a change proposal yet. Please ask me again if you want me to try the proposal step once more.")
                return
            }
            _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: reply)
            return
        }

        _ = try persistence.messages.insert(sessionID: sessionID, role: "assistant", content: safetyLimitMessage)
    }

    func generateSessionTitle(sessionID: Int64) async throws -> String {
        let session = try persistence.sessions.find(id: sessionID)
        let agent = try persistence.agents.find(id: session.agentID)
        let messages = try persistence.messages.findBySessionID(sessionID)
        guard let firstUserMessage = messages.first(where: { $0.role.caseInsensitiveCompare("user") == .orderedSame }) else {
            return ""
        }
        let firstAssistantMessage = messages.first(where: { $0.role.caseInsensitiveCompare("assistant") == .orderedSame })

        var conversation = [
            ConversationItem.text(role: "user", content: "User's first message:\n\(firstUserMessage.content)")
        ]
        if let firstAssistantMessage {
            conversation.append(.text(role: "user", content: "Agent's first reply:\n\(firstAssistantMessage.content)"))
        }
        conversation.append(.text(role: "user", content: "Create a concise 3-7 word title for this session. Return only the title, with no quotes and no punctuation at the end."))

        let response = try await llmClient.generateTurn(
            settings: ProviderSettings(baseURL: agent.baseURL, apiKey: agent.apiKey, defaultModel: agent.model),
            model: agent.model,
            systemPrompt: "You write short, specific conversation titles for a desktop AI agent app.",
            conversation: conversation,
            tools: [],
            temperature: 0.2
        )

        return cleanTitle(response.content)
    }

    private func mergeSystemPrompt(_ systemPrompt: String, tools: [ToolDefinition]) -> String {
        let guidance = """
        You can inspect the workspace with tools, but use them deliberately.
        Never repeat the same tool call with the same arguments once you already have its result.
        When the user asks for a file change, inspect only what you need, then call propose_file_write with the full replacement file content.
        Do not keep calling read_file on the same target file after you already have its content.
        Never tell the user that you created, proposed, or prepared a file change unless you actually called propose_file_write successfully in this turn.
        After a successful propose_file_write call, stop calling tools and tell the user to review the Changes view.
        When you have enough information, stop calling tools and answer the user directly.
        """
        guard !tools.isEmpty else { return systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }
        let base = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? guidance : base + "\n\n" + guidance
    }

    private func latestUserMessage(_ messages: [Message]) -> String {
        messages.last { $0.role.caseInsensitiveCompare("user") == .orderedSame }?.content ?? ""
    }

    private func isEditRequest(_ content: String) -> Bool {
        let normalized = content.lowercased()
        return ["update ", "change ", "edit ", "modify ", "replace ", "refactor ", "fix ", "set ", "bump ", "rename ", "remove ", "add ", "upgrade ", "downgrade ", "rewrite ", "patch ", "implement ", "create ", "write ", "change the version", "update the version", "downgrade the version", "upgrade the version"].contains { normalized.contains($0) }
    }

    private func mentionsProposalWithoutTool(_ reply: String) -> Bool {
        let normalized = reply.lowercased()
        return ["changes view", "approve", "propose the change", "proposed the change", "review and approve"].contains { normalized.contains($0) }
    }

    private func cleanTitle(_ value: String) -> String {
        var title = value
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? value
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_# "))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".?!:;,- "))

        if title.count > 64 {
            title = String(title.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }
}
