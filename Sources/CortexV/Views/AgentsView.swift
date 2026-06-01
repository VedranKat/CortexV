import Dispatch
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var route: AgentConsoleRoute = .hub
    @State private var selectedGroup: AgentGroupSelection = .all
    @State private var agentSearchText = ""
    @State private var filter: AgentConsoleFilter = .all
    @State private var editorDraft: AgentDraft?
    @State private var templateDraft: AgentTemplateDraft?
    @State private var propagationDraft: AgentTemplatePropagationDraft?
    @State private var templatePushAfterSaveID: Int64?
    @State private var pendingTemplateDelete: AgentTemplate?
    @State private var feedback: ActionFeedback?

    private var selectedAgent: Agent? {
        guard let selectedAgentID = appModel.selectedAgentID else { return nil }
        return appModel.agents.first { $0.id == selectedAgentID }
    }

    private var selectedTemplate: AgentTemplate? {
        guard case .group(.template(_)) = route else { return nil }
        guard case .template(let id) = selectedGroup else { return nil }
        return appModel.agentTemplates.first { $0.id == id }
    }

    private var knownTemplateIDs: Set<Int64> {
        Set(appModel.agentTemplates.map(\.id))
    }

    private var templatesByID: [Int64: AgentTemplate] {
        Dictionary(uniqueKeysWithValues: appModel.agentTemplates.map { ($0.id, $0) })
    }

    private var agentsInSelectedGroup: [Agent] {
        agents(for: selectedGroup)
    }

    private var visibleAgents: [Agent] {
        agentsInSelectedGroup
            .filter(matchesSearch)
            .filter(filter.matches)
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var detailAgent: Agent? {
        guard case .group = route else { return nil }
        guard let selectedAgent,
              agentsInSelectedGroup.contains(where: { $0.id == selectedAgent.id })
        else {
            return nil
        }
        return selectedAgent
    }

    private var selectedBoundWorkspaces: [Workspace] {
        appModel.boundWorkspaces(for: detailAgent?.id)
    }

    var body: some View {
        Group {
            switch route {
            case .hub:
                AgentHubView(
                    templates: appModel.agentTemplates,
                    agents: appModel.agents,
                    knownTemplateIDs: knownTemplateIDs,
                    templatesByID: templatesByID,
                    onOpen: enterGroup,
                    onNewAgent: { editorDraft = newAgentDraft() },
                    onNewTemplate: { templateDraft = appModel.agentTemplateDraft() },
                    onEditTemplate: editTemplate,
                    onPushTemplate: pushTemplate,
                    onDeleteTemplate: confirmDeleteTemplate
                )
            case .group:
                AgentWorkspaceView(
                    group: selectedGroup,
                    selectedTemplate: selectedTemplate,
                    agents: visibleAgents,
                    groupAgents: agentsInSelectedGroup,
                    templatesByID: templatesByID,
                    selectedAgentID: appModel.selectedAgentID,
                    searchText: $agentSearchText,
                    filter: $filter,
                    selectedAgent: detailAgent,
                    boundWorkspaces: selectedBoundWorkspaces,
                    allAgents: appModel.agents,
                    allTemplates: appModel.agentTemplates,
                    allWorkspaces: appModel.workspaces,
                    agentWorkspaceIDs: appModel.agentWorkspaceIDs,
                    orchestrationMembers: appModel.orchestrationMembers(for: detailAgent?.id),
                    feedback: feedback,
                    onBack: returnToHub,
                    onSelectAgent: { appModel.selectedAgentID = $0.id },
                    onNewAgent: { editorDraft = newAgentDraft() },
                    onEditAgent: editSelectedAgent,
                    onCreateWorkspace: { appModel.selectedSection = .workspaces },
                    onCreateTemplateFromAgent: { agent in
                        templateDraft = appModel.agentTemplateDraft(from: agent)
                    },
                    onDetachAgent: detachSelectedAgent,
                    onEditTemplate: editSelectedTemplate,
                    onPushTemplate: pushSelectedTemplate,
                    onDeleteTemplate: confirmDeleteSelectedTemplate
                )
            }
        }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    templateDraft = appModel.agentTemplateDraft()
                } label: {
                    Label("New Template", systemImage: "rectangle.stack.badge.plus")
                }

                Button {
                    editorDraft = newAgentDraft()
                } label: {
                    Label("New Agent", systemImage: "plus")
                }

                Button {
                    editSelectedAgent()
                } label: {
                    Label("Edit Agent", systemImage: "pencil")
                }
                .disabled(detailAgent == nil)

                Button(role: .destructive) {
                    appModel.deleteSelectedAgent()
                    feedback = ActionFeedback(kind: .info, message: appModel.statusText)
                    reconcileSelection()
                } label: {
                    Label("Delete Agent", systemImage: "trash")
                }
                .disabled(detailAgent == nil)
            }
        }
        .sheet(item: $editorDraft) { draft in
            AgentEditorSheet(
                draft: draft,
                agents: appModel.agents,
                templates: appModel.agentTemplates,
                workspaces: appModel.workspaces,
                agentWorkspaceIDs: appModel.agentWorkspaceIDs,
                onCancel: { editorDraft = nil },
                onSave: { draft in
                    let saved = appModel.saveAgent(draft)
                    let result = ActionFeedback(kind: saved ? .success : .error, message: appModel.statusText)
                    feedback = result
                    return result
                },
                onSaved: {
                    editorDraft = nil
                    reconcileSelection()
                }
            )
        }
        .sheet(item: $templateDraft) { draft in
            AgentTemplateEditorSheet(
                draft: draft,
                linkedAgentCount: linkedAgents(for: draft.id).count,
                onCancel: { templateDraft = nil },
                onSave: { draft, openPush in
                    let saved = appModel.saveAgentTemplate(draft)
                    let result = ActionFeedback(kind: saved ? .success : .error, message: appModel.statusText)
                    feedback = result
                    if saved, openPush, let id = draft.id {
                        templatePushAfterSaveID = id
                    }
                    return result
                },
                onSaved: {
                    templateDraft = nil
                    if let id = templatePushAfterSaveID,
                       let template = appModel.agentTemplates.first(where: { $0.id == id }) {
                        DispatchQueue.main.async {
                            propagationDraft = appModel.agentTemplatePropagationDraft(for: template)
                            templatePushAfterSaveID = nil
                        }
                    }
                    reconcileSelection()
                }
            )
        }
        .sheet(item: $propagationDraft) { draft in
            if let template = appModel.agentTemplates.first(where: { $0.id == draft.templateID }) {
                AgentTemplatePropagationSheet(
                    draft: draft,
                    template: template,
                    agents: linkedAgents(for: template.id),
                    onCancel: { propagationDraft = nil },
                    onApply: { draft in
                        let pushed = appModel.pushAgentTemplate(draft)
                        let result = ActionFeedback(kind: pushed ? .success : .error, message: appModel.statusText)
                        feedback = result
                        return result
                    },
                    onApplied: {
                        propagationDraft = nil
                    }
                )
            } else {
                Text("Template no longer exists.")
                    .padding()
            }
        }
        .alert("Delete Template?", isPresented: templateDeleteBinding, presenting: pendingTemplateDelete) { template in
            Button("Detach and Delete", role: .destructive) {
                deleteTemplate(template)
            }
            Button("Cancel", role: .cancel) {
                pendingTemplateDelete = nil
            }
        } message: { template in
            let count = linkedAgents(for: template.id).count
            Text("This detaches \(count) linked agent\(count == 1 ? "" : "s"). Copied provider settings and prompts stay on those agents.")
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: selectedGroup) { _, _ in reconcileSelection() }
        .onChange(of: route) { _, _ in reconcileSelection() }
        .onChange(of: appModel.agents) { _, _ in reconcileSelection() }
        .onChange(of: appModel.agentTemplates) { _, _ in reconcileSelection() }
    }

    private var templateDeleteBinding: Binding<Bool> {
        Binding {
            pendingTemplateDelete != nil
        } set: { isPresented in
            if !isPresented {
                pendingTemplateDelete = nil
            }
        }
    }

    private func agents(for group: AgentGroupSelection) -> [Agent] {
        switch group {
        case .all:
            return appModel.agents
        case .uncategorized:
            return appModel.agents.filter { agent in
                guard let templateID = agent.templateID else { return true }
                return !knownTemplateIDs.contains(templateID)
            }
        case .template(let templateID):
            return appModel.agents.filter { $0.templateID == templateID }
        }
    }

    private func matchesSearch(_ agent: Agent) -> Bool {
        let query = agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [
            agent.name,
            agent.description,
            agent.baseURL,
            agent.model,
            agent.kind.title,
            templateName(for: agent.templateID)
        ]
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func templateName(for id: Int64?) -> String {
        guard let id else { return "Uncategorized" }
        return appModel.agentTemplates.first { $0.id == id }?.name ?? "Missing Template"
    }

    private func linkedAgents(for templateID: Int64?) -> [Agent] {
        guard let templateID else { return [] }
        return appModel.agents.filter { $0.templateID == templateID }
    }

    private func newAgentDraft() -> AgentDraft {
        if case .group(.template(_)) = route,
           let template = selectedTemplate {
            return appModel.agentDraft(template: template)
        }
        return appModel.agentDraft()
    }

    private func enterGroup(_ group: AgentGroupSelection) {
        selectedGroup = group
        route = .group(group)
        agentSearchText = ""
        filter = .all
        reconcileSelection()
    }

    private func returnToHub() {
        route = .hub
        appModel.selectedAgentID = nil
    }

    private func editSelectedAgent() {
        guard let detailAgent else { return }
        editorDraft = appModel.agentDraft(for: detailAgent)
    }

    private func editSelectedTemplate() {
        guard let selectedTemplate else { return }
        editTemplate(selectedTemplate)
    }

    private func pushSelectedTemplate() {
        guard let selectedTemplate else { return }
        pushTemplate(selectedTemplate)
    }

    private func confirmDeleteSelectedTemplate() {
        guard let selectedTemplate else { return }
        confirmDeleteTemplate(selectedTemplate)
    }

    private func editTemplate(_ template: AgentTemplate) {
        templateDraft = appModel.agentTemplateDraft(for: template)
    }

    private func pushTemplate(_ template: AgentTemplate) {
        propagationDraft = appModel.agentTemplatePropagationDraft(for: template)
    }

    private func confirmDeleteTemplate(_ template: AgentTemplate) {
        pendingTemplateDelete = template
    }

    private func deleteTemplate(_ template: AgentTemplate) {
        let deleted = appModel.deleteAgentTemplate(id: template.id)
        feedback = ActionFeedback(kind: deleted ? .success : .error, message: appModel.statusText)
        pendingTemplateDelete = nil
        if case .template(let id) = selectedGroup, id == template.id {
            selectedGroup = .all
            route = .hub
        }
        reconcileSelection()
    }

    private func detachSelectedAgent() {
        guard let detailAgent else { return }
        let detached = appModel.linkAgent(detailAgent.id, toTemplate: nil)
        feedback = ActionFeedback(kind: detached ? .success : .error, message: appModel.statusText)
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard case .group = route else { return }

        if case .template(let id) = selectedGroup,
           !appModel.agentTemplates.contains(where: { $0.id == id }) {
            selectedGroup = .all
            route = .hub
            return
        }

        let groupAgents = agents(for: selectedGroup)
        if let selectedAgent,
           groupAgents.contains(where: { $0.id == selectedAgent.id }) {
            return
        }
        appModel.selectedAgentID = groupAgents.first?.id
    }
}

