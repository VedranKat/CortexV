import SwiftUI

struct OrchestrationDetailSection: View {
    let lead: Agent
    let members: [OrchestrationMember]
    let agents: [Agent]
    let workspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Orchestration")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                if members.isEmpty {
                    Text("No sub-agents assigned.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members) { member in
                        OrchestrationMemberCard(
                            member: member,
                            childName: childName(member.childAgentID),
                            sharedWorkspaces: sharedWorkspaceNames(childAgentID: member.childAgentID)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func childName(_ id: Int64) -> String {
        agents.first { $0.id == id }?.name ?? "Agent #\(id)"
    }

    private func sharedWorkspaceNames(childAgentID: Int64) -> String {
        let leadWorkspaceIDs = agentWorkspaceIDs[lead.id] ?? []
        let childWorkspaceIDs = agentWorkspaceIDs[childAgentID] ?? []
        let sharedIDs = leadWorkspaceIDs.intersection(childWorkspaceIDs)
        let names = workspaces
            .filter { sharedIDs.contains($0.id) }
            .map(\.name)
            .sorted()
        return names.isEmpty ? "No shared workspace" : names.joined(separator: ", ")
    }
}

private struct OrchestrationMemberCard: View {
    let member: OrchestrationMember
    let childName: String
    let sharedWorkspaces: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(member.role.title, systemImage: member.role.systemImage)
                    .font(.callout.weight(.semibold))

                Spacer(minLength: 12)

                Text(childName)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.trailing)
            }

            Text(sharedWorkspaces)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(member.effectivePrompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct OrchestrationEditorSection: View {
    @Binding var draft: AgentDraft
    let agents: [Agent]
    let workspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]

    var body: some View {
        Section("Orchestration") {
            if draft.workspaceIDs.isEmpty {
                ActionFeedbackView(feedback: ActionFeedback(kind: .info, message: "Bind this lead agent to a workspace before assigning sub-agents."))
            }

            if draft.orchestrationMembers.isEmpty {
                Text("No sub-agents assigned.")
                    .foregroundStyle(.secondary)
            }

            if !canAddAssignment {
                Text(unavailableSubAgentMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($draft.orchestrationMembers) { $member in
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Agent", selection: $member.childAgentID) {
                        ForEach(candidateAgents(for: member.childAgentID)) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }

                    Picker("Role", selection: $member.role) {
                        ForEach(OrchestrationRole.allCases) { role in
                            Label(role.title, systemImage: role.systemImage).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Handoff Prompt", text: $member.handoffPrompt, axis: .vertical)
                        .lineLimit(2...5)

                    Text(member.effectivePrompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if !sharesWorkspace(member.childAgentID) {
                        ActionFeedbackView(feedback: ActionFeedback(kind: .error, message: "This sub-agent is not bound to the same workspace as the lead."))
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            remove(member.id)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Button {
                addChildAgent()
            } label: {
                Label("Add Sub-Agent", systemImage: "plus")
            }
            .disabled(!canAddAssignment)
        }
    }

    private var canAddAssignment: Bool {
        firstAvailableAgentID != nil && firstAvailableRole(for: firstAvailableAgentID!) != nil
    }

    private var firstAvailableAgentID: Int64? {
        eligibleAgents.first { firstAvailableRole(for: $0.id) != nil }?.id
    }

    private var eligibleAgents: [Agent] {
        agents.filter { agent in
            if let draftID = draft.id, agent.id == draftID {
                return false
            }
            return agent.enabled && sharesWorkspace(agent.id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var unavailableSubAgentMessage: String {
        if draft.workspaceIDs.isEmpty {
            return "Sub-agents need a workspace in common with this lead."
        }
        if eligibleAgents.isEmpty {
            return "No enabled agents share this lead's workspace yet."
        }
        return "All eligible sub-agent role assignments are already assigned."
    }

    private func candidateAgents(for currentID: Int64?) -> [Agent] {
        agents.filter { agent in
            if let draftID = draft.id, agent.id == draftID {
                return false
            }
            if !agent.enabled, agent.id != currentID {
                return false
            }
            if agent.id == currentID {
                return true
            }
            return sharesWorkspace(agent.id) && firstAvailableRole(for: agent.id) != nil
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sharesWorkspace(_ childAgentID: Int64) -> Bool {
        let childWorkspaceIDs = agentWorkspaceIDs[childAgentID] ?? []
        return !childWorkspaceIDs.intersection(draft.workspaceIDs).isEmpty
    }

    private func addChildAgent() {
        guard let childAgentID = firstAvailableAgentID,
              let role = firstAvailableRole(for: childAgentID)
        else {
            return
        }
        draft.orchestrationMembers.append(OrchestrationMemberDraft(childAgentID: childAgentID, role: role))
    }

    private func remove(_ id: OrchestrationMemberDraft.ID) {
        draft.orchestrationMembers.removeAll { $0.id == id }
    }

    private func firstAvailableRole(for childAgentID: Int64) -> OrchestrationRole? {
        OrchestrationRole.allCases.first { role in
            !draft.orchestrationMembers.contains {
                $0.childAgentID == childAgentID && $0.role == role
            }
        }
    }
}
