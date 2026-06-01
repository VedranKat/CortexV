import AppKit
import Dispatch
import SwiftUI

struct WorkspacesView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var route: WorkspaceRoute = .library
    @State private var editorDraft: WorkspaceDraft?
    @State private var pendingDelete: Workspace?
    @State private var feedback: ActionFeedback?

    private var selectedWorkspace: Workspace? {
        switch route {
        case .library:
            return appModel.selectedWorkspaceID.flatMap { id in
                appModel.workspaces.first { $0.id == id }
            }
        case .workspace(let id):
            return appModel.workspaces.first { $0.id == id }
        }
    }

    var body: some View {
        Group {
            switch route {
            case .library:
                WorkspaceLibraryView(
                    workspaces: appModel.workspaces,
                    summaries: summariesByWorkspaceID,
                    onOpen: openWorkspace,
                    onNew: { editorDraft = appModel.workspaceDraft() },
                    onEdit: edit,
                    onDelete: { pendingDelete = $0 }
                )
            case .workspace:
                if let workspace = selectedWorkspace {
                    WorkspaceControlRoomView(
                        workspace: workspace,
                        summary: summary(for: workspace),
                        boundAgents: boundAgents(for: workspace),
                        recentSessions: recentSessions(for: workspace),
                        pendingChanges: pendingChanges(for: workspace),
                        feedback: feedback,
                        onBack: { route = .library },
                        onNewSession: { startSession(in: workspace) },
                        onReveal: { reveal(workspace) },
                        onOpenAgent: openAgent,
                        onOpenSession: openSession,
                        onEdit: { edit(workspace) },
                        onDelete: { pendingDelete = workspace }
                    )
                } else {
                    ContentUnavailableView {
                        Label("Workspace Not Found", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("This workspace may have been deleted.")
                    } actions: {
                        Button("Back to Library") {
                            route = .library
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editorDraft = appModel.workspaceDraft()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }

                Button {
                    if let selectedWorkspace {
                        edit(selectedWorkspace)
                    }
                } label: {
                    Label("Edit Workspace", systemImage: "pencil")
                }
                .disabled(selectedWorkspace == nil)

                Button(role: .destructive) {
                    if let selectedWorkspace {
                        pendingDelete = selectedWorkspace
                    }
                } label: {
                    Label("Delete Workspace", systemImage: "trash")
                }
                .disabled(selectedWorkspace == nil)
            }
        }
        .sheet(item: $editorDraft) { draft in
            WorkspaceEditorSheet(
                draft: draft,
                onCancel: { editorDraft = nil },
                onSave: { draft in
                    let saved = appModel.saveWorkspace(draft)
                    let result = ActionFeedback(kind: saved ? .success : .error, message: appModel.statusText)
                    feedback = result
                    return result
                },
                onSaved: {
                    editorDraft = nil
                    if let id = appModel.selectedWorkspaceID {
                        route = .workspace(id)
                    }
                }
            )
        }
        .alert("Delete Workspace?", isPresented: deleteBinding, presenting: pendingDelete) { workspace in
            Button("Delete", role: .destructive) {
                delete(workspace)
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { workspace in
            let summary = summary(for: workspace)
            Text("This detaches \(summary.boundAgentCount) agent\(summary.boundAgentCount == 1 ? "" : "s") and clears this workspace from \(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s").")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding {
            pendingDelete != nil
        } set: { isPresented in
            if !isPresented {
                pendingDelete = nil
            }
        }
    }

    private var summariesByWorkspaceID: [Int64: WorkspaceSummary] {
        Dictionary(uniqueKeysWithValues: appModel.workspaces.map { workspace in
            (workspace.id, summary(for: workspace))
        })
    }

    private func summary(for workspace: Workspace) -> WorkspaceSummary {
        let sessions = appModel.sessions.filter { $0.workspaceID == workspace.id && !$0.attachedChildRun }
        return WorkspaceSummary(
            workspaceID: workspace.id,
            boundAgentCount: boundAgents(for: workspace).count,
            sessionCount: sessions.count,
            pendingChangeCount: pendingChanges(for: workspace).count,
            folderExists: folderExists(workspace),
            lastSessionDate: sessions.map(\.startedAt).max()
        )
    }

    private func boundAgents(for workspace: Workspace) -> [Agent] {
        appModel.agents
            .filter { agent in
                appModel.agentWorkspaceIDs[agent.id]?.contains(workspace.id) == true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func recentSessions(for workspace: Workspace) -> [Session] {
        appModel.sessions
            .filter { $0.workspaceID == workspace.id && !$0.attachedChildRun }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(6)
            .map { $0 }
    }

    private func pendingChanges(for workspace: Workspace) -> [FileChange] {
        let changeSetsByID = Dictionary(uniqueKeysWithValues: appModel.allChangeSets.map { ($0.id, $0) })
        return appModel.allFileChanges.filter { change in
            change.pending && changeSetsByID[change.changeSetID]?.workspaceID == workspace.id
        }
    }

    private func folderExists(_ workspace: Workspace) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: workspace.rootPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func openWorkspace(_ workspace: Workspace) {
        appModel.selectedWorkspaceID = workspace.id
        route = .workspace(workspace.id)
    }

    private func edit(_ workspace: Workspace) {
        appModel.selectedWorkspaceID = workspace.id
        editorDraft = appModel.workspaceDraft(for: workspace)
    }

    private func delete(_ workspace: Workspace) {
        appModel.selectedWorkspaceID = workspace.id
        appModel.deleteSelectedWorkspace()
        feedback = ActionFeedback(kind: .info, message: appModel.statusText)
        pendingDelete = nil
        route = .library
    }

    private func startSession(in workspace: Workspace) {
        appModel.selectedWorkspaceID = workspace.id
        appModel.selectSession(id: nil)
        appModel.selectedSection = .sessions
    }

    private func reveal(_ workspace: Workspace) {
        NSWorkspace.shared.open(URL(fileURLWithPath: workspace.rootPath, isDirectory: true))
    }

    private func openAgent(_ agent: Agent) {
        appModel.selectedAgentID = agent.id
        appModel.pendingCommand = .openSelectedAgent
        appModel.selectedSection = .agents
    }

    private func openSession(_ session: Session) {
        appModel.selectedSection = .sessions
        appModel.selectSession(id: session.id)
    }
}

private enum WorkspaceRoute: Hashable {
    case library
    case workspace(Int64)
}

private struct WorkspaceSummary {
    let workspaceID: Int64
    let boundAgentCount: Int
    let sessionCount: Int
    let pendingChangeCount: Int
    let folderExists: Bool
    let lastSessionDate: Date?
}

private struct WorkspaceLibraryView: View {
    let workspaces: [Workspace]
    let summaries: [Int64: WorkspaceSummary]
    let onOpen: (Workspace) -> Void
    let onNew: () -> Void
    let onEdit: (Workspace) -> Void
    let onDelete: (Workspace) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Workspace Library")
                            .font(.largeTitle.weight(.semibold))
                        Text("\(workspaces.count) local project root\(workspaces.count == 1 ? "" : "s") available to agents")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onNew) {
                        Label("New Workspace", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(workspaces) { workspace in
                        WorkspaceLibraryCard(
                            workspace: workspace,
                            summary: summaries[workspace.id] ?? .empty(workspaceID: workspace.id),
                            onOpen: { onOpen(workspace) },
                            onEdit: { onEdit(workspace) },
                            onDelete: { onDelete(workspace) }
                        )
                    }

                    WorkspaceCreateCard(onCreate: onNew)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if workspaces.isEmpty {
                ContentUnavailableView {
                    Label("No Workspaces", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a local folder to give agents scoped file access.")
                } actions: {
                    Button(action: onNew) {
                        Label("New Workspace", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private extension WorkspaceSummary {
    static func empty(workspaceID: Int64) -> WorkspaceSummary {
        WorkspaceSummary(
            workspaceID: workspaceID,
            boundAgentCount: 0,
            sessionCount: 0,
            pendingChangeCount: 0,
            folderExists: false,
            lastSessionDate: nil
        )
    }
}

private struct WorkspaceLibraryCard: View {
    @State private var isHovering = false
    let workspace: Workspace
    let summary: WorkspaceSummary
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summary.folderExists ? "folder" : "folder.badge.questionmark")
                    .font(.system(size: 29, weight: .semibold))
                    .frame(width: 62, height: 62)
                    .foregroundStyle(summary.folderExists ? Color.accentColor : Color.orange)
                    .background((summary.folderExists ? Color.accentColor : Color.orange).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(summary.boundAgentCount)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("Agents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Menu {
                    Button(action: onEdit) {
                        Label("Edit Workspace", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Workspace", systemImage: "trash")
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

            VStack(alignment: .leading, spacing: 7) {
                Text(workspace.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(workspace.rootPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                WorkspaceStatusChip(text: workspace.allowWrite ? "Write allowed" : "Read only", systemImage: workspace.allowWrite ? "pencil" : "lock", tint: workspace.allowWrite ? .secondary : .secondary)
                WorkspaceStatusChip(text: workspace.gitEnabled ? "Git enabled" : "Git off", systemImage: "arrow.triangle.branch", tint: .secondary)
            }

            HStack(spacing: 10) {
                WorkspaceMiniMetric(value: summary.sessionCount, label: "Sessions")
                WorkspaceMiniMetric(value: summary.pendingChangeCount, label: "Pending")
                Spacer()
                if !summary.folderExists {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else if let lastSessionDate = summary.lastSessionDate {
                    Label(lastSessionDate.formatted(date: .abbreviated, time: .omitted), systemImage: "clock")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(18)
        .frame(minHeight: 238, alignment: .topLeading)
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
    }
}

private struct WorkspaceCreateCard: View {
    @State private var isHovering = false
    let onCreate: () -> Void

    var body: some View {
        Button(action: onCreate) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("New Workspace")
                        .font(.title3.weight(.semibold))
                    Text("Add a local project folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("Choose folder", systemImage: "folder.badge.plus")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(18)
            .frame(minHeight: 238, alignment: .topLeading)
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

private struct WorkspaceControlRoomView: View {
    let workspace: Workspace
    let summary: WorkspaceSummary
    let boundAgents: [Agent]
    let recentSessions: [Session]
    let pendingChanges: [FileChange]
    let feedback: ActionFeedback?
    let onBack: () -> Void
    let onNewSession: () -> Void
    let onReveal: () -> Void
    let onOpenAgent: (Agent) -> Void
    let onOpenSession: (Session) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspaceDetailHeader(
                    workspace: workspace,
                    summary: summary,
                    onBack: onBack,
                    onNewSession: onNewSession,
                    onReveal: onReveal,
                    onEdit: onEdit,
                    onDelete: onDelete
                )

                if let feedback {
                    ActionFeedbackView(feedback: feedback)
                }

                HStack(spacing: 8) {
                    WorkspaceDashboardMetric(label: "Agents", value: summary.boundAgentCount, systemImage: "person.2")
                    WorkspaceDashboardMetric(label: "Sessions", value: summary.sessionCount, systemImage: "bubble.left.and.bubble.right")
                    WorkspaceDashboardMetric(label: "Pending", value: summary.pendingChangeCount, systemImage: "doc.text.magnifyingglass")
                    WorkspaceDashboardMetric(label: summary.folderExists ? "Folder OK" : "Missing", value: nil, systemImage: summary.folderExists ? "checkmark.circle" : "exclamationmark.triangle.fill")
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        WorkspaceDetailSection("Bound Agents") {
                            if boundAgents.isEmpty {
                                Text("No agents are bound to this workspace yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(boundAgents) { agent in
                                    WorkspaceAgentRow(agent: agent) {
                                        onOpenAgent(agent)
                                    }
                                }
                            }
                        }

                        WorkspaceDetailSection("Recent Sessions") {
                            if recentSessions.isEmpty {
                                Text("No sessions have used this workspace yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(recentSessions) { session in
                                    WorkspaceSessionRow(session: session) {
                                        onOpenSession(session)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        WorkspaceDetailSection("Permissions") {
                            WorkspaceDetailRow(title: "Read", value: workspace.allowRead ? "Allowed" : "Blocked")
                            WorkspaceDetailRow(title: "Write", value: workspace.allowWrite ? "Allowed" : "Blocked")
                            WorkspaceDetailRow(title: "Git", value: workspace.gitEnabled ? "Enabled" : "Disabled")
                        }

                        WorkspaceDetailSection("Scope Rules") {
                            WorkspaceDetailRow(title: "Include", value: workspace.includePatterns)
                            WorkspaceDetailRow(title: "Exclude", value: workspace.excludePatterns.isEmpty ? "None" : workspace.excludePatterns)
                        }

                        WorkspaceDetailSection("Pending Changes") {
                            if pendingChanges.isEmpty {
                                Text("No pending changes target this workspace.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(pendingChanges.prefix(6)) { change in
                                    HStack {
                                        Text(change.filePath)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text(change.status.capitalized)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.orange)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 380)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct WorkspaceDetailHeader: View {
    let workspace: Workspace
    let summary: WorkspaceSummary
    let onBack: () -> Void
    let onNewSession: () -> Void
    let onReveal: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .help("Back")
            .buttonStyle(.borderless)
            .frame(width: 30, height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Image(systemName: summary.folderExists ? "folder" : "folder.badge.questionmark")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 48, height: 48)
                .foregroundStyle(summary.folderExists ? Color.accentColor : Color.orange)
                .background((summary.folderExists ? Color.accentColor : Color.orange).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                Text(workspace.rootPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(action: onNewSession) {
                Label("New Session", systemImage: "plus.bubble")
            }
            .buttonStyle(.borderedProminent)

            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(!summary.folderExists)

            Menu {
                Button(action: onEdit) {
                    Label("Edit Workspace", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Workspace", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

private struct WorkspaceDashboardMetric: View {
    let label: String
    let value: Int?
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if let value {
                Text("\(value)")
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.26), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WorkspaceMiniMetric: View {
    let value: Int
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WorkspaceStatusChip: View {
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
            .background(tint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct WorkspaceAgentRow: View {
    let agent: Agent
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: agent.orchestrator ? "person.2.badge.gearshape" : "person.crop.circle")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(agent.orchestrator ? Color.accentColor : Color.secondary)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(agent.model.isEmpty ? "Model not set" : agent.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(agent.status.rawValue.capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceSessionRow: View {
    let session: Session
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.summary.isEmpty ? "Session #\(session.id)" : session.summary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(session.status.rawValue.capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceDetailSection<Content: View>: View {
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

private struct WorkspaceDetailRow: View {
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

private struct WorkspaceEditorSheet: View {
    @State private var draft: WorkspaceDraft
    @State private var saveFeedback: ActionFeedback?
    let onCancel: () -> Void
    let onSave: (WorkspaceDraft) -> ActionFeedback
    let onSaved: () -> Void

    init(
        draft: WorkspaceDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (WorkspaceDraft) -> ActionFeedback,
        onSaved: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSave = onSave
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.id == nil ? "New Workspace" : "Edit Workspace")
                    .font(.title2.weight(.semibold))
                Text("Local folder, file scope, and write proposal permissions.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                    HStack {
                        TextField("Root Path", text: $draft.rootPath)
                        Button {
                            chooseFolder()
                        } label: {
                            Label("Choose", systemImage: "folder")
                        }
                    }
                }

                Section("Scope") {
                    TextField("Include Patterns", text: $draft.includePatterns)
                    TextField("Exclude Patterns", text: $draft.excludePatterns)
                }

                Section("Permissions") {
                    Toggle("Allow write proposals and approved writes", isOn: $draft.allowWrite)
                    Toggle("Git integration enabled", isOn: $draft.gitEnabled)
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
        .frame(width: 680, height: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: draft.rootPath)

        if panel.runModal() == .OK, let url = panel.url {
            draft.rootPath = url.path
        }
    }
}
