import AppKit
import Dispatch
import SwiftUI

struct WorkspacesView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var editorDraft: WorkspaceDraft?
    @State private var feedback: ActionFeedback?

    private var selectedWorkspace: Workspace? {
        appModel.workspaces.first { $0.id == appModel.selectedWorkspaceID }
    }

    var body: some View {
        HSplitView {
            workspaceListColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            WorkspaceDetailView(
                workspace: selectedWorkspace,
                feedback: feedback,
                onNew: { editorDraft = appModel.workspaceDraft() }
            )
            .frame(minWidth: 520)
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
                        editorDraft = appModel.workspaceDraft(for: selectedWorkspace)
                    }
                } label: {
                    Label("Edit Workspace", systemImage: "pencil")
                }
                .disabled(selectedWorkspace == nil)

                Button(role: .destructive) {
                    appModel.deleteSelectedWorkspace()
                    feedback = ActionFeedback(kind: .info, message: appModel.statusText)
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
                onSaved: { editorDraft = nil }
            )
        }
    }

    private var workspaceListColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Workspaces", systemImage: "folder")
                    .font(.headline)
                Spacer()
                Button {
                    editorDraft = appModel.workspaceDraft()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("New Workspace")
            }
            .padding(12)

            Divider()

            List(selection: $appModel.selectedWorkspaceID) {
                ForEach(appModel.workspaces) { workspace in
                    WorkspaceRow(workspace: workspace)
                        .tag(Optional(workspace.id))
                }
            }
            .overlay {
                if appModel.workspaces.isEmpty {
                    ContentUnavailableView(
                        "No Workspaces",
                        systemImage: "folder.badge.plus",
                        description: Text("Add a local folder before creating agents and sessions.")
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(workspace.name)
                .font(.headline)
                .lineLimit(1)
            Text(workspace.rootPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                WorkspacePermissionBadge(title: "Write", isEnabled: workspace.allowWrite)
                WorkspacePermissionBadge(title: "Git", isEnabled: workspace.gitEnabled)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct WorkspacePermissionBadge: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(isEnabled ? .green : .secondary)
    }
}

private struct WorkspaceDetailView: View {
    let workspace: Workspace?
    let feedback: ActionFeedback?
    let onNew: () -> Void

    var body: some View {
        if let workspace {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name)
                                .font(.largeTitle.weight(.semibold))
                                .lineLimit(1)
                            Text(workspace.rootPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }

                        Spacer()
                    }

                    if let feedback {
                        ActionFeedbackView(feedback: feedback)
                    }

                    WorkspaceDetailSection("Scope") {
                        WorkspaceDetailRow(title: "Include", value: workspace.includePatterns)
                        WorkspaceDetailRow(title: "Exclude", value: workspace.excludePatterns.isEmpty ? "None" : workspace.excludePatterns)
                    }

                    WorkspaceDetailSection("Permissions") {
                        WorkspaceDetailRow(title: "Write", value: workspace.allowWrite ? "Allowed" : "Blocked")
                        WorkspaceDetailRow(title: "Git", value: workspace.gitEnabled ? "Enabled" : "Disabled")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView {
                Label("Select a Workspace", systemImage: "folder")
            } description: {
                Text("Workspaces define the local folders agents can read and propose changes for.")
            } actions: {
                Button {
                    onNew()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
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
