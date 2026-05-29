import Dispatch
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var editorDraft: AgentDraft?
    @State private var feedback: ActionFeedback?

    private var selectedAgent: Agent? {
        appModel.agents.first { $0.id == appModel.selectedAgentID }
    }

    private var selectedBoundWorkspaces: [Workspace] {
        appModel.boundWorkspaces(for: selectedAgent?.id)
    }

    var body: some View {
        HSplitView {
            agentListColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            AgentDetailView(
                agent: selectedAgent,
                boundWorkspaces: selectedBoundWorkspaces,
                allAgents: appModel.agents,
                allWorkspaces: appModel.workspaces,
                agentWorkspaceIDs: appModel.agentWorkspaceIDs,
                orchestrationMembers: appModel.orchestrationMembers(for: selectedAgent?.id),
                feedback: feedback,
                onNew: { editorDraft = appModel.agentDraft() },
                onCreateWorkspace: { appModel.selectedSection = .workspaces }
            )
            .frame(minWidth: 520)
        }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editorDraft = appModel.agentDraft()
                } label: {
                    Label("New Agent", systemImage: "plus")
                }

                Button {
                    if let selectedAgent {
                        editorDraft = appModel.agentDraft(for: selectedAgent)
                    }
                } label: {
                    Label("Edit Agent", systemImage: "pencil")
                }
                .disabled(selectedAgent == nil)

                Button(role: .destructive) {
                    appModel.deleteSelectedAgent()
                    feedback = ActionFeedback(kind: .info, message: appModel.statusText)
                } label: {
                    Label("Delete Agent", systemImage: "trash")
                }
                .disabled(selectedAgent == nil)
            }
        }
        .sheet(item: $editorDraft) { draft in
            AgentEditorSheet(
                draft: draft,
                agents: appModel.agents,
                workspaces: appModel.workspaces,
                agentWorkspaceIDs: appModel.agentWorkspaceIDs,
                onCancel: { editorDraft = nil },
                onSave: { draft in
                    let saved = appModel.saveAgent(draft)
                    let result = ActionFeedback(kind: saved ? .success : .error, message: appModel.statusText)
                    feedback = result
                    return result
                },
                onSaved: { editorDraft = nil }
            )
        }
    }

    private var agentListColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Agents", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                    Spacer()
                    Button {
                        editorDraft = appModel.agentDraft()
                    } label: {
                        Label("New Agent", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .help("New Agent")
                }

                if appModel.workspaces.isEmpty {
                    ActionFeedbackView(feedback: ActionFeedback(kind: .info, message: "Workspaces are optional. Create a chat-only agent now, then bind a workspace later for file tools."))
                }
            }
            .padding(12)

            Divider()

            List(selection: $appModel.selectedAgentID) {
                ForEach(appModel.agents) { agent in
                    AgentRow(agent: agent)
                        .tag(Optional(agent.id))
                }
            }
            .overlay {
                if appModel.agents.isEmpty {
                    ContentUnavailableView(
                        "No Agents",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Create a chat-only agent, or bind one to a workspace for file tools.")
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AgentRow: View {
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(agent.status.rawValue.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(agent.enabled ? .green : .secondary)
            }

            HStack(spacing: 6) {
                Text(agent.kind.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(agent.orchestrator ? Color.accentColor : Color.secondary)

                Text(agent.model.isEmpty ? "Model not set" : agent.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !agent.baseURL.isEmpty {
                Text(agent.baseURL)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AgentDetailView: View {
    let agent: Agent?
    let boundWorkspaces: [Workspace]
    let allAgents: [Agent]
    let allWorkspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]
    let orchestrationMembers: [OrchestrationMember]
    let feedback: ActionFeedback?
    let onNew: () -> Void
    let onCreateWorkspace: () -> Void

    var body: some View {
        if let agent {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(agent: agent)

                    if let feedback {
                        ActionFeedbackView(feedback: feedback)
                    }

                    AgentDetailSection("Provider") {
                        DetailRow(title: "Kind", value: agent.kind.title)
                        DetailRow(title: "Base URL", value: agent.baseURL.isEmpty ? "Not set" : agent.baseURL)
                        DetailRow(title: "Model", value: agent.model.isEmpty ? "Not set" : agent.model)
                        DetailRow(title: "Status", value: agent.status.rawValue.capitalized)
                        DetailRow(title: "Temperature", value: agent.temperature.formatted(.number.precision(.fractionLength(1))))
                    }

                    AgentDetailSection("Bound Workspaces") {
                        if boundWorkspaces.isEmpty {
                            Text("Chat only. Bind a workspace later to enable file tools.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(boundWorkspaces) { workspace in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspace.name)
                                        .font(.callout.weight(.medium))
                                    Text(workspace.rootPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    AgentDetailSection("Description") {
                        Text(agent.description.isEmpty ? "No description" : agent.description)
                            .foregroundStyle(agent.description.isEmpty ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    AgentDetailSection("System Prompt") {
                        Text(agent.systemPrompt)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if agent.orchestrator {
                        OrchestrationDetailSection(
                            lead: agent,
                            members: orchestrationMembers,
                            agents: allAgents,
                            workspaces: allWorkspaces,
                            agentWorkspaceIDs: agentWorkspaceIDs
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView {
                Label("Select an Agent", systemImage: "person.crop.circle")
            } description: {
                Text("Agents define provider settings and workspace bindings.")
            } actions: {
                HStack {
                    Button {
                        onCreateWorkspace()
                    } label: {
                        Label("Workspace", systemImage: "folder.badge.plus")
                    }

                    Button {
                        onNew()
                    } label: {
                        Label("New Agent", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func detailHeader(agent: Agent) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                Text(agent.model.isEmpty ? "Model not set" : agent.model)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

private struct AgentDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct AgentEditorSheet: View {
    @State private var draft: AgentDraft
    @State private var saveFeedback: ActionFeedback?
    let agents: [Agent]
    let workspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]
    let onCancel: () -> Void
    let onSave: (AgentDraft) -> ActionFeedback
    let onSaved: () -> Void

    init(
        draft: AgentDraft,
        agents: [Agent],
        workspaces: [Workspace],
        agentWorkspaceIDs: [Int64: Set<Int64>],
        onCancel: @escaping () -> Void,
        onSave: @escaping (AgentDraft) -> ActionFeedback,
        onSaved: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.agents = agents
        self.workspaces = workspaces
        self.agentWorkspaceIDs = agentWorkspaceIDs
        self.onCancel = onCancel
        self.onSave = onSave
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.id == nil ? "New Agent" : "Edit Agent")
                    .font(.title2.weight(.semibold))
                Text("Provider settings, prompt, and workspace access.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Status", selection: $draft.status) {
                        ForEach(AgentStatus.allCases) { status in
                            Text(status.rawValue.capitalized).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Kind", selection: $draft.kind) {
                        ForEach(AgentKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Provider") {
                    TextField("Base URL", text: $draft.baseURL)
                    SecureField("API Key", text: $draft.apiKey)
                    TextField("Model", text: $draft.model)
                    HStack {
                        Slider(value: $draft.temperature, in: 0...2, step: 0.1) {
                            Text("Temperature")
                        } minimumValueLabel: {
                            Text("0")
                        } maximumValueLabel: {
                            Text("2")
                        }
                        Text(draft.temperature.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                Section("Workspace Binding") {
                    if workspaces.isEmpty {
                        ActionFeedbackView(feedback: ActionFeedback(kind: .info, message: "No workspaces yet. Save this agent as chat-only, then bind a workspace later for file tools."))
                    } else {
                        ForEach(workspaces) { workspace in
                            Toggle(isOn: binding(for: workspace.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.name)
                                    Text(workspace.rootPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                Section("System Prompt") {
                    TextField("System Prompt", text: $draft.systemPrompt, axis: .vertical)
                        .lineLimit(5...10)
                }

                if draft.kind == .orchestrator {
                    OrchestrationEditorSection(
                        draft: $draft,
                        agents: agents,
                        workspaces: workspaces,
                        agentWorkspaceIDs: agentWorkspaceIDs
                    )
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.kind) { _, kind in
                applyDefaultPrompt(for: kind)
            }

            Divider()

            VStack(spacing: 10) {
                if let saveFeedback {
                    ActionFeedbackView(feedback: saveFeedback)
                }

                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button("Save") {
                        let result = onSave(draft)
                        saveFeedback = result
                        if result.kind == .success {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                                onSaved()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 700, height: 760)
    }

    private func binding(for workspaceID: Int64) -> Binding<Bool> {
        Binding {
            draft.workspaceIDs.contains(workspaceID)
        } set: { isSelected in
            if isSelected {
                draft.workspaceIDs.insert(workspaceID)
            } else {
                draft.workspaceIDs.remove(workspaceID)
            }
        }
    }

    private func applyDefaultPrompt(for kind: AgentKind) {
        let trimmed = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == AgentPromptDefaults.standard else { return }
        draft.systemPrompt = AgentPromptDefaults.systemPrompt(for: kind)
    }
}
