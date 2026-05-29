import SwiftUI

struct ChangesView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedFileChangeID: Int64?
    @State private var filter: ChangeReviewFilter = .all

    private var entries: [ChangeReviewEntry] {
        ChangeReviewEntry.make(
            sessions: appModel.sessions,
            agents: appModel.agents,
            workspaces: appModel.workspaces,
            changeSets: appModel.allChangeSets,
            fileChanges: appModel.allFileChanges
        )
    }

    private var visibleEntries: [ChangeReviewEntry] {
        entries.filter { filter.includes($0.change.status) }
    }

    private var selectedEntry: ChangeReviewEntry? {
        let id = selectedFileChangeID ?? visibleEntries.first?.id
        return visibleEntries.first { $0.id == id }
    }

    private var selectionSignature: String {
        visibleEntries
            .map { "\($0.id):\($0.change.status)" }
            .joined(separator: "|")
    }

    private var pendingCount: Int {
        entries.filter(\.change.pending).count
    }

    private var appliedCount: Int {
        entries.filter { $0.change.status.caseInsensitiveCompare("APPLIED") == .orderedSame }.count
    }

    private var rejectedCount: Int {
        entries.filter { $0.change.status.caseInsensitiveCompare("REJECTED") == .orderedSame }.count
    }

    private var blockedCount: Int {
        entries.filter { appModel.preflightResultsByFileChangeID[$0.id]?.status == .blocked }.count
    }

    private var warningCount: Int {
        entries.filter { appModel.preflightResultsByFileChangeID[$0.id]?.status == .warning }.count
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()

                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Agent file proposals will appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                } else if visibleEntries.isEmpty {
                    emptyFilteredState
                } else if geometry.size.width < 860 {
                    VStack(spacing: 0) {
                        reviewQueue
                            .frame(height: max(220, geometry.size.height * 0.36))
                        Divider()
                        detailPane
                    }
                } else {
                    HStack(spacing: 0) {
                        reviewQueue
                            .frame(width: min(max(340, geometry.size.width * 0.36), 460))
                        Divider()
                        detailPane
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Changes")
        .toolbar {
            Button {
                refreshChanges()
            } label: {
                Label("Refresh Changes", systemImage: "arrow.clockwise")
            }
        }
        .onAppear {
            refreshChanges()
        }
        .onChange(of: selectionSignature) {
            keepSelectionValid()
        }
        .onChange(of: filter) {
            keepSelectionValid()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Review Queue", systemImage: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))

                ChangeCountPill(text: "\(pendingCount) pending", color: .orange)
                ChangeCountPill(text: "\(appliedCount) applied", color: .green)
                ChangeCountPill(text: "\(rejectedCount) rejected", color: .secondary)
                if blockedCount > 0 {
                    ChangeCountPill(text: "\(blockedCount) blocked", color: .red)
                }
                if warningCount > 0 {
                    ChangeCountPill(text: "\(warningCount) warning", color: .yellow)
                }

                Spacer(minLength: 12)

                Picker("Status", selection: $filter) {
                    ForEach(ChangeReviewFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }

            if let selectedEntry {
                HStack(spacing: 8) {
                    ChangeStatusPill(text: selectedEntry.change.status.capitalized)
                    Text(selectedEntry.sessionTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Session #\(selectedEntry.sessionID.map(String.init) ?? "-")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var reviewQueue: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(visibleEntries.count) file\(visibleEntries.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if filter != .all {
                    Button("Show All") {
                        filter = .all
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleEntries) { entry in
                        ChangeReviewRow(
                            entry: entry,
                            preflight: appModel.preflightResultsByFileChangeID[entry.id],
                            isSelected: selectedFileChangeID == entry.id || (selectedFileChangeID == nil && visibleEntries.first?.id == entry.id)
                        ) {
                            selectedFileChangeID = entry.id
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailPane: some View {
        Group {
            if let selectedEntry {
                ChangeReviewDetailPane(
                    entry: selectedEntry,
                    preflight: appModel.preflightResultsByFileChangeID[selectedEntry.id],
                    sessionPreflights: selectedEntry.sessionID.map(sessionPreflights) ?? [],
                    onApproveFile: { appModel.approveFileChange(id: selectedEntry.id) },
                    onRejectFile: { appModel.rejectFileChange(id: selectedEntry.id) },
                    onApproveSession: {
                        guard let sessionID = selectedEntry.sessionID else { return }
                        appModel.approvePendingChanges(sessionID: sessionID)
                    },
                    onRejectSession: {
                        guard let sessionID = selectedEntry.sessionID else { return }
                        appModel.rejectPendingChanges(sessionID: sessionID)
                    },
                    onAskLeadToReview: {
                        guard let sessionID = selectedEntry.sessionID else { return }
                        appModel.sendAppliedChangeReviewRequest(sessionID: sessionID)
                    },
                    onOpenSession: {
                        guard let sessionID = selectedEntry.sessionID else { return }
                        appModel.selectedSection = .sessions
                        appModel.selectSession(id: sessionID)
                    }
                )
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyFilteredState: some View {
        ContentUnavailableView {
            Label("No \(filter.title) Changes", systemImage: filter.systemImage)
        } description: {
            Text("Switch filters to view the rest of the queue.")
        } actions: {
            Button("Show All") {
                filter = .all
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func refreshChanges() {
        appModel.refreshSnapshot()
        keepSelectionValid()
    }

    private func keepSelectionValid() {
        if let selectedFileChangeID,
           visibleEntries.contains(where: { $0.id == selectedFileChangeID }) {
            return
        }
        selectedFileChangeID = visibleEntries.first?.id
    }

    private func sessionPreflights(sessionID: Int64) -> [ChangePreflightResult] {
        entries
            .filter { $0.sessionID == sessionID && $0.change.pending }
            .compactMap { appModel.preflightResultsByFileChangeID[$0.id] }
    }
}

private enum ChangeReviewFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case applied
    case rejected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pending: "Pending"
        case .applied: "Applied"
        case .rejected: "Rejected"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .pending: "clock"
        case .applied: "checkmark.circle"
        case .rejected: "xmark.circle"
        }
    }

    func includes(_ status: String) -> Bool {
        switch self {
        case .all:
            return true
        case .pending:
            return status.caseInsensitiveCompare("PENDING") == .orderedSame
        case .applied:
            return status.caseInsensitiveCompare("APPLIED") == .orderedSame
        case .rejected:
            return status.caseInsensitiveCompare("REJECTED") == .orderedSame
        }
    }
}

private struct ChangeReviewEntry: Identifiable, Equatable {
    let change: FileChange
    let changeSet: ChangeSet?
    let session: Session?
    let agentName: String
    let workspaceName: String
    let sessionTitle: String
    let roleText: String
    let createdAt: Date?
    let sessionPendingCount: Int
    let sessionAppliedCount: Int

    var id: Int64 { change.id }
    var sessionID: Int64? { changeSet?.sessionID }
    var sortDate: Date { createdAt ?? session?.startedAt ?? .distantPast }
    var canOpenSession: Bool { sessionID != nil }
    var canBulkReview: Bool { sessionID != nil && sessionPendingCount > 0 }
    var canAskLeadToReview: Bool {
        session?.parentSessionID != nil && sessionAppliedCount > 0
    }

    static func make(
        sessions: [Session],
        agents: [Agent],
        workspaces: [Workspace],
        changeSets: [ChangeSet],
        fileChanges: [FileChange]
    ) -> [ChangeReviewEntry] {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let changeSetsByID = Dictionary(uniqueKeysWithValues: changeSets.map { ($0.id, $0) })
        let sessionIDsByChangeID: [Int64: Int64] = Dictionary(
            uniqueKeysWithValues: fileChanges.compactMap { change in
                guard let sessionID = changeSetsByID[change.changeSetID]?.sessionID else {
                    return nil
                }
                return (change.id, sessionID)
            }
        )
        let changesBySession = Dictionary(grouping: fileChanges) { change in
            sessionIDsByChangeID[change.id]
        }
        let pendingCountBySession = changesBySession.mapValues { changes in
            changes.filter(\.pending).count
        }
        let appliedCountBySession = changesBySession.mapValues { changes in
            changes.filter { $0.status.caseInsensitiveCompare("APPLIED") == .orderedSame }.count
        }

        return fileChanges.map { change in
            let changeSet = changeSetsByID[change.changeSetID]
            let session = changeSet.flatMap { sessionsByID[$0.sessionID] }
            let agentName = session.flatMap { agentsByID[$0.agentID]?.name } ?? "Unknown Agent"
            let workspaceName = changeSet?.workspaceID.flatMap { workspacesByID[$0]?.name }
                ?? session?.workspaceID.flatMap { workspacesByID[$0]?.name }
                ?? "No workspace"
            let sessionTitle = session.map { session in
                session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Session #\(session.id)"
                    : session.summary
            } ?? "Missing session"
            let roleText = session.map { session in
                if session.hasParentProvenance {
                    return session.orchestrationRole?.title ?? "Sub-Agent Session"
                }
                return "Lead Session"
            } ?? "Detached Change"
            let sessionID = changeSet?.sessionID

            return ChangeReviewEntry(
                change: change,
                changeSet: changeSet,
                session: session,
                agentName: agentName,
                workspaceName: workspaceName,
                sessionTitle: sessionTitle,
                roleText: roleText,
                createdAt: changeSet?.createdAt,
                sessionPendingCount: sessionID.flatMap { pendingCountBySession[$0] } ?? 0,
                sessionAppliedCount: sessionID.flatMap { appliedCountBySession[$0] } ?? 0
            )
        }
        .sorted { lhs, rhs in
            let lhsRank = statusRank(lhs.change.status)
            let rhsRank = statusRank(rhs.change.status)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }
            return lhs.change.filePath.localizedCaseInsensitiveCompare(rhs.change.filePath) == .orderedAscending
        }
    }

    private static func statusRank(_ status: String) -> Int {
        if status.caseInsensitiveCompare("PENDING") == .orderedSame { return 0 }
        if status.caseInsensitiveCompare("APPLIED") == .orderedSame { return 1 }
        if status.caseInsensitiveCompare("REJECTED") == .orderedSame { return 2 }
        return 3
    }
}

private struct ChangeReviewRow: View {
    let entry: ChangeReviewEntry
    let preflight: ChangePreflightResult?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.change.filePath)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    ChangeStatusPill(text: entry.change.status.capitalized)
                    if entry.change.pending, let preflight {
                        ChangePreflightPill(result: preflight)
                    }
                }

                HStack(spacing: 7) {
                    Label(entry.roleText, systemImage: roleSymbol)
                    Text(entry.agentName)
                    Text(entry.workspaceName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                HStack(spacing: 8) {
                    Text(entry.sessionTitle)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let createdAt = entry.createdAt {
                        Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var roleSymbol: String {
        if let role = entry.session?.orchestrationRole {
            return role.systemImage
        }
        return entry.session?.hasParentProvenance == true ? "arrow.triangle.branch" : "message"
    }

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        return Color(nsColor: .controlBackgroundColor)
    }
}

private struct ChangeReviewDetailPane: View {
    let entry: ChangeReviewEntry
    let preflight: ChangePreflightResult?
    let sessionPreflights: [ChangePreflightResult]
    let onApproveFile: () -> Void
    let onRejectFile: () -> Void
    let onApproveSession: () -> Void
    let onRejectSession: () -> Void
    let onAskLeadToReview: () -> Void
    let onOpenSession: () -> Void

    @State private var pendingConfirmation: ChangeApprovalConfirmation?

    private var diffLines: [String] {
        let diffText = entry.change.diffText.trimmingCharacters(in: .newlines)
        guard !diffText.isEmpty else {
            return ["No diff preview available."]
        }
        return diffText.components(separatedBy: .newlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diffViewer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.change.filePath)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Text("\(entry.roleText)  |  \(entry.agentName)  |  \(entry.workspaceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                ChangeStatusPill(text: entry.change.status.capitalized)
            }

            HStack(spacing: 8) {
                Button {
                    onOpenSession()
                } label: {
                    Label("Open Session", systemImage: "message")
                }
                .disabled(!entry.canOpenSession)

                if entry.change.pending {
                    Button(role: .destructive) {
                        onRejectFile()
                    } label: {
                        Label("Reject File", systemImage: "xmark.circle")
                    }

                    Button {
                        approveFile()
                    } label: {
                        Label("Approve File", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preflight?.canApprove == false)
                }

                Menu {
                    Button {
                        approveSession()
                    } label: {
                        Label("Preflight And Apply Pending", systemImage: "checkmark.circle")
                    }
                    .disabled(!canApproveSession)

                    Button(role: .destructive) {
                        onRejectSession()
                    } label: {
                        Label("Reject Pending in Session", systemImage: "xmark.circle")
                    }
                    .disabled(!entry.canBulkReview)

                    Divider()

                    Button {
                        onAskLeadToReview()
                    } label: {
                        Label("Ask Lead to Review Applied Changes", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(!entry.canAskLeadToReview)
                } label: {
                    Label("Session Actions", systemImage: "ellipsis.circle")
                }

                Spacer()

                Text("Proposal #\(entry.id)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .controlSize(.small)

            if entry.change.pending, let preflight {
                ChangePreflightBanner(result: preflight)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Approve With Warnings?", isPresented: confirmationPresented) {
            if let pendingConfirmation {
                Button(pendingConfirmation.buttonTitle) {
                    switch pendingConfirmation {
                    case .file:
                        onApproveFile()
                    case .session:
                        onApproveSession()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingConfirmation?.message ?? "Review the warning before continuing.")
        }
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

    private var canApproveSession: Bool {
        entry.canBulkReview && !sessionPreflights.contains { $0.status == .blocked }
    }

    private func approveFile() {
        guard preflight?.hasWarnings == true else {
            onApproveFile()
            return
        }
        pendingConfirmation = .file(preflight?.issues.filter { $0.severity == .warning } ?? [])
    }

    private func approveSession() {
        let warnings = sessionPreflights.flatMap { result in
            result.issues.filter { $0.severity == .warning }
        }
        guard !warnings.isEmpty else {
            onApproveSession()
            return
        }
        pendingConfirmation = .session(warnings)
    }

    private var diffViewer: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffLines.enumerated()), id: \.offset) { index, line in
                    DiffLineView(number: index + 1, text: line)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private enum ChangeApprovalConfirmation: Identifiable {
    case file([ChangePreflightIssue])
    case session([ChangePreflightIssue])

    var id: String {
        switch self {
        case .file:
            return "file"
        case .session:
            return "session"
        }
    }

    var buttonTitle: String {
        switch self {
        case .file:
            return "Approve File"
        case .session:
            return "Apply Pending Changes"
        }
    }

    var message: String {
        let issues: [ChangePreflightIssue]
        switch self {
        case .file(let values), .session(let values):
            issues = values
        }
        let details = issues.prefix(3).map(\.title).joined(separator: ", ")
        return details.isEmpty ? "Review the warning before continuing." : "Warnings: \(details)."
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

                if result.canApprove {
                    Text(result.hasWarnings ? "Review warnings before applying." : "Disk content still matches the proposal base.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Resolve blocked checks before applying this proposal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private var color: Color {
        switch result.status {
        case .ready:
            return .green
        case .warning:
            return .yellow
        case .blocked:
            return .red
        case .resolved:
            return .secondary
        }
    }

    private var symbol: String {
        switch result.status {
        case .ready:
            return "checkmark.shield"
        case .warning:
            return "exclamationmark.triangle"
        case .blocked:
            return "xmark.octagon"
        case .resolved:
            return "checkmark.circle"
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
            return .green
        case .warning:
            return .yellow
        case .blocked:
            return .red
        case .resolved:
            return .secondary
        }
    }

    private var symbol: String {
        switch result.status {
        case .ready:
            return "checkmark.shield"
        case .warning:
            return "exclamationmark.triangle"
        case .blocked:
            return "xmark.octagon"
        case .resolved:
            return "checkmark.circle"
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
            return .green
        case .removed:
            return .red
        case .hunk:
            return .blue
        case .fileHeader:
            return .secondary
        case .context:
            return .primary
        }
    }

    var background: Color {
        switch self {
        case .added:
            return Color.green.opacity(0.09)
        case .removed:
            return Color.red.opacity(0.08)
        case .hunk:
            return Color.blue.opacity(0.08)
        case .fileHeader:
            return Color(nsColor: .controlBackgroundColor)
        case .context:
            return Color.clear
        }
    }
}

private struct ChangeStatusPill: View {
    let text: String

    private var color: Color {
        switch text.uppercased() {
        case "PENDING":
            return .orange
        case "APPLIED":
            return .green
        case "REJECTED":
            return .secondary
        case "MIXED":
            return .blue
        default:
            return .secondary
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

private struct ChangeCountPill: View {
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        .clipShape(Capsule())
    }
}