private enum AgentGroupSelection: Hashable {
    case all
    case uncategorized
    case template(Int64)
}

private enum AgentConsoleRoute: Hashable {
    case hub
    case group(AgentGroupSelection)
}

private struct AgentHubView: View {
    let templates: [AgentTemplate]
    let agents: [Agent]
    let knownTemplateIDs: Set<Int64>
    let templatesByID: [Int64: AgentTemplate]
    let onOpen: (AgentGroupSelection) -> Void
    let onNewAgent: () -> Void
    let onNewTemplate: () -> Void
    let onEditTemplate: (AgentTemplate) -> Void
    let onPushTemplate: (AgentTemplate) -> Void
    let onDeleteTemplate: (AgentTemplate) -> Void

    private var uncategorizedAgents: [Agent] {
        agents.filter { agent in
            guard let templateID = agent.templateID else { return true }
            return !knownTemplateIDs.contains(templateID)
        }
    }

    private var linkedAgents: [Agent] {
        agents.filter { agent in
            guard let templateID = agent.templateID else { return false }
            return knownTemplateIDs.contains(templateID)
        }
    }

    private var missingKeyCount: Int {
        agents.filter { $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var overrideCount: Int {
        linkedAgents.filter { hasOverrides($0) }.count
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Agents")
                            .font(.largeTitle.weight(.semibold))
                        Text("\(agents.count) agent\(agents.count == 1 ? "" : "s") across \(templates.count) template\(templates.count == 1 ? "" : "s")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onNewAgent) {
                        Label("New Agent", systemImage: "plus")
                    }
                    .controlSize(.large)

                    Button(action: onNewTemplate) {
                        Label("New Template", systemImage: "rectangle.stack.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                HStack(spacing: 8) {
                    AgentMetric(label: "Agents", value: agents.count, systemImage: "person.2")
                    AgentMetric(label: "Templates", value: templates.count, systemImage: "rectangle.stack")
                    AgentMetric(label: "Missing Key", value: missingKeyCount, systemImage: "key.slash")
                    AgentMetric(label: "Overrides", value: overrideCount, systemImage: "slider.horizontal.3")
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    AgentHubTile(
                        title: "All Agents",
                        subtitle: "Every model endpoint",
                        systemImage: "person.3.sequence",
                        count: agents.count,
                        statusText: "\(agents.filter(\.enabled).count) enabled",
                        warningCount: missingKeyCount,
                        overrideCount: overrideCount,
                        updatedText: nil,
                        tint: .accentColor,
                        onOpen: { onOpen(.all) }
                    )

                    AgentHubTile(
                        title: "Uncategorized",
                        subtitle: "Independent settings",
                        systemImage: "tray",
                        count: uncategorizedAgents.count,
                        statusText: "\(uncategorizedAgents.filter(\.enabled).count) enabled",
                        warningCount: uncategorizedAgents.filter { $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
                        overrideCount: 0,
                        updatedText: nil,
                        tint: .secondary,
                        onOpen: { onOpen(.uncategorized) }
                    )

                    ForEach(templates) { template in
                        let linked = agents.filter { $0.templateID == template.id }
                        AgentHubTile(
                            title: template.name,
                            subtitle: template.baseURL.isEmpty ? "Base URL not set" : template.baseURL,
                            systemImage: "rectangle.stack.badge.person.crop",
                            count: linked.count,
                            statusText: template.hasAPIKey ? "Key set" : "Missing key",
                            warningCount: templateWarningCount(template, linkedAgents: linked),
                            overrideCount: linked.filter { hasOverrides($0, template: template) }.count,
                            updatedText: template.updatedAt.formatted(date: .abbreviated, time: .omitted),
                            tint: tint(for: template),
                            onOpen: { onOpen(.template(template.id)) },
                            onEdit: { onEditTemplate(template) },
                            onPush: linked.isEmpty ? nil : { onPushTemplate(template) },
                            onDelete: { onDeleteTemplate(template) }
                        )
                    }

                    AgentCreateTemplateTile(onCreate: onNewTemplate)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func tint(for template: AgentTemplate) -> Color {
        .accentColor
    }

    private func templateWarningCount(_ template: AgentTemplate, linkedAgents: [Agent]) -> Int {
        (template.hasAPIKey ? 0 : 1) + linkedAgents.filter { $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private func hasOverrides(_ agent: Agent) -> Bool {
        guard let templateID = agent.templateID,
              let template = templatesByID[templateID]
        else {
            return false
        }
        return hasOverrides(agent, template: template)
    }

    private func hasOverrides(_ agent: Agent, template: AgentTemplate) -> Bool {
        agent.baseURL != template.baseURL ||
            agent.apiKey != template.apiKey ||
            agent.model != template.defaultModel ||
            agent.systemPrompt != template.systemPrompt ||
            agent.temperature != template.temperature ||
            agent.kind != template.kind
    }
}

private struct AgentHubTile: View {
    @State private var isHovering = false
    let title: String
    let subtitle: String
    let systemImage: String
    let count: Int
    let statusText: String
    let warningCount: Int
    let overrideCount: Int
    let updatedText: String?
    let tint: Color
    let onOpen: () -> Void
    var onEdit: (() -> Void)?
    var onPush: (() -> Void)?
    var onDelete: (() -> Void)?

    private var hasMenu: Bool {
        onEdit != nil || onPush != nil || onDelete != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.08))
                    Image(systemName: systemImage)
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 62, height: 62)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(count)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("Agents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if hasMenu {
                    Menu {
                        if let onEdit {
                            Button(action: onEdit) {
                                Label("Edit Template", systemImage: "slider.horizontal.3")
                            }
                        }
                        if let onPush {
                            Button(action: onPush) {
                                Label("Push Template", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        if let onDelete {
                            Divider()
                            Button(role: .destructive, action: onDelete) {
                                Label("Delete Template", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(isHovering ? 0.06 : 0.0))
                            .clipShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                AgentStatusChip(text: statusText, systemImage: "key", tint: statusText == "Missing key" ? .orange : .secondary)
                AgentStatusChip(text: warningCount > 0 ? "\(warningCount) warning\(warningCount == 1 ? "" : "s")" : "Clean", systemImage: warningCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle", tint: warningCount > 0 ? .orange : .secondary)
            }

            HStack(spacing: 7) {
                if overrideCount > 0 {
                    Label("\(overrideCount) override\(overrideCount == 1 ? "" : "s")", systemImage: "slider.horizontal.3")
                        .foregroundStyle(.orange)
                }

                Spacer()

                if let updatedText {
                    Label(updatedText, systemImage: "clock")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.weight(.medium))
            .frame(minHeight: 18)
        }
        .padding(18)
        .frame(minHeight: 232, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovering ? Color.accentColor.opacity(0.28) : Color(nsColor: .separatorColor).opacity(0.34), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: isHovering ? Color.black.opacity(0.05) : Color.clear, radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

private struct AgentCreateTemplateTile: View {
    @State private var isHovering = false
    let onCreate: () -> Void

    var body: some View {
        Button(action: onCreate) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("New Template")
                        .font(.title3.weight(.semibold))
                    Text("Provider defaults")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("Add provider defaults", systemImage: "rectangle.stack.badge.plus")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(18)
            .frame(minHeight: 232, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(isHovering ? 0.38 : 0.24), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: isHovering ? Color.black.opacity(0.04) : Color.clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct AgentStatusChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AgentTileStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AgentWorkspaceView: View {
    let group: AgentGroupSelection
    let selectedTemplate: AgentTemplate?
    let agents: [Agent]
    let groupAgents: [Agent]
    let templatesByID: [Int64: AgentTemplate]
    let selectedAgentID: Int64?
    @Binding var searchText: String
    @Binding var filter: AgentConsoleFilter
    let selectedAgent: Agent?
    let boundWorkspaces: [Workspace]
    let allAgents: [Agent]
    let allTemplates: [AgentTemplate]
    let allWorkspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]
    let orchestrationMembers: [OrchestrationMember]
    let feedback: ActionFeedback?
    let onBack: () -> Void
    let onSelectAgent: (Agent) -> Void
    let onNewAgent: () -> Void
    let onEditAgent: () -> Void
    let onCreateWorkspace: () -> Void
    let onCreateTemplateFromAgent: (Agent) -> Void
    let onDetachAgent: () -> Void
    let onEditTemplate: () -> Void
    let onPushTemplate: () -> Void
    let onDeleteTemplate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgentWorkspaceHeader(
                group: group,
                selectedTemplate: selectedTemplate,
                agents: groupAgents,
                onBack: onBack,
                onNewAgent: onNewAgent,
                onEditTemplate: onEditTemplate,
                onPushTemplate: onPushTemplate,
                onDeleteTemplate: onDeleteTemplate
            )

            Divider()

            HSplitView {
                AgentCollectionPane(
                    group: group,
                    selectedTemplate: selectedTemplate,
                    agents: agents,
                    groupAgents: groupAgents,
                    templatesByID: templatesByID,
                    selectedAgentID: selectedAgentID,
                    showsHeader: false,
                    searchText: $searchText,
                    filter: $filter,
                    onSelectAgent: onSelectAgent,
                    onNewAgent: onNewAgent,
                    onEditTemplate: onEditTemplate,
                    onPushTemplate: onPushTemplate,
                    onDeleteTemplate: onDeleteTemplate
                )
                .frame(minWidth: 390, idealWidth: 520)

                AgentInspectorPane(
                    agent: selectedAgent,
                    template: selectedTemplate,
                    boundWorkspaces: boundWorkspaces,
                    allAgents: allAgents,
                    allTemplates: allTemplates,
                    allWorkspaces: allWorkspaces,
                    agentWorkspaceIDs: agentWorkspaceIDs,
                    orchestrationMembers: orchestrationMembers,
                    feedback: feedback,
                    onEditAgent: onEditAgent,
                    onNewAgent: onNewAgent,
                    onNewAgentFromTemplate: onNewAgent,
                    onCreateWorkspace: onCreateWorkspace,
                    onCreateTemplateFromAgent: onCreateTemplateFromAgent,
                    onDetachAgent: onDetachAgent,
                    onEditTemplate: onEditTemplate,
                    onPushTemplate: onPushTemplate,
                    onDeleteTemplate: onDeleteTemplate
                )
                .frame(minWidth: 460)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct AgentWorkspaceHeader: View {
    let group: AgentGroupSelection
    let selectedTemplate: AgentTemplate?
    let agents: [Agent]
    let onBack: () -> Void
    let onNewAgent: () -> Void
    let onEditTemplate: () -> Void
    let onPushTemplate: () -> Void
    let onDeleteTemplate: () -> Void

    private var title: String {
        switch group {
        case .all:
            return "All Agents"
        case .uncategorized:
            return "Uncategorized"
        case .template:
            return selectedTemplate?.name ?? "Missing Template"
        }
    }

    private var subtitle: String {
        switch group {
        case .all:
            return "Agents"
        case .uncategorized:
            return "Independent provider settings"
        case .template:
            return selectedTemplate?.baseURL.isEmpty == false ? selectedTemplate?.baseURL ?? "Template" : "Template"
        }
    }

    private var missingKeyCount: Int {
        agents.filter { $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .help("Back")
            .buttonStyle(.borderless)
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Agents")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(title)
                }
                .font(.title2.weight(.semibold))
                .lineLimit(1)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                AgentMetric(label: "Agents", value: agents.count, systemImage: "person.2")
                AgentMetric(label: "Enabled", value: agents.filter(\.enabled).count, systemImage: "checkmark.circle")
                AgentMetric(label: "Missing Key", value: missingKeyCount, systemImage: "key.slash")
            }

            Button(action: onNewAgent) {
                Label(selectedTemplate == nil ? "New Agent" : "New from Template", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            if selectedTemplate != nil {
                Menu {
                    Button(action: onEditTemplate) {
                        Label("Edit Template", systemImage: "slider.horizontal.3")
                    }
                    Button(action: onPushTemplate) {
                        Label("Push Template", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(agents.isEmpty)
                    Divider()
                    Button(role: .destructive, action: onDeleteTemplate) {
                        Label("Delete Template", systemImage: "trash")
                    }
                } label: {
                    Label("Template", systemImage: "ellipsis.circle")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }
}

private enum AgentConsoleFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case disabled
    case standard
    case orchestrator
    case missingAPIKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .standard: "Standard"
        case .orchestrator: "Orchestrators"
        case .missingAPIKey: "Missing Key"
        }
    }

    func matches(_ agent: Agent) -> Bool {
        switch self {
        case .all:
            return true
        case .enabled:
            return agent.enabled
        case .disabled:
            return !agent.enabled
        case .standard:
            return agent.kind == .standard
        case .orchestrator:
            return agent.kind == .orchestrator
        case .missingAPIKey:
            return agent.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private struct AgentTemplateRail: View {
    let templates: [AgentTemplate]
    let agents: [Agent]
    let knownTemplateIDs: Set<Int64>
    let selectedGroup: AgentGroupSelection
    let onSelect: (AgentGroupSelection) -> Void
    let onNewTemplate: () -> Void

    private var uncategorizedCount: Int {
        agents.filter { agent in
            guard let templateID = agent.templateID else { return true }
            return !knownTemplateIDs.contains(templateID)
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Templates", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Button(action: onNewTemplate) {
                    Label("New Template", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("New Template")
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    AgentTemplateRailRow(
                        title: "All Agents",
                        subtitle: "Every configured agent",
                        systemImage: "person.3.sequence",
                        count: agents.count,
                        warningCount: agents.filter { $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
                        isSelected: selectedGroup == .all,
                        onSelect: { onSelect(.all) }
                    )

                    AgentTemplateRailRow(
                        title: "Uncategorized",
                        subtitle: "No template link",
                        systemImage: "tray",
                        count: uncategorizedCount,
                        warningCount: 0,
                        isSelected: selectedGroup == .uncategorized,
                        onSelect: { onSelect(.uncategorized) }
                    )

                    if !templates.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(templates) { template in
                        let linkedAgents = agents.filter { $0.templateID == template.id }
                        AgentTemplateRailRow(
                            title: template.name,
                            subtitle: template.baseURL.isEmpty ? "Base URL not set" : template.baseURL,
                            systemImage: "rectangle.stack.badge.person.crop",
                            count: linkedAgents.count,
                            warningCount: template.hasAPIKey ? 0 : 1,
                            isSelected: selectedGroup == .template(template.id),
                            onSelect: { onSelect(.template(template.id)) }
                        )
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AgentTemplateRailRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let count: Int
    let warningCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .background((isSelected ? Color.accentColor : Color.secondary).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    if warningCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(9)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct AgentCollectionPane: View {
    let group: AgentGroupSelection
    let selectedTemplate: AgentTemplate?
    let agents: [Agent]
    let groupAgents: [Agent]
    let templatesByID: [Int64: AgentTemplate]
    let selectedAgentID: Int64?
    var showsHeader = true
    @Binding var searchText: String
    @Binding var filter: AgentConsoleFilter
    let onSelectAgent: (Agent) -> Void
    let onNewAgent: () -> Void
    let onEditTemplate: () -> Void
    let onPushTemplate: () -> Void
    let onDeleteTemplate: () -> Void

    private var enabledCount: Int {
        groupAgents.filter(\.enabled).count
    }

    private var missingKeyCount: Int {
        groupAgents.filter { $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var headerTitle: String {
        switch group {
        case .all:
            return "All Agents"
        case .uncategorized:
            return "Uncategorized"
        case .template:
            return selectedTemplate?.name ?? "Missing Template"
        }
    }

    private var headerSubtitle: String {
        switch group {
        case .all:
            return "Manage every configured agent and model endpoint."
        case .uncategorized:
            return "Agents with independent provider settings."
        case .template:
            if let selectedTemplate {
                return selectedTemplate.baseURL.isEmpty ? "Template base URL is not set." : selectedTemplate.baseURL
            }
            return "This template no longer exists."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(headerTitle)
                                .font(.title2.weight(.semibold))
                                .lineLimit(1)
                            Text(headerSubtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Button(action: onNewAgent) {
                            Label(selectedTemplate == nil ? "New Agent" : "New from Template", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    HStack(spacing: 8) {
                        AgentMetric(label: "Agents", value: groupAgents.count, systemImage: "person.2")
                        AgentMetric(label: "Enabled", value: enabledCount, systemImage: "checkmark.circle")
                        AgentMetric(label: "Missing Key", value: missingKeyCount, systemImage: "key.slash")
                    }

                    if selectedTemplate != nil {
                        HStack(spacing: 8) {
                            Button(action: onEditTemplate) {
                                Label("Edit Template", systemImage: "slider.horizontal.3")
                            }
                            Button(action: onPushTemplate) {
                                Label("Push Template", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(groupAgents.isEmpty)
                            Button(role: .destructive, action: onDeleteTemplate) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(18)

                Divider()
            }

            HStack(spacing: 10) {
                Label("Search", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                TextField("Search agents", text: $searchText)
                    .textFieldStyle(.plain)

                Picker("Filter", selection: $filter) {
                    ForEach(AgentConsoleFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(agents) { agent in
                        AgentConsoleRow(
                            agent: agent,
                            template: agent.templateID.flatMap { templatesByID[$0] },
                            overrideCount: overrideCount(for: agent),
                            isSelected: selectedAgentID == agent.id,
                            onSelect: { onSelectAgent(agent) }
                        )
                    }
                }
                .padding(12)
            }
            .overlay {
                if agents.isEmpty {
                    ContentUnavailableView(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Agents" : "No Matches",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text(emptyMessage)
                    )
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Adjust search or filters to show more agents."
        }
        if selectedTemplate != nil {
            return "Create an agent from this template to start grouping provider settings."
        }
        return "Create an agent or template to begin."
    }

    private func overrideCount(for agent: Agent) -> Int {
        guard let templateID = agent.templateID,
              let template = templatesByID[templateID]
        else {
            return 0
        }
        var count = 0
        if agent.baseURL != template.baseURL { count += 1 }
        if agent.apiKey != template.apiKey { count += 1 }
        if agent.model != template.defaultModel { count += 1 }
        if agent.systemPrompt != template.systemPrompt { count += 1 }
        if agent.temperature != template.temperature { count += 1 }
        if agent.kind != template.kind { count += 1 }
        return count
    }
}

private struct AgentMetric: View {
    let label: String
    let value: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("\(value)")
                .font(.callout.monospacedDigit().weight(.semibold))
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.26), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AgentConsoleRow: View {
    @State private var isHovering = false
    let agent: Agent
    let template: AgentTemplate?
    let overrideCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: agent.orchestrator ? "person.2.badge.gearshape" : "person.crop.circle")
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(agent.orchestrator ? Color.accentColor : Color.secondary)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(agent.name)
                            .font(.headline)
                            .lineLimit(1)

                        StatusPill(text: agent.status.rawValue.capitalized, tint: .secondary)
                    }

                    Text(agent.model.isEmpty ? "Model not set" : agent.model)
                        .font(.callout)
                        .foregroundStyle(agent.model.isEmpty ? .secondary : .primary)
                        .lineLimit(1)

                    HStack(spacing: 7) {
                        if let template {
                            Label(template.name, systemImage: "rectangle.stack")
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Label("Uncategorized", systemImage: "tray")
                                .foregroundStyle(.secondary)
                        }

                        if overrideCount > 0 {
                            Label("\(overrideCount) override\(overrideCount == 1 ? "" : "s")", systemImage: "slider.horizontal.3")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(agent.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(agent.orchestrator ? Color.accentColor : Color.secondary)

                    Label(
                        agent.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Missing" : "Key set",
                        systemImage: agent.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "key.slash" : "key"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(agent.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .orange : .secondary)
                }
            }
            .padding(12)
            .frame(minHeight: 86)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.42) : (isHovering ? Color.primary.opacity(0.13) : Color(nsColor: .separatorColor).opacity(0.30)), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: isHovering && !isSelected ? Color.black.opacity(0.035) : Color.clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct AgentInspectorPane: View {
    let agent: Agent?
    let template: AgentTemplate?
    let boundWorkspaces: [Workspace]
    let allAgents: [Agent]
    let allTemplates: [AgentTemplate]
    let allWorkspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]
    let orchestrationMembers: [OrchestrationMember]
    let feedback: ActionFeedback?
    let onEditAgent: () -> Void
    let onNewAgent: () -> Void
    let onNewAgentFromTemplate: () -> Void
    let onCreateWorkspace: () -> Void
    let onCreateTemplateFromAgent: (Agent) -> Void
    let onDetachAgent: () -> Void
    let onEditTemplate: () -> Void
    let onPushTemplate: () -> Void
    let onDeleteTemplate: () -> Void

    var body: some View {
        if let agent {
            AgentDetailInspector(
                agent: agent,
                template: template(for: agent.templateID),
                boundWorkspaces: boundWorkspaces,
                allAgents: allAgents,
                allTemplates: allTemplates,
                allWorkspaces: allWorkspaces,
                agentWorkspaceIDs: agentWorkspaceIDs,
                orchestrationMembers: orchestrationMembers,
                feedback: feedback,
                onEdit: onEditAgent,
                onCreateTemplate: { onCreateTemplateFromAgent(agent) },
                onDetach: onDetachAgent
            )
        } else if let template {
            AgentTemplateInspector(
                template: template,
                linkedAgents: allAgents.filter { $0.templateID == template.id },
                feedback: feedback,
                onNewAgent: onNewAgentFromTemplate,
                onEdit: onEditTemplate,
                onPush: onPushTemplate,
                onDelete: onDeleteTemplate
            )
        } else {
            ContentUnavailableView {
                Label("Select an Agent", systemImage: "person.crop.circle")
            } description: {
                Text("Agents define provider settings, prompts, orchestration, and workspace access.")
            } actions: {
                HStack {
                    Button(action: onCreateWorkspace) {
                        Label("Workspace", systemImage: "folder.badge.plus")
                    }

                    Button(action: onNewAgent) {
                        Label("New Agent", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func template(for id: Int64?) -> AgentTemplate? {
        guard let id else { return nil }
        return allTemplates.first { $0.id == id }
    }
}

private struct AgentDetailInspector: View {
    let agent: Agent
    let template: AgentTemplate?
    let boundWorkspaces: [Workspace]
    let allAgents: [Agent]
    let allTemplates: [AgentTemplate]
    let allWorkspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]
    let orchestrationMembers: [OrchestrationMember]
    let feedback: ActionFeedback?
    let onEdit: () -> Void
    let onCreateTemplate: () -> Void
    let onDetach: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: agent.orchestrator ? "person.2.badge.gearshape" : "person.crop.circle")
                        .font(.system(size: 28, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(agent.name)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(1)
                        Text(agent.model.isEmpty ? "Model not set" : agent.model)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let feedback {
                    ActionFeedbackView(feedback: feedback)
                }

                HStack(spacing: 8) {
                    StatusPill(text: agent.status.rawValue.capitalized, tint: agent.enabled ? .green : .secondary)
                    StatusPill(text: agent.kind.title, tint: agent.orchestrator ? .accentColor : .secondary)
                    if let template {
                        StatusPill(text: template.name, tint: .accentColor)
                    } else {
                        StatusPill(text: "Uncategorized", tint: .secondary)
                    }
                }

                AgentConsoleSection("Template") {
                    if let template {
                        DetailRow(title: "Source", value: template.name)
                        DetailRow(title: "Overrides", value: overrideSummary(template))
                        HStack {
                            Button(action: onDetach) {
                                Label("Detach", systemImage: "link.badge.minus")
                            }
                            Spacer()
                        }
                    } else {
                        Text("This agent keeps independent provider settings.")
                            .foregroundStyle(.secondary)
                        Button(action: onCreateTemplate) {
                            Label("Create Template from Agent", systemImage: "rectangle.stack.badge.plus")
                        }
                    }
                }

                AgentConsoleSection("Provider") {
                    DetailRow(title: "Base URL", value: agent.baseURL.isEmpty ? "Not set" : agent.baseURL)
                    DetailRow(title: "Model", value: agent.model.isEmpty ? "Not set" : agent.model)
                    DetailRow(title: "API Key", value: agent.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Missing" : "Set")
                    DetailRow(title: "Temperature", value: agent.temperature.formatted(.number.precision(.fractionLength(1))))
                    DetailRow(title: "Updated", value: agent.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                AgentConsoleSection("Bound Workspaces") {
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

                AgentConsoleSection("Description") {
                    Text(agent.description.isEmpty ? "No description" : agent.description)
                        .foregroundStyle(agent.description.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AgentConsoleSection("System Prompt") {
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
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func overrideSummary(_ template: AgentTemplate) -> String {
        var fields: [String] = []
        if agent.baseURL != template.baseURL { fields.append("Base URL") }
        if agent.apiKey != template.apiKey { fields.append("API Key") }
        if agent.model != template.defaultModel { fields.append("Model") }
        if agent.systemPrompt != template.systemPrompt { fields.append("Prompt") }
        if agent.temperature != template.temperature { fields.append("Temperature") }
        if agent.kind != template.kind { fields.append("Kind") }
        return fields.isEmpty ? "None" : fields.joined(separator: ", ")
    }
}

private struct AgentTemplateInspector: View {
    let template: AgentTemplate
    let linkedAgents: [Agent]
    let feedback: ActionFeedback?
    let onNewAgent: () -> Void
    let onEdit: () -> Void
    let onPush: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "rectangle.stack.badge.person.crop")
                        .font(.system(size: 28, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(template.name)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(1)
                        Text(template.description.isEmpty ? "Agent template" : template.description)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()
                }

                if let feedback {
                    ActionFeedbackView(feedback: feedback)
                }

                HStack(spacing: 8) {
                    Button(action: onNewAgent) {
                        Label("New Agent", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }

                    Button(action: onPush) {
                        Label("Push", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(linkedAgents.isEmpty)

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }

                HStack(spacing: 8) {
                    AgentMetric(label: "Linked", value: linkedAgents.count, systemImage: "link")
                    AgentMetric(label: "Enabled", value: linkedAgents.filter(\.enabled).count, systemImage: "checkmark.circle")
                    AgentMetric(label: "Overrides", value: linkedAgents.filter { hasOverrides($0) }.count, systemImage: "slider.horizontal.3")
                }

                AgentConsoleSection("Provider Defaults") {
                    DetailRow(title: "Base URL", value: template.baseURL.isEmpty ? "Not set" : template.baseURL)
                    DetailRow(title: "API Key", value: template.hasAPIKey ? "Set" : "Missing")
                    DetailRow(title: "Default Model", value: template.defaultModel.isEmpty ? "Not set" : template.defaultModel)
                }

                AgentConsoleSection("Agent Defaults") {
                    DetailRow(title: "Kind", value: template.kind.title)
                    DetailRow(title: "Temperature", value: template.temperature.formatted(.number.precision(.fractionLength(1))))
                    DetailRow(title: "Updated", value: template.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                AgentConsoleSection("System Prompt") {
                    Text(template.systemPrompt)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func hasOverrides(_ agent: Agent) -> Bool {
        agent.baseURL != template.baseURL ||
            agent.apiKey != template.apiKey ||
            agent.model != template.defaultModel ||
            agent.systemPrompt != template.systemPrompt ||
            agent.temperature != template.temperature ||
            agent.kind != template.kind
    }
}

private struct AgentConsoleSection<Content: View>: View {
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

private struct AgentTemplateEditorSheet: View {
    @State private var draft: AgentTemplateDraft
    @State private var saveFeedback: ActionFeedback?
    let linkedAgentCount: Int
    let onCancel: () -> Void
    let onSave: (AgentTemplateDraft, Bool) -> ActionFeedback
    let onSaved: () -> Void

    init(
        draft: AgentTemplateDraft,
        linkedAgentCount: Int,
        onCancel: @escaping () -> Void,
        onSave: @escaping (AgentTemplateDraft, Bool) -> ActionFeedback,
        onSaved: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.linkedAgentCount = linkedAgentCount
        self.onCancel = onCancel
        self.onSave = onSave
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.id == nil ? "New Template" : "Edit Template")
                    .font(.title2.weight(.semibold))
                Text("Defaults are copied into agents. Push selected fields when you want linked agents updated.")
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
                }

                Section("Provider Defaults") {
                    TextField("Base URL", text: $draft.baseURL)
                    SecureField("API Key", text: $draft.apiKey)
                    TextField("Default Model", text: $draft.defaultModel)
                }

                Section("Agent Defaults") {
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(AgentKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

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

                Section("System Prompt") {
                    TextField("System Prompt", text: $draft.systemPrompt, axis: .vertical)
                        .lineLimit(5...10)
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

                    if draft.id != nil && linkedAgentCount > 0 {
                        Button {
                            save(openPush: true)
                        } label: {
                            Label("Save & Push", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    Button("Save") {
                        save(openPush: false)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 680, height: 640)
    }

    private func save(openPush: Bool) {
        let result = onSave(draft, openPush)
        saveFeedback = result
        if result.kind == .success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                onSaved()
            }
        }
    }

    private func applyDefaultPrompt(for kind: AgentKind) {
        let trimmed = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == AgentPromptDefaults.standard else { return }
        draft.systemPrompt = AgentPromptDefaults.systemPrompt(for: kind)
    }
}

private struct AgentTemplatePropagationSheet: View {
    @State private var draft: AgentTemplatePropagationDraft
    @State private var saveFeedback: ActionFeedback?
    let template: AgentTemplate
    let agents: [Agent]
    let onCancel: () -> Void
    let onApply: (AgentTemplatePropagationDraft) -> ActionFeedback
    let onApplied: () -> Void

    init(
        draft: AgentTemplatePropagationDraft,
        template: AgentTemplate,
        agents: [Agent],
        onCancel: @escaping () -> Void,
        onApply: @escaping (AgentTemplatePropagationDraft) -> ActionFeedback,
        onApplied: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.template = template
        self.agents = agents
        self.onCancel = onCancel
        self.onApply = onApply
        self.onApplied = onApplied
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Push Template")
                    .font(.title2.weight(.semibold))
                Text("Apply selected \(template.name) fields to linked agents.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section("Fields") {
                    ForEach(AgentTemplatePropagationField.allCases) { field in
                        Toggle(isOn: fieldBinding(field)) {
                            Label(field.title, systemImage: field.systemImage)
                        }
                    }
                }

                Section("Agents") {
                    if agents.isEmpty {
                        Text("No linked agents.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(agents) { agent in
                            Toggle(isOn: agentBinding(agent.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                    Text(agent.model.isEmpty ? "Model not set" : agent.model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                Section("Template Values") {
                    DetailRow(title: "Base URL", value: template.baseURL.isEmpty ? "Not set" : template.baseURL)
                    DetailRow(title: "API Key", value: template.hasAPIKey ? "Set" : "Missing")
                    DetailRow(title: "Default Model", value: template.defaultModel.isEmpty ? "Not set" : template.defaultModel)
                    DetailRow(title: "Kind", value: template.kind.title)
                    DetailRow(title: "Temperature", value: template.temperature.formatted(.number.precision(.fractionLength(1))))
                }
            }
            .formStyle(.grouped)

            Divider()

            VStack(spacing: 10) {
                if let saveFeedback {
                    ActionFeedbackView(feedback: saveFeedback)
                }

                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button {
                        let result = onApply(draft)
                        saveFeedback = result
                        if result.kind == .success {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                                onApplied()
                            }
                        }
                    } label: {
                        Label("Apply to \(draft.agentIDs.count) Agent\(draft.agentIDs.count == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.fields.isEmpty || draft.agentIDs.isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 640, height: 640)
    }

    private func fieldBinding(_ field: AgentTemplatePropagationField) -> Binding<Bool> {
        Binding {
            draft.fields.contains(field)
        } set: { isSelected in
            if isSelected {
                draft.fields.insert(field)
            } else {
                draft.fields.remove(field)
            }
        }
    }

    private func agentBinding(_ agentID: Int64) -> Binding<Bool> {
        Binding {
            draft.agentIDs.contains(agentID)
        } set: { isSelected in
            if isSelected {
                draft.agentIDs.insert(agentID)
            } else {
                draft.agentIDs.remove(agentID)
            }
        }
    }
}

private struct AgentEditorSheet: View {
    @State private var draft: AgentDraft
    @State private var saveFeedback: ActionFeedback?
    let agents: [Agent]
    let templates: [AgentTemplate]
    let workspaces: [Workspace]
    let agentWorkspaceIDs: [Int64: Set<Int64>]
    let onCancel: () -> Void
    let onSave: (AgentDraft) -> ActionFeedback
    let onSaved: () -> Void

    init(
        draft: AgentDraft,
        agents: [Agent],
        templates: [AgentTemplate],
        workspaces: [Workspace],
        agentWorkspaceIDs: [Int64: Set<Int64>],
        onCancel: @escaping () -> Void,
        onSave: @escaping (AgentDraft) -> ActionFeedback,
        onSaved: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.agents = agents
        self.templates = templates
        self.workspaces = workspaces
        self.agentWorkspaceIDs = agentWorkspaceIDs
        self.onCancel = onCancel
        self.onSave = onSave
        self.onSaved = onSaved
    }

    private var selectedTemplate: AgentTemplate? {
        guard let templateID = draft.templateID else { return nil }
        return templates.first { $0.id == templateID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.id == nil ? "New Agent" : "Edit Agent")
                    .font(.title2.weight(.semibold))
                Text("Provider settings, prompt, templates, and workspace access.")
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

                Section("Template") {
                    Picker("Source", selection: $draft.templateID) {
                        Text("Uncategorized").tag(Optional<Int64>.none)
                        ForEach(templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }

                    if let selectedTemplate {
                        Text("This agent stores copied settings. Template edits affect it only when pushed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            applyTemplateDefaults(selectedTemplate)
                        } label: {
                            Label("Apply Template Defaults", systemImage: "arrow.down.doc")
                        }
                    } else {
                        Text("Uncategorized agents keep independent provider settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .frame(width: 700, height: 790)
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

    private func applyTemplateDefaults(_ template: AgentTemplate) {
        draft.baseURL = template.baseURL
        draft.apiKey = template.apiKey
        draft.model = template.defaultModel
        draft.systemPrompt = template.systemPrompt
        draft.temperature = template.temperature
        draft.kind = template.kind
        draft.templateID = template.id
    }

    private func applyDefaultPrompt(for kind: AgentKind) {
        let trimmed = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == AgentPromptDefaults.standard else { return }
        draft.systemPrompt = AgentPromptDefaults.systemPrompt(for: kind)
    }
}
