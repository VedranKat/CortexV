import SwiftUI

struct ChangesView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var filters = ReviewFilters()
    @State private var selectedGroupID: String?
    @State private var selectedFileChangeID: Int64?
    @State private var selectedFileChangeIDs: Set<Int64> = []
    @State private var expandedGroupIDs: Set<String> = []
    @State private var pendingConfirmation: ReviewActionConfirmation?

    private var projection: ReviewProjectionSnapshot {
        ReviewProjection.make(
            sessions: appModel.sessions,
            agents: appModel.agents,
            workspaces: appModel.workspaces,
            changeSets: appModel.allChangeSets,
            fileChanges: appModel.allFileChanges,
            preflightResults: appModel.preflightResultsByFileChangeID,
            handoffs: appModel.reviewContextHandoffs
        )
    }

    private var visibleGroups: [ReviewTaskGroup] {
        projection.filteredGroups(using: filters)
    }

    private var visibleItems: [ReviewChangeItem] {
        visibleGroups.flatMap(\.items)
    }

    private var selectedGroup: ReviewTaskGroup? {
        if let selectedGroupID,
           let group = visibleGroups.first(where: { $0.id == selectedGroupID }) {
            return group
        }
        return visibleGroups.first
    }

    private var selectedItem: ReviewChangeItem? {
        guard let selectedFileChangeID else { return nil }
        return visibleItems.first { $0.id == selectedFileChangeID }
    }

    private var selectedPendingIDs: [Int64] {
        selectedFileChangeIDs
            .compactMap { id in visibleItems.first { $0.id == id } }
            .filter(\.pending)
            .map(\.id)
            .sorted()
    }

    private var queueSignature: String {
        visibleGroups
            .map { group in
                let fileState = group.items.map { "\($0.id):\($0.change.status):\($0.preflight?.status.rawValue ?? "NONE")" }.joined(separator: ",")
                return "\(group.id):\(group.syncState.rawValue):\(fileState)"
            }
            .joined(separator: "|")
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()

                if projection.groups.isEmpty {
                    emptyState
                } else if visibleGroups.isEmpty {
                    emptyFilteredState
                } else {
                    workbench(width: geometry.size.width)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Changes")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    refreshChanges()
                } label: {
                    Label("Refresh Changes", systemImage: "arrow.clockwise")
                }

                Button {
                    sendFinishedVisibleUpdates()
                } label: {
                    Label("Send Finished Updates", systemImage: "arrow.up.message")
                }
                .disabled(!visibleGroups.contains { $0.canSendFinishedLeadContext && $0.needsLeadContext })
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationPresented) {
            if let pendingConfirmation {
                Button(pendingConfirmation.buttonTitle, role: pendingConfirmation.buttonRole) {
                    performConfirmedAction(pendingConfirmation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .onAppear {
            refreshChanges()
        }
        .onChange(of: queueSignature) {
            keepSelectionValid()
        }
        .onChange(of: filters) {
            keepSelectionValid()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Label("Review Workbench", systemImage: "doc.text.magnifyingglass")
                .font(.title3.weight(.semibold))

            ReviewCountPill(text: "\(projection.summary.pendingCount) pending", color: .orange)
            ReviewCountPill(text: "\(projection.summary.blockedCount) blocked", color: .red)
            ReviewCountPill(text: "\(projection.summary.warningCount) warning", color: .yellow)
            ReviewCountPill(text: "\(projection.summary.needsLeadSyncCount) sync", color: .blue)

            Spacer(minLength: 12)

            TextField("Search files, sessions, agents", text: $filters.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            if filters.hasActiveFacets {
                Button {
                    filters.reset()
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func workbench(width: CGFloat) -> some View {
        Group {
            if width < 1060 {
                VStack(spacing: 0) {
                    compactFilterBar
                    Divider()
                    HStack(spacing: 0) {
                        reviewQueue
                            .frame(width: min(max(360, width * 0.42), 470))
                        Divider()
                        detailPane
                    }
                }
            } else {
                HStack(spacing: 0) {
                    filterRail
                        .frame(width: 258)
                    Divider()
                    reviewQueue
                        .frame(width: min(max(390, width * 0.34), 510))
                    Divider()
                    detailPane
                }
            }
        }
    }

    private var filterRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterPickerSection(title: "Status") {
                    Picker("Status", selection: $filters.status) {
                        ForEach(ReviewStatusFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                filterPickerSection(title: "Safety") {
                    Picker("Safety", selection: $filters.safety) {
                        ForEach(ReviewSafetyFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                filterPickerSection(title: "Lead Sync") {
                    Picker("Lead Sync", selection: $filters.sync) {
                        ForEach(ReviewSyncFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                facetSection(
                    title: "Projects",
                    allTitle: "All Projects",
                    selectedID: filters.workspaceID,
                    options: projection.workspaceFacets
                ) { filters.workspaceID = $0 }

                facetSection(
                    title: "Leads",
                    allTitle: "All Leads",
                    selectedID: filters.rootSessionID,
                    options: projection.leadFacets
                ) { filters.rootSessionID = $0 }

                roleFacetSection

                facetSection(
                    title: "Agents",
                    allTitle: "All Agents",
                    selectedID: filters.agentID,
                    options: projection.agentFacets
                ) { filters.agentID = $0 }

                facetSection(
                    title: "Sessions",
                    allTitle: "All Sessions",
                    selectedID: filters.sessionID,
                    options: projection.sessionFacets
                ) { filters.sessionID = $0 }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var compactFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker("Status", selection: $filters.status) {
                    ForEach(ReviewStatusFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Picker("Safety", selection: $filters.safety) {
                    ForEach(ReviewSafetyFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                filterMenu(
                    title: filters.workspaceID.flatMap { selectedFacetTitle(id: $0, options: projection.workspaceFacets) } ?? "Projects",
                    allTitle: "All Projects",
                    selectedID: filters.workspaceID,
                    options: projection.workspaceFacets
                ) { filters.workspaceID = $0 }

                filterMenu(
                    title: filters.rootSessionID.flatMap { selectedFacetTitle(id: $0, options: projection.leadFacets) } ?? "Leads",
                    allTitle: "All Leads",
                    selectedID: filters.rootSessionID,
                    options: projection.leadFacets
                ) { filters.rootSessionID = $0 }

                Menu(filters.role?.title ?? "Roles") {
                    Button("All Roles") { filters.role = nil }
                    ForEach(projection.roleFacets) { option in
                        Button("\(option.title) (\(option.count))") {
                            filters.role = option.role
                        }
                    }
                }

                filterMenu(
                    title: filters.agentID.flatMap { selectedFacetTitle(id: $0, options: projection.agentFacets) } ?? "Agents",
                    allTitle: "All Agents",
                    selectedID: filters.agentID,
                    options: projection.agentFacets
                ) { filters.agentID = $0 }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var reviewQueue: some View {
        VStack(spacing: 0) {
            queueToolbar
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleGroups) { group in
                        groupCard(group)
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var queueToolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(visibleGroups.count) task\(visibleGroups.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                Text("\(visibleItems.count) file\(visibleItems.count == 1 ? "" : "s") visible")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                requestApprove(ids: selectedPendingIDs)
            } label: {
                Label("Approve Selected", systemImage: "checkmark.circle")
            }
            .disabled(selectedPendingIDs.isEmpty)

            Button(role: .destructive) {
                requestReject(ids: selectedPendingIDs)
            } label: {
                Label("Reject Selected", systemImage: "xmark.circle")
            }
            .disabled(selectedPendingIDs.isEmpty)

            Menu {
                Button {
                    requestApprove(ids: visibleItems.filter(\.ready).map(\.id))
                } label: {
                    Label("Approve Visible Ready", systemImage: "checkmark.shield")
                }
                .disabled(!visibleItems.contains(where: \.ready))

                Button {
                    selectVisiblePending()
                } label: {
                    Label("Select Visible Pending", systemImage: "checklist")
                }
                .disabled(!visibleItems.contains(where: \.pending))

                Button {
                    selectedFileChangeIDs.removeAll()
                } label: {
                    Label("Clear Selection", systemImage: "xmark")
                }
                .disabled(selectedFileChangeIDs.isEmpty)

                Divider()

                Button {
                    sendFinishedVisibleUpdates()
                } label: {
                    Label("Send Finished Lead Updates", systemImage: "arrow.up.message")
                }
                .disabled(!visibleGroups.contains { $0.canSendFinishedLeadContext && $0.needsLeadContext })
            } label: {
                Label("Batch Actions", systemImage: "ellipsis.circle")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var detailPane: some View {
        Group {
            if let selectedItem, let group = group(containing: selectedItem.id) {
                fileDetail(item: selectedItem, group: group)
            } else if let selectedGroup {
                taskDetail(group: selectedGroup)
            } else {
                ContentUnavailableView("No Review Task", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Changes",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Agent file proposals will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyFilteredState: some View {
        ContentUnavailableView {
            Label("No Matching Changes", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Clear or adjust filters to show the rest of the queue.")
        } actions: {
            Button("Clear Filters") {
                filters.reset()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func filterPickerSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func facetSection(
        title: String,
        allTitle: String,
        selectedID: Int64?,
        options: [ReviewFacetOption],
        onSelect: @escaping (Int64?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ReviewFacetButton(
                title: allTitle,
                subtitle: nil,
                count: options.reduce(0) { $0 + $1.count },
                isSelected: selectedID == nil
            ) {
                onSelect(nil)
            }

            ForEach(options) { option in
                ReviewFacetButton(
                    title: option.title,
                    subtitle: option.subtitle,
                    count: option.count,
                    isSelected: selectedID == option.id
                ) {
                    onSelect(option.id)
                }
            }
        }
    }

    private var roleFacetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Roles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ReviewFacetButton(
                title: "All Roles",
                subtitle: nil,
                count: projection.roleFacets.reduce(0) { $0 + $1.count },
                isSelected: filters.role == nil
            ) {
                filters.role = nil
            }

            ForEach(projection.roleFacets) { option in
                ReviewFacetButton(
                    title: option.title,
                    subtitle: nil,
                    count: option.count,
                    isSelected: filters.role == option.role
                ) {
                    filters.role = option.role
                }
            }
        }
    }

    private func filterMenu(
        title: String,
        allTitle: String,
        selectedID: Int64?,
        options: [ReviewFacetOption],
        onSelect: @escaping (Int64?) -> Void
    ) -> some View {
        Menu(title) {
            Button(allTitle) { onSelect(nil) }
            ForEach(options) { option in
                Button("\(option.title) (\(option.count))") {
                    onSelect(option.id)
                }
            }
        }
    }

    private func selectedFacetTitle(id: Int64, options: [ReviewFacetOption]) -> String? {
        options.first { $0.id == id }?.title
    }

    private func groupCard(_ group: ReviewTaskGroup) -> some View {
        let isSelected = selectedGroup?.id == group.id && selectedFileChangeID == nil
        let isExpanded = expandedGroupIDs.contains(group.id)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        toggleExpanded(group.id)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: group.role?.systemImage ?? "message")
                        .foregroundStyle(group.blockedCount > 0 ? .red : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.taskTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(group.roleText)  |  \(group.agentName)  |  \(group.workspaceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    ReviewSyncPill(state: group.syncState)
                }

                HStack(spacing: 6) {
                    if group.pendingCount > 0 {
                        ReviewCountPill(text: "\(group.pendingCount) pending", color: .orange)
                    }
                    if group.appliedCount > 0 {
                        ReviewCountPill(text: "\(group.appliedCount) applied", color: .green)
                    }
                    if group.rejectedCount > 0 {
                        ReviewCountPill(text: "\(group.rejectedCount) rejected", color: .secondary)
                    }
                    if group.blockedCount > 0 {
                        ReviewCountPill(text: "\(group.blockedCount) blocked", color: .red)
                    }
                    if group.warningCount > 0 {
                        ReviewCountPill(text: "\(group.warningCount) warning", color: .yellow)
                    }

                    Spacer(minLength: 8)

                    Text(group.sessionID.map { "#\($0)" } ?? "No session")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture {
                selectGroup(group)
            }

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        fileRow(item, group: group)
                        if item.id != group.items.last?.id {
                            Divider()
                                .padding(.leading, 34)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Approve Pending in Task") {
                requestApprove(ids: group.pendingItems.map(\.id))
            }
            .disabled(group.pendingCount == 0)

            Button("Reject Pending in Task", role: .destructive) {
                requestReject(ids: group.pendingItems.map(\.id))
            }
            .disabled(group.pendingCount == 0)

            Divider()

            Button("Send Lead Update") {
                appModel.sendLeadUpdate(for: group)
            }
            .disabled(!group.canSendLeadContext)
        }
    }

    private func fileRow(_ item: ReviewChangeItem, group: ReviewTaskGroup) -> some View {
        let isSelected = selectedFileChangeID == item.id
        let isChecked = selectedFileChangeIDs.contains(item.id)
        return HStack(spacing: 8) {
            Button {
                toggleFileSelection(item.id)
            } label: {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(!item.pending)

            Button {
                selectFile(item, group: group)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.change.filePath)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("Proposal #\(item.id)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 8)

                    ChangeStatusPill(text: item.change.status.capitalized)
                    if item.pending, let preflight = item.preflight {
                        ChangePreflightPill(result: preflight)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func taskDetail(group: ReviewTaskGroup) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: group.role?.systemImage ?? "message")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.taskTitle)
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                Text("\(group.roleText)  |  \(group.agentName)  |  \(group.workspaceName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ReviewSyncPill(state: group.syncState)
                        }

                        HStack(spacing: 6) {
                            ReviewCountPill(text: "\(group.fileCount) files", color: .secondary)
                            ReviewCountPill(text: "\(group.pendingCount) pending", color: .orange)
                            ReviewCountPill(text: "\(group.appliedCount) applied", color: .green)
                            ReviewCountPill(text: "\(group.rejectedCount) rejected", color: .secondary)
                            if group.blockedCount > 0 {
                                ReviewCountPill(text: "\(group.blockedCount) blocked", color: .red)
                            }
                            if group.warningCount > 0 {
                                ReviewCountPill(text: "\(group.warningCount) warning", color: .yellow)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            openSession(group.sessionID)
                        } label: {
                            Label("Open Task", systemImage: "message")
                        }
                        .disabled(group.sessionID == nil)

                        if let rootSessionID = group.rootSessionID, rootSessionID != group.sessionID {
                            Button {
                                openSession(rootSessionID)
                            } label: {
                                Label("Open Lead", systemImage: "person.2.wave.2")
                            }
                        }

                        Button {
                            requestApprove(ids: group.pendingItems.map(\.id))
                        } label: {
                            Label("Approve Task", systemImage: "checkmark.circle")
                        }
                        .disabled(group.pendingCount == 0)

                        Button(role: .destructive) {
                            requestReject(ids: group.pendingItems.map(\.id))
                        } label: {
                            Label("Reject Task", systemImage: "xmark.circle")
                        }
                        .disabled(group.pendingCount == 0)

                        Menu {
                            Button {
                                appModel.sendLeadUpdate(for: group)
                            } label: {
                                Label("Send Lead Update", systemImage: "arrow.up.message")
                            }
                            .disabled(!group.canSendLeadContext)

                            Button {
                                appModel.sendLeadUpdate(for: group, allowDuplicate: true)
                            } label: {
                                Label("Resend Lead Update", systemImage: "arrow.counterclockwise")
                            }
                            .disabled(!group.canSendLeadContext)
                        } label: {
                            Label("Lead Context", systemImage: "pin")
                        }
                    }
                    .controlSize(.small)

                    if group.canSendLeadContext {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lead Update Preview")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(ReviewContextPayload.message(for: group))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Files")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(group.items) { item in
                            Button {
                                selectFile(item, group: group)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(item.change.filePath)
                                        .lineLimit(2)
                                    Spacer()
                                    ChangeStatusPill(text: item.change.status.capitalized)
                                    if item.pending, let preflight = item.preflight {
                                        ChangePreflightPill(result: preflight)
                                    }
                                }
                                .font(.caption)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func fileDetail(item: ReviewChangeItem, group: ReviewTaskGroup) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.change.filePath)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Text("\(item.roleText)  |  \(item.agentName)  |  \(item.workspaceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    ChangeStatusPill(text: item.change.status.capitalized)
                    if item.pending, let preflight = item.preflight {
                        ChangePreflightPill(result: preflight)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        openSession(item.sessionID)
                    } label: {
                        Label("Open Session", systemImage: "message")
                    }
                    .disabled(item.sessionID == nil)

                    if item.pending {
                        Button(role: .destructive) {
                            requestReject(ids: [item.id])
                        } label: {
                            Label("Reject File", systemImage: "xmark.circle")
                        }

                        Button {
                            requestApprove(ids: [item.id])
                        } label: {
                            Label("Approve File", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!item.canApprove)
                    }

                    Menu {
                        Button {
                            requestApprove(ids: group.pendingItems.map(\.id))
                        } label: {
                            Label("Approve Pending in Task", systemImage: "checkmark.circle")
                        }
                        .disabled(group.pendingCount == 0)

                        Button(role: .destructive) {
                            requestReject(ids: group.pendingItems.map(\.id))
                        } label: {
                            Label("Reject Pending in Task", systemImage: "xmark.circle")
                        }
                        .disabled(group.pendingCount == 0)

                        Divider()

                        Button {
                            appModel.sendLeadUpdate(for: group)
                        } label: {
                            Label("Send Lead Update", systemImage: "arrow.up.message")
                        }
                        .disabled(!group.canSendLeadContext)
                    } label: {
                        Label("Task Actions", systemImage: "ellipsis.circle")
                    }

                    Spacer()

                    Text("Proposal #\(item.id)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .controlSize(.small)

                if item.pending, let preflight = item.preflight {
                    ChangePreflightBanner(result: preflight)
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            diffViewer(item.change.diffText)
        }
    }

    private func diffViewer(_ diffText: String) -> some View {
        let lines = diffText.trimmingCharacters(in: .newlines).isEmpty
            ? ["No diff preview available."]
            : diffText.trimmingCharacters(in: .newlines).components(separatedBy: .newlines)
        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    DiffLineView(number: index + 1, text: line)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var confirmationPresented: Binding<Bool> {
        Binding {
            pendingConfirmation != nil
        } set: { isPresented in
            if !isPresented {
                pendingConfirmation = nil
            }
        }
    }

    private var confirmationTitle: String {
        pendingConfirmation?.title ?? "Confirm Review Action"
    }

    private var confirmationMessage: String {
        pendingConfirmation?.message ?? "Review the selected action before continuing."
    }

    private func performConfirmedAction(_ action: ReviewActionConfirmation) {
        switch action {
        case .approve(let ids, _):
            appModel.approveFileChanges(ids: ids)
            selectedFileChangeIDs.subtract(ids)
        case .reject(let ids):
            appModel.rejectFileChanges(ids: ids)
            selectedFileChangeIDs.subtract(ids)
        }
    }

    private func requestApprove(ids: [Int64]) {
        let unique = uniquePendingItems(ids)
        guard !unique.isEmpty else {
            appModel.statusText = "No pending selected changes can be approved."
            return
        }

        let approvable = unique.filter(\.canApprove)
        let blocked = unique.filter { !$0.canApprove }
        guard !approvable.isEmpty else {
            appModel.statusText = "Approval blocked for \(blocked.count) selected change\(blocked.count == 1 ? "" : "s")."
            return
        }

        let warnings = approvable.flatMap { item in
            item.preflight?.issues.filter { $0.severity == .warning } ?? []
        }
        let approvableIDs = approvable.map(\.id)
        if warnings.isEmpty {
            appModel.approveFileChanges(ids: approvableIDs)
            selectedFileChangeIDs.subtract(approvableIDs)
        } else {
            pendingConfirmation = .approve(ids: approvableIDs, warnings: warnings)
        }
    }

    private func requestReject(ids: [Int64]) {
        let unique = uniquePendingItems(ids)
        guard !unique.isEmpty else {
            appModel.statusText = "No pending selected changes can be rejected."
            return
        }
        let ids = unique.map(\.id)
        if ids.count == 1 {
            appModel.rejectFileChanges(ids: ids)
            selectedFileChangeIDs.subtract(ids)
        } else {
            pendingConfirmation = .reject(ids: ids)
        }
    }

    private func uniquePendingItems(_ ids: [Int64]) -> [ReviewChangeItem] {
        var seen = Set<Int64>()
        return ids.compactMap { id in
            guard !seen.contains(id), let item = visibleItems.first(where: { $0.id == id }), item.pending else {
                return nil
            }
            seen.insert(id)
            return item
        }
    }

    private func selectGroup(_ group: ReviewTaskGroup) {
        selectedGroupID = group.id
        selectedFileChangeID = nil
        expandedGroupIDs.insert(group.id)
    }

    private func selectFile(_ item: ReviewChangeItem, group: ReviewTaskGroup) {
        selectedGroupID = group.id
        selectedFileChangeID = item.id
        expandedGroupIDs.insert(group.id)
    }

    private func toggleExpanded(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    private func toggleFileSelection(_ id: Int64) {
        if selectedFileChangeIDs.contains(id) {
            selectedFileChangeIDs.remove(id)
        } else {
            selectedFileChangeIDs.insert(id)
        }
    }

    private func selectVisiblePending() {
        selectedFileChangeIDs = Set(visibleItems.filter(\.pending).map(\.id))
    }

    private func group(containing fileChangeID: Int64) -> ReviewTaskGroup? {
        visibleGroups.first { group in
            group.items.contains { $0.id == fileChangeID }
        }
    }

    private func openSession(_ sessionID: Int64?) {
        guard let sessionID else { return }
        appModel.selectedSection = .sessions
        appModel.selectSession(id: sessionID)
    }

    private func sendFinishedVisibleUpdates() {
        appModel.sendLeadUpdates(for: visibleGroups, finishedOnly: true)
    }

    private func refreshChanges() {
        appModel.refreshSnapshot()
        keepSelectionValid()
    }

    private func keepSelectionValid() {
        let visibleIDs = Set(visibleItems.map(\.id))
        selectedFileChangeIDs = selectedFileChangeIDs.intersection(visibleIDs)

        if let selectedFileChangeID, !visibleIDs.contains(selectedFileChangeID) {
            self.selectedFileChangeID = nil
        }

        if let selectedGroupID, visibleGroups.contains(where: { $0.id == selectedGroupID }) {
            return
        }
        selectedGroupID = visibleGroups.first?.id
        if let selectedGroupID {
            expandedGroupIDs.insert(selectedGroupID)
        }
    }
}

private enum ReviewActionConfirmation: Identifiable {
    case approve(ids: [Int64], warnings: [ChangePreflightIssue])
    case reject(ids: [Int64])

    var id: String {
        switch self {
        case .approve(let ids, _):
            "approve-\(ids.map(String.init).joined(separator: "-"))"
        case .reject(let ids):
            "reject-\(ids.map(String.init).joined(separator: "-"))"
        }
    }

    var title: String {
        switch self {
        case .approve:
            "Approve With Warnings?"
        case .reject:
            "Reject Selected Changes?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .approve(let ids, _):
            ids.count == 1 ? "Approve File" : "Approve \(ids.count) Files"
        case .reject(let ids):
            ids.count == 1 ? "Reject File" : "Reject \(ids.count) Files"
        }
    }

    var buttonRole: ButtonRole? {
        switch self {
        case .approve:
            nil
        case .reject:
            .destructive
        }
    }

    var message: String {
        switch self {
        case .approve(_, let warnings):
            let details = warnings.prefix(4).map(\.title).joined(separator: ", ")
            return details.isEmpty ? "Review the warning before continuing." : "Warnings: \(details)."
        case .reject(let ids):
            return "Reject \(ids.count) pending file change\(ids.count == 1 ? "" : "s"). This only rejects proposals; it does not edit files on disk."
        }
    }
}

private struct ReviewFacetButton: View {
    let title: String
    let subtitle: String?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(count.formatted())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private struct ReviewSyncPill: View {
    let state: ReviewLeadSyncState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.systemImage)
                .font(.caption2)
            Text(state.title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.11))
        .clipShape(Capsule())
    }

    private var color: Color {
        switch state {
        case .notApplicable:
            .secondary
        case .waitingForReview:
            .orange
        case .needsLeadSync:
            .blue
        case .sent:
            .green
        case .changedSinceSent:
            .yellow
        }
    }
}

private struct ChangePreflightBanner: View {
    let result: ChangePreflightResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(result.status.title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)

                Text(result.canApprove ? approveText : "Resolve blocked checks before applying this proposal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.issues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: issue.severity == .blocked ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .blocked ? .red : .yellow)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.caption.weight(.medium))
                        Text(issue.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var approveText: String {
        result.hasWarnings ? "Review warnings before applying." : "Disk content still matches the proposal base."
    }

    private var color: Color {
        switch result.status {
        case .ready:
            .green
        case .warning:
            .yellow
        case .blocked:
            .red
        case .resolved:
            .secondary
        }
    }

    private var symbol: String {
        switch result.status {
        case .ready:
            "checkmark.shield"
        case .warning:
            "exclamationmark.triangle"
        case .blocked:
            "xmark.octagon"
        case .resolved:
            "checkmark.circle"
        }
    }
}

private struct ChangePreflightPill: View {
    let result: ChangePreflightResult

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(result.status.title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.11))
        .clipShape(Capsule())
    }

    private var color: Color {
        switch result.status {
        case .ready:
            .green
        case .warning:
            .yellow
        case .blocked:
            .red
        case .resolved:
            .secondary
        }
    }

    private var symbol: String {
        switch result.status {
        case .ready:
            "checkmark.shield"
        case .warning:
            "exclamationmark.triangle"
        case .blocked:
            "xmark.octagon"
        case .resolved:
            "checkmark.circle"
        }
    }
}

private struct DiffLineView: View {
    let number: Int
    let text: String

    private var kind: DiffLineKind {
        DiffLineKind(line: text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number.formatted())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
                .textSelection(.disabled)

            Text(verbatim: text.isEmpty ? " " : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(kind.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.background)
    }
}

private enum DiffLineKind {
    case added
    case removed
    case hunk
    case fileHeader
    case context

    init(line: String) {
        if line.hasPrefix("@@") {
            self = .hunk
        } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") {
            self = .fileHeader
        } else if line.hasPrefix("+") {
            self = .added
        } else if line.hasPrefix("-") {
            self = .removed
        } else {
            self = .context
        }
    }

    var foreground: Color {
        switch self {
        case .added:
            .green
        case .removed:
            .red
        case .hunk:
            .blue
        case .fileHeader:
            .secondary
        case .context:
            .primary
        }
    }

    var background: Color {
        switch self {
        case .added:
            Color.green.opacity(0.09)
        case .removed:
            Color.red.opacity(0.08)
        case .hunk:
            Color.blue.opacity(0.08)
        case .fileHeader:
            Color(nsColor: .controlBackgroundColor)
        case .context:
            Color.clear
        }
    }
}

private struct ChangeStatusPill: View {
    let text: String

    private var color: Color {
        switch text.uppercased() {
        case "PENDING":
            .orange
        case "APPLIED":
            .green
        case "REJECTED":
            .secondary
        case "MIXED":
            .blue
        default:
            .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
        .clipShape(Capsule())
    }
}

private struct ReviewCountPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        .clipShape(Capsule())
    }
}
