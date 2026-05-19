import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var collapsedWorkspaceIDs: Set<Int64> = []

    private var assignedSessionGroups: [WorkspaceSessionGroup] {
        appModel.workspaces.compactMap { workspace in
            let sessions = appModel.sessions.filter { $0.workspaceID == workspace.id }
            guard !sessions.isEmpty else { return nil }
            return WorkspaceSessionGroup(workspace: workspace, sessions: sessions)
        }
    }

    private var unassignedSessions: [Session] {
        let knownWorkspaceIDs = Set(appModel.workspaces.map(\.id))
        return appModel.sessions.filter { session in
            guard let workspaceID = session.workspaceID else { return true }
            return !knownWorkspaceIDs.contains(workspaceID)
        }
    }

    var body: some View {
        List {
            Section("Cortex V") {
                ForEach(NavigationSection.allCases) { section in
                    SidebarNavigationButton(
                        section: section,
                        count: count(for: section),
                        pendingReviewCount: section == .sessions ? appModel.snapshot.pendingChangesCount : 0,
                        isSelected: isSectionSelected(section)
                    ) {
                        select(section)
                    }
                }
            }

            ForEach(assignedSessionGroups) { group in
                Section {
                    DisclosureGroup(isExpanded: expandedBinding(for: group.workspace.id)) {
                        ForEach(group.sessions) { session in
                            SidebarSessionButton(
                                session: session,
                                isSelected: isSessionSelected(session),
                                agentName: appModel.agentName(for: session.agentID)
                            ) {
                                selectSession(session)
                            }
                        }
                    } label: {
                        WorkspaceGroupLabel(
                            workspace: group.workspace,
                            count: group.sessions.count,
                            onStartSession: {
                                startSession(in: group.workspace, sessions: group.sessions)
                            }
                        )
                    }
                }
            }

            if !unassignedSessions.isEmpty {
                Section("Chat Sessions") {
                    ForEach(unassignedSessions) { session in
                        SidebarSessionButton(
                            session: session,
                            isSelected: isSessionSelected(session),
                            agentName: appModel.agentName(for: session.agentID)
                        ) {
                            selectSession(session)
                        }
                    }
                }
            }

            if appModel.sessions.isEmpty {
                Section("Sessions") {
                    Text("No sessions yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        .onChange(of: appModel.pendingCommand) { _, command in
            guard command == .newSession else { return }
            select(.sessions)
            appModel.consumePendingCommand(.newSession)
        }
    }

    private func select(_ section: NavigationSection) {
        appModel.selectedSection = section
        if section == .sessions {
            appModel.selectedWorkspaceID = nil
            appModel.selectSession(id: nil)
        }
    }

    private func selectSession(_ session: Session) {
        appModel.selectedSection = .sessions
        appModel.selectSession(id: session.id)
    }

    private func startSession(in workspace: Workspace, sessions: [Session]) {
        appModel.selectedSection = .sessions
        appModel.selectedWorkspaceID = workspace.id
        if let selectedSessionID = appModel.selectedSessionID,
           let selectedSession = appModel.sessions.first(where: { $0.id == selectedSessionID }),
           selectedSession.workspaceID == workspace.id {
            appModel.selectedAgentID = selectedSession.agentID
        } else if let latestSession = sessions.first {
            appModel.selectedAgentID = latestSession.agentID
        }
        appModel.selectSession(id: nil)
    }

    private func isSectionSelected(_ section: NavigationSection) -> Bool {
        switch section {
        case .sessions:
            appModel.selectedSection == .sessions && appModel.selectedSessionID == nil
        case .agents, .workspaces, .releaseNotes:
            appModel.selectedSection == section
        }
    }

    private func isSessionSelected(_ session: Session) -> Bool {
        appModel.selectedSection == .sessions && appModel.selectedSessionID == session.id
    }

    private func count(for section: NavigationSection) -> Int {
        switch section {
        case .sessions:
            appModel.snapshot.sessionsCount
        case .agents:
            appModel.snapshot.agentsCount
        case .workspaces:
            appModel.snapshot.workspacesCount
        case .releaseNotes:
            0
        }
    }

    private func expandedBinding(for workspaceID: Int64) -> Binding<Bool> {
        Binding {
            !collapsedWorkspaceIDs.contains(workspaceID)
        } set: { isExpanded in
            if isExpanded {
                collapsedWorkspaceIDs.remove(workspaceID)
            } else {
                collapsedWorkspaceIDs.insert(workspaceID)
            }
        }
    }
}

private struct WorkspaceSessionGroup: Identifiable {
    let workspace: Workspace
    let sessions: [Session]

    var id: Int64 { workspace.id }
}

private struct SidebarNavigationButton: View {
    let section: NavigationSection
    let count: Int
    let pendingReviewCount: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                HStack(spacing: 8) {
                    Text(section.title)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if pendingReviewCount > 0 {
                        Text(pendingReviewCount.formatted())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange)
                            .clipShape(Capsule())
                            .help("\(pendingReviewCount.formatted()) pending review")
                    }

                    if section.showsCount {
                        Text(count.formatted())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                    }
                }
            } icon: {
                Image(systemName: section.systemImage)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

private struct WorkspaceGroupLabel: View {
    let workspace: Workspace
    let count: Int
    let onStartSession: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(workspace.name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "folder")
            }

            Spacer(minLength: 6)

            Text(count.formatted())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                onStartSession()
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Start Session in \(workspace.name)")
        }
    }
}

private struct SidebarSessionButton: View {
    let session: Session
    let isSelected: Bool
    let agentName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.summary.isEmpty ? "New session" : session.summary)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }

                Text(agentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}
