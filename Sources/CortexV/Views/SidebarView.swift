import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("sidebar.isAppMenuExpanded") private var isAppMenuExpanded = true
    @AppStorage("sidebar.showsSubAgentSessions") private var showsSubAgentSessions = true
    @State private var collapsedWorkspaceIDs: Set<Int64> = []
    @State private var collapsedSessionIDs: Set<Int64> = []

    private var assignedSessionGroups: [WorkspaceSessionGroup] {
        appModel.workspaces.compactMap { workspace in
            let sessions = topLevelSessions.filter { $0.workspaceID == workspace.id }
            guard !sessions.isEmpty else { return nil }
            return WorkspaceSessionGroup(workspace: workspace, sessions: sessions)
        }
    }

    private var topLevelSessions: [Session] {
        appModel.sessions.filter { !$0.attachedChildRun }
    }

    private var unassignedSessions: [Session] {
        let knownWorkspaceIDs = Set(appModel.workspaces.map(\.id))
        return topLevelSessions.filter { session in
            guard let workspaceID = session.workspaceID else { return true }
            return !knownWorkspaceIDs.contains(workspaceID)
        }
    }

    var body: some View {
        List {
            Section {
                SidebarAppMenuHeader(isExpanded: isAppMenuExpanded) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isAppMenuExpanded.toggle()
                    }
                }

                if isAppMenuExpanded {
                    ForEach(NavigationSection.allCases) { section in
                        SidebarNavigationButton(
                            section: section,
                            count: count(for: section),
                            pendingReviewCount: 0,
                            isSelected: isSectionSelected(section)
                        ) {
                            select(section)
                        }
                    }

                    Toggle(isOn: $showsSubAgentSessions) {
                        Label("Sub-Agent Sessions", systemImage: "arrow.triangle.branch")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            ForEach(assignedSessionGroups) { group in
                Section {
                    DisclosureGroup(isExpanded: expandedBinding(for: group.workspace.id)) {
                        ForEach(group.sessions) { session in
                            SidebarSessionTree(
                                session: session,
                                childRuns: childRuns(for: session),
                                showsChildRuns: showsSubAgentSessions,
                                isExpanded: sessionExpandedBinding(for: session.id),
                                isSelected: isSessionSelected,
                                agentName: appModel.agentName(for:),
                                onSelect: selectSession
                            )
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
                        SidebarSessionTree(
                            session: session,
                            childRuns: childRuns(for: session),
                            showsChildRuns: showsSubAgentSessions,
                            isExpanded: sessionExpandedBinding(for: session.id),
                            isSelected: isSessionSelected,
                            agentName: appModel.agentName(for:),
                            onSelect: selectSession
                        )
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
        case .changes, .agents, .workspaces, .releaseNotes:
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
        case .changes:
            appModel.snapshot.pendingChangesCount
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

    private func sessionExpandedBinding(for sessionID: Int64) -> Binding<Bool> {
        Binding {
            !collapsedSessionIDs.contains(sessionID)
        } set: { isExpanded in
            if isExpanded {
                collapsedSessionIDs.remove(sessionID)
            } else {
                collapsedSessionIDs.insert(sessionID)
            }
        }
    }

    private func childRuns(for session: Session) -> [Session] {
        appModel.sessions.filter { $0.parentSessionID == session.id && $0.attachedChildRun }
    }
}

private struct WorkspaceSessionGroup: Identifiable {
    let workspace: Workspace
    let sessions: [Session]

    var id: Int64 { workspace.id }
}

private struct SidebarAppMenuHeader: View {
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Text("Cortex V")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse Cortex V Menu" : "Expand Cortex V Menu")
    }
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

private struct SidebarSessionTree: View {
    let session: Session
    let childRuns: [Session]
    let showsChildRuns: Bool
    @Binding var isExpanded: Bool
    let isSelected: (Session) -> Bool
    let agentName: (Int64) -> String
    let onSelect: (Session) -> Void

    var body: some View {
        if showsChildRuns && !childRuns.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(childRuns) { childRun in
                    SidebarSessionButton(
                        session: childRun,
                        isSelected: isSelected(childRun),
                        agentName: agentName(childRun.agentID),
                        depth: 1
                    ) {
                        onSelect(childRun)
                    }
                }
            } label: {
                SidebarSessionButton(
                    session: session,
                    isSelected: isSelected(session),
                    agentName: agentName(session.agentID),
                    childCount: childRuns.count
                ) {
                    onSelect(session)
                }
            }
        } else {
            SidebarSessionButton(
                session: session,
                isSelected: isSelected(session),
                agentName: agentName(session.agentID),
                childCount: childRuns.count
            ) {
                onSelect(session)
            }
        }
    }
}

private struct SidebarSessionButton: View {
    let session: Session
    let isSelected: Bool
    let agentName: String
    var depth = 0
    var childCount = 0
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
                    if childCount > 0 {
                        Text(childCount.formatted())
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if session.hasParentProvenance {
                        SidebarStatusBadge(text: session.sidebarStatusText, color: session.sidebarStatusColor)
                    }
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

                if session.hasParentProvenance {
                    Label(childRunText, systemImage: session.orchestrationRole?.systemImage ?? "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var childRunText: String {
        let role = session.orchestrationRole?.title ?? "Sub-Agent Session"
        guard let parentSessionID = session.parentSessionID else { return role }
        if session.detachedChildRun {
            return "Detached \(role) from #\(parentSessionID)"
        }
        return "\(role) from #\(parentSessionID)"
    }
}

private struct SidebarStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        .clipShape(Capsule())
    }
}

private extension Session {
    var sidebarStatusText: String {
        if detachedChildRun {
            return "Detached"
        }
        switch status {
        case .active:
            return "Running"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    var sidebarStatusColor: Color {
        if detachedChildRun {
            return .secondary
        }
        switch status {
        case .active:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }
}
