import AppKit
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedAgentForNewSession: Int64?
    @State private var selectedWorkspaceForNewSession: Int64?
    @State private var isInspectorExpanded = false
    @State private var composerText = ""
    @State private var composerFocusToken = 0
    @State private var confirmsDiagnosticsExport = false

    private var selectedSession: Session? {
        appModel.sessions.first { $0.id == appModel.selectedSessionID }
    }

    private var agentOptions: [Agent] {
        appModel.sessionAgentOptions(for: selectedWorkspaceForNewSession)
    }

    private var canOpenSession: Bool {
        selectedAgentForNewSession != nil
    }

    private var selectedSessionIsOrchestrator: Bool {
        guard let selectedSession else { return false }
        return appModel.agents.first { $0.id == selectedSession.agentID }?.orchestrator == true
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            HStack(spacing: 0) {
                if let selectedSession {
                    ChatPane(
                        session: selectedSession,
                        messages: appModel.messages,
                        toolCalls: appModel.toolCalls,
                        subAgentSessions: appModel.sessions.filter { $0.parentSessionID == selectedSession.id },
                        isSending: appModel.isSendingMessage,
                        composerText: $composerText,
                        focusToken: composerFocusToken,
                        agentName: appModel.agentName(for: selectedSession.agentID),
                        workspaceName: appModel.workspaceName(for: selectedSession.workspaceID),
                        agentNameForID: appModel.agentName(for:),
                        workspaceNameForID: appModel.workspaceName(for:),
                        canSendMessages: !selectedSession.attachedChildRun,
                        readOnlyReason: selectedSession.attachedChildRun ? "Attached sub-agent sessions are read-only. Continue standalone to detach this session from the lead." : nil,
                        onDetach: appModel.detachSelectedSession,
                        onOpenSubAgentSession: { appModel.selectSession(id: $0) },
                        onSendSummaryToLead: appModel.sendSelectedSessionSummaryToLead(_:),
                        onSend: sendComposerMessage
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StartSessionView(
                        selectedAgentID: $selectedAgentForNewSession,
                        selectedWorkspaceID: $selectedWorkspaceForNewSession,
                        agentOptions: agentOptions,
                        workspaces: appModel.workspaces,
                        canOpenSession: canOpenSession,
                        onWorkspaceChanged: clearAgentSelection,
                        onCreateWorkspace: { appModel.selectedSection = .workspaces },
                        onCreateAgent: { appModel.selectedSection = .agents },
                        onOpenSession: openSession
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()

                SessionInspectorPanel(
                    session: selectedSession,
                    isExpanded: $isInspectorExpanded,
                    messagesCount: appModel.messages.count,
                    toolCalls: appModel.toolCalls,
                    fileChanges: appModel.fileChanges,
                    changeSetsByID: appModel.changeSetsByID,
                    preflightResults: appModel.preflightResultsByFileChangeID,
                    runMap: appModel.selectedRunMap,
                    childRuns: selectedSession.map { selected in appModel.sessions.filter { $0.parentSessionID == selected.id } } ?? [],
                    agentName: selectedSession.map { appModel.agentName(for: $0.agentID) } ?? "",
                    workspaceName: selectedSession.map { appModel.workspaceName(for: $0.workspaceID) } ?? "",
                    agentNameForID: appModel.agentName(for:),
                    workspaceNameForID: appModel.workspaceName(for:),
                    onOpenChildRun: { appModel.selectSession(id: $0) },
                    onOpenRunNode: { appModel.selectSession(id: $0) },
                    onOpenChanges: { sessionID in
                        appModel.selectedSection = .changes
                        if let sessionID {
                            appModel.selectSession(id: sessionID)
                        }
                    },
                    onApprove: appModel.approveFileChange(id:),
                    onReject: appModel.rejectFileChange(id:)
                )
                .frame(width: isInspectorExpanded ? (compact ? 280 : 330) : 44)
            }
        }
        .navigationTitle(selectedSession == nil ? "Start Session" : "Session")
        .toolbar {
            ToolbarItemGroup {
                if selectedSessionIsOrchestrator {
                    Button {
                        confirmsDiagnosticsExport = true
                    } label: {
                        Label("Export Diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Export an orchestration diagnostics report into the session workspace.")
                }

                if selectedSession?.attachedChildRun == true {
                    Button {
                        appModel.detachSelectedSession()
                    } label: {
                        Label("Continue Standalone", systemImage: "arrow.up.forward.app")
                    }
                }

                Button(role: .destructive) {
                    appModel.deleteSelectedSession()
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
                .disabled(selectedSession == nil)
            }
        }
        .alert("Export Diagnostics?", isPresented: $confirmsDiagnosticsExport) {
            Button("Cancel", role: .cancel) {}
            Button("Export") {
                appModel.exportSelectedSessionDiagnostics()
            }
        } message: {
            Text("This writes a local markdown report for the selected orchestrator session into the workspace diagnostics folder.")
        }
        .onAppear {
            syncNewSessionDefaults()
            handlePendingCommand(appModel.pendingCommand)
        }
        .onChange(of: appModel.agents) {
            syncNewSessionDefaults()
        }
        .onChange(of: appModel.workspaces) {
            syncNewSessionDefaults()
        }
        .onChange(of: appModel.selectedAgentID) {
            syncNewSessionDefaults()
        }
        .onChange(of: appModel.selectedWorkspaceID) {
            syncNewSessionDefaults()
        }
        .onChange(of: appModel.pendingCommand) { _, command in
            handlePendingCommand(command)
        }
    }

    private func openSession() {
        guard canOpenSession else {
            if appModel.agents.isEmpty {
                appModel.statusText = "Create an agent before opening a session."
            } else {
                appModel.statusText = "Choose an agent before opening a session."
            }
            return
        }
        appModel.createSession(
            agentID: selectedAgentForNewSession,
            workspaceID: selectedWorkspaceForNewSession,
            useDefaultWorkspace: false
        )
        syncNewSessionDefaults()
    }

    private func sendComposerMessage() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appModel.sendUserMessage(composerText)
        composerText = ""
    }

    private func syncNewSessionDefaults() {
        if let selectedWorkspaceID = appModel.selectedWorkspaceID,
           appModel.workspaces.contains(where: { $0.id == selectedWorkspaceID }),
           selectedWorkspaceForNewSession == nil {
            selectedWorkspaceForNewSession = selectedWorkspaceID
        }
        clearInvalidAgentSelection()
    }

    private func clearAgentSelection() {
        selectedAgentForNewSession = nil
    }

    private func clearInvalidAgentSelection() {
        guard let selectedAgentForNewSession else { return }
        if !agentOptions.contains(where: { $0.id == selectedAgentForNewSession }) {
            self.selectedAgentForNewSession = nil
        }
    }

    private func handlePendingCommand(_ command: AppCommand?) {
        if command == .newSession {
            syncNewSessionDefaults()
            appModel.consumePendingCommand(.newSession)
            return
        }
        guard command == .sendMessage else { return }
        composerFocusToken += 1
        appModel.consumePendingCommand(.sendMessage)
    }
}

private struct ChatPane: View {
    let session: Session
    let messages: [Message]
    let toolCalls: [ToolCall]
    let subAgentSessions: [Session]
    let isSending: Bool
    @Binding var composerText: String
    let focusToken: Int
    let agentName: String
    let workspaceName: String
    let agentNameForID: (Int64) -> String
    let workspaceNameForID: (Int64?) -> String
    let canSendMessages: Bool
    let readOnlyReason: String?
    let onDetach: () -> Void
    let onOpenSubAgentSession: (Int64) -> Void
    let onSendSummaryToLead: (String) -> Void
    let onSend: () -> Void

    @State private var composerHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            chatHeader(session: session)
            Divider()
            messageList
            Divider()
            if session.detachedChildRun {
                detachedSummaryControls
            }
            if canSendMessages {
                composer
            } else {
                readOnlyComposer
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func chatHeader(session: Session) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.summary.isEmpty ? "Session #\(session.id)" : session.summary)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(sessionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusPill(text: session.status.rawValue.capitalized)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sessionSubtitle: String {
        var parts = [agentName, workspaceName]
        if session.hasParentProvenance {
            let role = session.orchestrationRole?.title ?? "Sub-Agent Session"
            if let parentSessionID = session.parentSessionID {
                parts.append(session.detachedChildRun ? "Detached \(role) from #\(parentSessionID)" : "\(role) from #\(parentSessionID)")
            } else {
                parts.append(role)
            }
        }
        return parts.joined(separator: "  |  ")
    }

    private var timelineItems: [ChatTimelineItem] {
        var items = messages.map(ChatTimelineItem.message)
        items.append(contentsOf: delegationCards.map(ChatTimelineItem.delegation))
        if let detachedAt = session.detachedAt {
            items.append(.detachment(timestamp: detachedAt, parentSessionID: session.parentSessionID))
        }
        return items.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id < rhs.id
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private var delegationCards: [DelegationCardModel] {
        toolCalls
            .filter { $0.toolName == "delegate_to_child_agent" }
            .map {
                DelegationCardModel(
                    toolCall: $0,
                    subAgentSessions: subAgentSessions,
                    agentName: agentNameForID,
                    workspaceName: workspaceNameForID
                )
            }
    }

    private var latestAssistantReply: String? {
        messages
            .last { $0.role.caseInsensitiveCompare("assistant") == .orderedSame && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var timelineRevision: String {
        "\(session.id):\(timelineItems.map(\.id).joined(separator: "|"))"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if timelineItems.isEmpty {
                        ContentUnavailableView(
                            "No Messages",
                            systemImage: "message",
                            description: Text("Send the first message to start this session.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(timelineItems) { item in
                            switch item {
                            case .message(let message):
                                MessageBubble(message: message)
                                    .id(item.id)
                            case .delegation(let card):
                                DelegationCardView(card: card, onOpen: onOpenSubAgentSession)
                                    .id(item.id)
                            case .detachment(_, let parentSessionID):
                                DetachmentBoundary(parentSessionID: parentSessionID)
                                    .id(item.id)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .id(session.id)
            .onAppear {
                scrollToLatest(proxy)
            }
            .onChange(of: session.id) {
                scrollToLatest(proxy)
            }
            .onChange(of: timelineRevision) {
                scrollToLatest(proxy)
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let latestID = timelineItems.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(latestID, anchor: .bottom)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                ChatComposerTextView(
                    text: $composerText,
                    calculatedHeight: $composerHeight,
                    placeholder: "Message \(agentName)",
                    focusToken: focusToken,
                    onSubmit: onSend
                )
                .frame(height: composerHeight)

                Button(action: onSend) {
                    Image(systemName: isSending ? "stopwatch" : "paperplane.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .help(isSending ? "Sending" : "Send")
                .disabled(isSending || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var detachedSummaryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Detached", systemImage: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("The lead no longer sees this conversation. Send a summary when you want to hand context back.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                Button {
                    composerText = summaryPrompt
                } label: {
                    Label("Create Summary", systemImage: "text.badge.plus")
                }
                .help("Put a summary request in the composer.")

                Button {
                    if let latestAssistantReply {
                        onSendSummaryToLead(latestAssistantReply)
                    }
                } label: {
                    Label("Send Latest Summary to Lead", systemImage: "pin")
                }
                .disabled(latestAssistantReply == nil)
                .help("Send only the latest assistant reply to the lead as pinned context.")

                Spacer()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var summaryPrompt: String {
        """
        Create a concise summary for the lead orchestrator. Include only durable findings, decisions, risks, changed assumptions, and recommended next actions. Do not include the full transcript. Keep it compact enough to pin back as context.
        """
    }

    private var readOnlyComposer: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(readOnlyReason ?? "This session is read-only.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button {
                onDetach()
            } label: {
                Label("Continue Standalone", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private enum ChatTimelineItem: Identifiable {
    case message(Message)
    case delegation(DelegationCardModel)
    case detachment(timestamp: Date, parentSessionID: Int64?)

    var id: String {
        switch self {
        case .message(let message):
            "message-\(message.id)"
        case .delegation(let card):
            "delegation-\(card.id)"
        case .detachment(let timestamp, _):
            "detachment-\(timestamp.timeIntervalSince1970)"
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let message):
            message.timestamp
        case .delegation(let card):
            card.timestamp
        case .detachment(let timestamp, _):
            timestamp
        }
    }
}

private struct DelegationCardModel: Identifiable {
    let id: Int64
    let timestamp: Date
    let objective: String
    let roleTitle: String
    let agentName: String
    let workspaceName: String
    let statusText: String
    let statusKind: DelegationStatusKind
    let childSessionID: Int64?
    let resultPreview: String

    init(
        toolCall: ToolCall,
        subAgentSessions: [Session],
        agentName: (Int64) -> String,
        workspaceName: (Int64?) -> String
    ) {
        let arguments = Self.parseJSON(toolCall.argumentsJSON)
        let resultSessionID = Self.childSessionID(from: toolCall.resultJSON)
        let childSession = resultSessionID.flatMap { id in
            subAgentSessions.first { $0.id == id }
        }
        let role = childSession?.orchestrationRole?.title
            ?? Self.roleTitle(from: arguments["role"] as? String)
            ?? "Sub-Agent"

        self.id = toolCall.id
        self.timestamp = toolCall.timestamp
        self.objective = Self.trimmed(arguments["objective"] as? String) ?? childSession?.summary ?? "Delegated task"
        self.roleTitle = role
        self.agentName = childSession.map { agentName($0.agentID) } ?? Self.childAgentLabel(from: arguments["childAgentId"])
        self.workspaceName = childSession.map { workspaceName($0.workspaceID) } ?? "Workspace selected by lead"
        self.childSessionID = childSession?.id ?? resultSessionID
        self.resultPreview = Self.resultPreview(from: toolCall.resultJSON)

        if !toolCall.successful {
            self.statusText = "Failed"
            self.statusKind = .failed
        } else if childSession?.detachedChildRun == true {
            self.statusText = "Detached"
            self.statusKind = .detached
        } else {
            switch childSession?.status {
            case .active:
                self.statusText = "Running"
                self.statusKind = .running
            case .failed:
                self.statusText = "Failed"
                self.statusKind = .failed
            case .completed:
                self.statusText = "Done"
                self.statusKind = .done
            case nil:
                self.statusText = "Done"
                self.statusKind = .done
            }
        }
    }

    private static func parseJSON(_ json: String) -> [String: Any] {
        let data = Data(json.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func childAgentLabel(from value: Any?) -> String {
        if let number = value as? NSNumber {
            return "Agent #\(number.int64Value)"
        }
        if let text = trimmed(value as? String) {
            return "Agent #\(text)"
        }
        return "Sub-agent"
    }

    private static func roleTitle(from value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        let normalized = value.uppercased().replacingOccurrences(of: " ", with: "_")
        if normalized == "WORKER" {
            return OrchestrationRole.worker.title
        }
        if normalized == "REVIEW" {
            return OrchestrationRole.reviewer.title
        }
        if normalized == "LOGREADER" {
            return OrchestrationRole.logReader.title
        }
        return OrchestrationRole(rawValue: normalized)?.title
    }

    private static func childSessionID(from result: String) -> Int64? {
        let pattern = #"Sub-agent session #([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        guard let match = regex.firstMatch(in: result, range: range),
              let idRange = Range(match.range(at: 1), in: result)
        else {
            return nil
        }
        return Int64(String(result[idRange]))
    }

    private static func resultPreview(from result: String) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No result recorded." }
        if trimmed.hasPrefix("Tool error:") {
            return trimmed
        }
        if let resultRange = trimmed.range(of: "\nResult:\n") {
            return String(trimmed[resultRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .prefix(3)
                .joined(separator: "\n")
        }
        return trimmed.components(separatedBy: .newlines).prefix(3).joined(separator: "\n")
    }
}

private enum DelegationStatusKind {
    case running
    case done
    case failed
    case detached

    var color: Color {
        switch self {
        case .running:
            .blue
        case .done:
            .green
        case .failed:
            .orange
        case .detached:
            .secondary
        }
    }
}

private struct DelegationCardView: View {
    let card: DelegationCardModel
    let onOpen: (Int64) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(card.roleTitle, systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(card.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 8)

                    StatusDotPill(text: card.statusText, color: card.statusKind.color)
                }

                Text(card.objective)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("\(card.agentName)  |  \(card.workspaceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !card.resultPreview.isEmpty {
                    Text(card.resultPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let childSessionID = card.childSessionID {
                    HStack {
                        Spacer()
                        Button {
                            onOpen(childSessionID)
                        } label: {
                            Label("Open Sub-Agent Session", systemImage: "arrow.right.circle")
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(card.statusKind.color.opacity(0.7))
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            Spacer(minLength: 56)
        }
    }
}

private struct DetachmentBoundary: View {
    let parentSessionID: Int64?

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)

            Text(boundaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var boundaryText: String {
        if let parentSessionID {
            return "Detached from lead #\(parentSessionID). The lead no longer sees this conversation unless you send a summary."
        }
        return "Detached. The lead no longer sees this conversation unless you send a summary."
    }
}

private struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    let placeholder: String
    let focusToken: Int
    let onSubmit: () -> Void

    private let minHeight: CGFloat = 44
    private let maxHeight: CGFloat = 142

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.placeholder = placeholder
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        textView.onSubmit = onSubmit
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.recalculateHeight()
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView
        weak var textView: ComposerTextView?
        weak var scrollView: NSScrollView?
        var lastFocusToken = 0

        init(parent: ChatComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let textView, let scrollView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let desiredHeight = usedRect.height + textView.textContainerInset.height * 2 + 2
            let clampedHeight = min(parent.maxHeight, max(parent.minHeight, ceil(desiredHeight)))
            if abs(parent.calculatedHeight - clampedHeight) > 0.5 {
                parent.calculatedHeight = clampedHeight
            }
            scrollView.hasVerticalScroller = desiredHeight > parent.maxHeight
        }
    }
}

private final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let hasShift = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
        if isReturn && !hasShift {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let origin = NSPoint(x: textContainerInset.width + 2, y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}

private struct StartSessionView: View {
    @Binding var selectedAgentID: Int64?
    @Binding var selectedWorkspaceID: Int64?
    let agentOptions: [Agent]
    let workspaces: [Workspace]
    let canOpenSession: Bool
    let onWorkspaceChanged: () -> Void
    let onCreateWorkspace: () -> Void
    let onCreateAgent: () -> Void
    let onOpenSession: () -> Void

    private var hasWorkspace: Bool { !workspaces.isEmpty }
    private var hasAgent: Bool { !agentOptions.isEmpty }
    private var selectedAgent: Agent? {
        agentOptions.first { $0.id == selectedAgentID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Start Session", systemImage: "plus.bubble")
                        .font(.largeTitle.weight(.semibold))
                    Text("Choose an agent for chat, optionally attach a workspace for file tools.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Picker("Workspace", selection: Binding(
                        get: { selectedWorkspaceID },
                        set: { workspaceID in
                            selectedWorkspaceID = workspaceID
                            onWorkspaceChanged()
                        }
                    )) {
                        Text("No Workspace - Chat only").tag(Optional<Int64>.none)
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }

                    Picker("Agent / Model", selection: $selectedAgentID) {
                        Text("Choose Agent").tag(Optional<Int64>.none)
                        ForEach(agentOptions) { agent in
                            Text(agent.model.isEmpty ? agent.name : "\(agent.name) - \(agent.model)")
                                .tag(Optional(agent.id))
                        }
                    }
                    .disabled(agentOptions.isEmpty)

                    if let selectedAgent {
                        LabeledContent("Provider", value: selectedAgent.baseURL.isEmpty ? "Not set" : selectedAgent.baseURL)
                        LabeledContent("Model", value: selectedAgent.model.isEmpty ? "Not set" : selectedAgent.model)
                    } else if selectedWorkspaceID != nil, hasWorkspace, !hasAgent {
                        Text("No agents are bound to this workspace yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        onCreateWorkspace()
                    } label: {
                        Label(hasWorkspace ? "Workspaces" : "Workspace", systemImage: "folder")
                    }

                    Button {
                        onCreateAgent()
                    } label: {
                        Label("Agents", systemImage: "person.crop.circle.badge.plus")
                    }

                    Spacer()

                    Button {
                        onOpenSession()
                    } label: {
                        Label("Open Session", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canOpenSession)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MessageBubble: View {
    let message: Message

    private var isUser: Bool {
        message.role.caseInsensitiveCompare("user") == .orderedSame
    }

    private var isContext: Bool {
        message.role.caseInsensitiveCompare("context") == .orderedSame
    }

    private var roleLabel: String {
        if isUser {
            return "Me"
        }
        if isContext {
            return "Context"
        }
        if message.role.caseInsensitiveCompare("assistant") == .orderedSame {
            return "Agent"
        }
        return message.role.capitalized
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 56) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(roleLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if isUser {
                    Text(message.content)
                        .font(.system(size: 14.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownMessageView(content: message.content)
                }
            }
            .padding(10)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !isUser && !isContext { Spacer(minLength: 56) }
        }
    }

    private var backgroundColor: Color {
        if isUser {
            return Color.accentColor.opacity(0.13)
        }
        if isContext {
            return Color.accentColor.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }
}

private struct MarkdownMessageView: View {
    let content: String
    @State private var height: CGFloat = 28

    var body: some View {
        StructuredSelectableTextView(content: content, calculatedHeight: $height)
            .frame(height: height)
    }
}

private struct StructuredSelectableTextView: NSViewRepresentable {
    let content: String
    @Binding var calculatedHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SelectableTextContainerView {
        let view = SelectableTextContainerView()
        view.textView.isEditable = false
        view.textView.isSelectable = true
        view.textView.drawsBackground = false
        view.textView.backgroundColor = .clear
        view.textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        view.textView.textContainerInset = .zero
        view.textView.textContainer?.lineFragmentPadding = 0
        view.textView.isVerticallyResizable = true
        view.textView.isHorizontallyResizable = false
        view.textView.autoresizingMask = [.width]
        view.textView.textContainer?.widthTracksTextView = true
        view.onHeightChanged = { height in
            context.coordinator.updateHeight(height)
        }
        context.coordinator.containerView = view
        context.coordinator.updateContent(content)
        return view
    }

    func updateNSView(_ view: SelectableTextContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.containerView = view
        context.coordinator.updateContent(content)
    }

    @MainActor
    final class Coordinator {
        var parent: StructuredSelectableTextView
        weak var containerView: SelectableTextContainerView?
        private var renderedContent = ""

        init(parent: StructuredSelectableTextView) {
            self.parent = parent
        }

        func updateContent(_ content: String) {
            if renderedContent != content {
                containerView?.textView.textStorage?.setAttributedString(Self.attributedString(for: content))
                renderedContent = content
            }
            containerView?.recalculateHeight()
            scheduleRecalculation()
        }

        func updateHeight(_ height: CGFloat) {
            guard abs(parent.calculatedHeight - height) > 0.5 else { return }
            parent.calculatedHeight = height
        }

        private func scheduleRecalculation() {
            DispatchQueue.main.async { [weak self] in
                self?.containerView?.forceLayoutRecalculation()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.containerView?.forceLayoutRecalculation()
            }
        }

        private static func attributedString(for content: String) -> NSAttributedString {
            let output = NSMutableAttributedString()

            for block in MarkdownBlock.parse(content) {
                if output.length > 0 {
                    output.append(NSAttributedString(string: "\n"))
                }
                output.append(attributedBlock(block))
            }

            return output
        }

        private static func attributedBlock(_ block: MarkdownBlock) -> NSAttributedString {
            switch block.kind {
            case .heading(let level):
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = level <= 2 ? 8 : 6
                style.lineSpacing = 2
                let font = headingFont(for: level)
                return attributedInlineMarkdown(
                    block.text,
                    baseFont: font,
                    boldFont: font,
                    paragraphStyle: style
                )

            case .paragraph:
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 8
                style.lineSpacing = 2
                let font = NSFont.systemFont(ofSize: 14.5)
                return attributedInlineMarkdown(
                    block.text,
                    baseFont: font,
                    boldFont: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    paragraphStyle: style
                )

            case .bullet:
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 5
                style.lineSpacing = 2
                style.firstLineHeadIndent = 0
                style.headIndent = 18
                style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
                let font = NSFont.systemFont(ofSize: 14.5)
                return attributedInlineMarkdown(
                    "•\t\(block.text)",
                    baseFont: font,
                    boldFont: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    paragraphStyle: style
                )

            case .code:
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 8
                style.lineSpacing = 1
                return NSAttributedString(
                    string: block.text,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.55),
                        .paragraphStyle: style
                    ]
                )

            case .table:
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 8
                style.lineSpacing = 1.4
                return NSAttributedString(
                    string: block.text,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.45),
                        .paragraphStyle: style
                    ]
                )
            }
        }

        private static func headingFont(for level: Int) -> NSFont {
            switch level {
            case 1:
                return .systemFont(ofSize: 17, weight: .semibold)
            case 2:
                return .systemFont(ofSize: 15.5, weight: .semibold)
            case 3:
                return .systemFont(ofSize: 14.8, weight: .semibold)
            default:
                return .systemFont(ofSize: 14.5, weight: .semibold)
            }
        }

        private static func attributedInlineMarkdown(
            _ text: String,
            baseFont: NSFont,
            boldFont: NSFont,
            paragraphStyle: NSParagraphStyle
        ) -> NSAttributedString {
            let output = NSMutableAttributedString()
            var index = text.startIndex
            var isBold = false
            var isCode = false
            var buffer = ""

            func flush() {
                guard !buffer.isEmpty else { return }
                let font = isCode
                    ? NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                    : (isBold ? boldFont : baseFont)
                append(buffer, font: font)
                buffer.removeAll()
            }

            func append(_ string: String, font: NSFont, link: String? = nil) {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle
                ]
                if let link {
                    attributes[.link] = link
                    attributes[.foregroundColor] = NSColor.controlAccentColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                output.append(NSAttributedString(string: string, attributes: attributes))
            }

            while index < text.endIndex {
                if text[index...].hasPrefix("**") {
                    flush()
                    isBold.toggle()
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                if let markdownLink = markdownLink(in: text, at: index) {
                    flush()
                    append(markdownLink.label, font: isBold ? boldFont : baseFont, link: markdownLink.destination)
                    index = markdownLink.nextIndex
                    continue
                }
                if text[index] == "`" {
                    flush()
                    isCode.toggle()
                    index = text.index(after: index)
                    continue
                }
                if text[index] == "*" || text[index] == "_" {
                    index = text.index(after: index)
                    continue
                }

                buffer.append(text[index])
                index = text.index(after: index)
            }

            flush()
            applyDetectedLinks(to: output)
            applyFilePathHighlights(to: output, pointSize: baseFont.pointSize)
            return output
        }

        private static func markdownLink(in text: String, at index: String.Index) -> (label: String, destination: String, nextIndex: String.Index)? {
            guard text[index] == "[" else { return nil }
            let labelStart = text.index(after: index)
            guard let labelEnd = text[labelStart...].firstIndex(of: "]") else { return nil }
            let openParen = text.index(after: labelEnd)
            guard openParen < text.endIndex, text[openParen] == "(" else { return nil }
            let destinationStart = text.index(after: openParen)
            guard let destinationEnd = text[destinationStart...].firstIndex(of: ")") else { return nil }
            let label = String(text[labelStart..<labelEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = String(text[destinationStart..<destinationEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !destination.isEmpty else { return nil }
            return (label, destination, text.index(after: destinationEnd))
        }

        private static func applyDetectedLinks(to attributedString: NSMutableAttributedString) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
            let fullRange = NSRange(location: 0, length: attributedString.length)
            detector.enumerateMatches(in: attributedString.string, range: fullRange) { match, _, _ in
                guard let match, let url = match.url else { return }
                attributedString.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: match.range)
            }
        }

        private static func applyFilePathHighlights(to attributedString: NSMutableAttributedString, pointSize: CGFloat) {
            let pattern = #"(?<![\w:/])((?:~|\.\.?|[A-Za-z0-9_.-]+)?(?:/[A-Za-z0-9_.-]+)+|(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+)(?::[0-9]+)?"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let fullRange = NSRange(location: 0, length: attributedString.length)
            regex.enumerateMatches(in: attributedString.string, range: fullRange) { match, _, _ in
                guard let match else { return }
                if attributedString.attribute(.link, at: match.range.location, effectiveRange: nil) != nil {
                    return
                }
                attributedString.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular),
                    .foregroundColor: NSColor.controlAccentColor
                ], range: match.range)
            }
        }
    }
}

private final class SelectableTextContainerView: NSView {
    let textView = NSTextView()
    var onHeightChanged: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(textView)
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        updateTextContainerSize()
        recalculateHeight()
    }

    func forceLayoutRecalculation() {
        updateTextContainerSize()
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        recalculateHeight()
    }

    func recalculateHeight() {
        guard let textContainer = textView.textContainer else { return }
        updateTextContainerSize()
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedRect = textView.layoutManager?.usedRect(for: textContainer) ?? .zero
        onHeightChanged?(max(28, ceil(usedRect.height) + 4))
    }

    private func updateTextContainerSize() {
        let width = max(bounds.width, 1)
        textView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: bounds.height))
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case bullet
        case code
        case table
    }

    let id = UUID()
    let kind: Kind
    let text: String

    var inlineAttributedString: AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(text)
        }
    }

    static func parse(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var tableLines: [String] = []
        var inCodeBlock = false

        func flushParagraph() {
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(MarkdownBlock(kind: .paragraph, text: text))
            }
            paragraphLines.removeAll()
        }

        func flushCode() {
            blocks.append(MarkdownBlock(kind: .code, text: codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }

        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if tableLines.count >= 2, tableLines.contains(where: isTableSeparator) {
                let rows = tableLines
                    .filter { !isTableSeparator($0) }
                    .map(tableCells)
                    .filter { !$0.isEmpty }
                let text = formattedTable(rows)
                if !text.isEmpty {
                    blocks.append(MarkdownBlock(kind: .table, text: text))
                }
            } else {
                paragraphLines.append(contentsOf: tableLines)
            }
            tableLines.removeAll()
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCodeBlock {
                    flushCode()
                    inCodeBlock = false
                } else {
                    flushTable()
                    flushParagraph()
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushTable()
                flushParagraph()
                continue
            }

            if isTableCandidate(line) {
                flushParagraph()
                tableLines.append(line)
                continue
            } else {
                flushTable()
            }

            if let heading = heading(from: line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level), text: heading.text))
                continue
            }

            if let bullet = bulletText(from: line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .bullet, text: bullet))
                continue
            }

            paragraphLines.append(rawLine)
        }

        if inCodeBlock {
            flushCode()
        }
        flushTable()
        flushParagraph()

        return blocks.isEmpty ? [MarkdownBlock(kind: .paragraph, text: content)] : blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let markerCount = line.prefix { $0 == "#" }.count
        guard (1...6).contains(markerCount) else { return nil }
        let rest = line.dropFirst(markerCount)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (markerCount, text)
    }

    private static func bulletText(from line: String) -> String? {
        for marker in ["* ", "- ", "• "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        let parts = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2,
           let number = Int(parts[0]),
           number > 0,
           parts[1].hasPrefix(" ") {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    private static func isTableCandidate(_ line: String) -> Bool {
        line.contains("|") && tableCells(line).count >= 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let cleaned = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            return cleaned.trimmingCharacters(in: .whitespaces).isEmpty && cell.contains("-")
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        if cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private static func formattedTable(_ rows: [[String]]) -> String {
        guard let columnCount = rows.map(\.count).max(), columnCount > 0 else { return "" }
        let widths = (0..<columnCount).map { column in
            rows.map { row in
                column < row.count ? row[column].count : 0
            }.max() ?? 0
        }
        return rows.map { row in
            (0..<columnCount).map { column in
                let value = column < row.count ? row[column] : ""
                return value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

private struct SessionInspectorPanel: View {
    let session: Session?
    @Binding var isExpanded: Bool
    let messagesCount: Int
    let toolCalls: [ToolCall]
    let fileChanges: [FileChange]
    let changeSetsByID: [Int64: ChangeSet]
    let preflightResults: [Int64: ChangePreflightResult]
    let runMap: OrchestrationRunMap?
    let childRuns: [Session]
    let agentName: String
    let workspaceName: String
    let agentNameForID: (Int64) -> String
    let workspaceNameForID: (Int64?) -> String
    let onOpenChildRun: (Int64) -> Void
    let onOpenRunNode: (Int64) -> Void
    let onOpenChanges: (Int64?) -> Void
    let onApprove: (Int64) -> Void
    let onReject: (Int64) -> Void

    var body: some View {
        Group {
            if isExpanded {
                expandedInspector
            } else {
                collapsedRail
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var collapsedRail: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded = true
                }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Show Session Details")

            if session != nil {
                InspectorRailBadge(symbol: "message", value: messagesCount)
                InspectorRailBadge(symbol: "list.bullet.rectangle", value: toolCalls.count)
                InspectorRailBadge(symbol: "arrow.triangle.branch", value: childRuns.count)
                InspectorRailBadge(symbol: "doc.text.magnifyingglass", value: fileChanges.filter(\.pending).count)
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var expandedInspector: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SessionDetailsContent(
                            session: session,
                            agentName: agentName,
                            workspaceName: workspaceName,
                            messagesCount: messagesCount,
                            toolCallsCount: toolCalls.count,
                            changesCount: fileChanges.count
                        )

                        if let runMap, runMap.shouldShow {
                            DisclosureGroup {
                                OrchestrationRunMapInspectorContent(
                                    runMap: runMap,
                                    onOpenSession: onOpenRunNode,
                                    onOpenChanges: onOpenChanges
                                )
                                .padding(.top, 8)
                            } label: {
                                InspectorDisclosureLabel(title: "Run Map", symbol: "point.3.connected.trianglepath.dotted", count: runMap.nodes.count)
                            }
                        }

                        if !childRuns.isEmpty {
                            DisclosureGroup {
                                ChildRunsInspectorContent(
                                    childRuns: childRuns,
                                    agentName: agentNameForID,
                                    workspaceName: workspaceNameForID,
                                    onOpen: onOpenChildRun
                                )
                                .padding(.top, 8)
                            } label: {
                                InspectorDisclosureLabel(title: "Sub-Agent Sessions", symbol: "arrow.triangle.branch", count: childRuns.count)
                            }
                        }

                        DisclosureGroup {
                            ActivityInspectorContent(toolCalls: toolCalls)
                                .padding(.top, 8)
                        } label: {
                            InspectorDisclosureLabel(title: "Activity", symbol: "list.bullet.rectangle", count: toolCalls.count)
                        }

                        DisclosureGroup {
                            ChangesInspectorContent(
                                fileChanges: fileChanges,
                                changeSetsByID: changeSetsByID,
                                preflightResults: preflightResults,
                                workspaceName: workspaceNameForID,
                                onApprove: onApprove,
                                onReject: onReject
                            )
                            .padding(.top, 8)
                        } label: {
                            InspectorDisclosureLabel(
                                title: "Changes",
                                symbol: "doc.text.magnifyingglass",
                                count: fileChanges.filter(\.pending).count
                            )
                        }
                    }
                    .padding(14)
                }
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "sidebar.right",
                    description: Text("Select or open a session to see details.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Label("Session", systemImage: "sidebar.right")
                .font(.headline)
            Spacer()
            if let session {
                Text("#\(session.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded = false
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .help("Collapse Inspector")
        }
        .padding(14)
    }
}

private struct InspectorRailBadge: View {
    let symbol: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .foregroundStyle(value > 0 ? .primary : .secondary)
            Text(value.formatted())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help("\(value)")
    }
}

private struct InspectorDisclosureLabel: View {
    let title: String
    let symbol: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.headline)
            Spacer()
            Text(count.formatted())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct SessionDetailsContent: View {
    let session: Session
    let agentName: String
    let workspaceName: String
    let messagesCount: Int
    let toolCallsCount: Int
    let changesCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("Session") {
                DetailValueRow(title: "Agent", value: agentName)
                DetailValueRow(title: "Workspace", value: workspaceName)
                if session.hasParentProvenance {
                    DetailValueRow(title: "Session Type", value: session.detachedChildRun ? "Detached \(session.orchestrationRole?.title ?? "Sub-Agent Session")" : (session.orchestrationRole?.title ?? "Sub-Agent Session"))
                    if let parentSessionID = session.parentSessionID {
                        DetailValueRow(title: "Parent", value: "#\(parentSessionID)")
                    }
                }
                DetailValueRow(title: "Status", value: session.status.rawValue.capitalized)
                DetailValueRow(title: "Started", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
            }

            InspectorSection("Counts") {
                DetailValueRow(title: "Messages", value: messagesCount.formatted())
                DetailValueRow(title: "Tool Calls", value: toolCallsCount.formatted())
                DetailValueRow(title: "Changes", value: changesCount.formatted())
            }

            InspectorSection("Summary") {
                Text(session.summary.isEmpty ? "New session" : session.summary)
                    .font(.callout)
                    .foregroundStyle(session.summary.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ChildRunsInspectorContent: View {
    let childRuns: [Session]
    let agentName: (Int64) -> String
    let workspaceName: (Int64?) -> String
    let onOpen: (Int64) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(childRuns) { childRun in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(childRun.orchestrationRole?.title ?? "Sub-Agent Session", systemImage: childRun.orchestrationRole?.systemImage ?? "arrow.triangle.branch")
                            .font(.callout.weight(.semibold))

                        Spacer()

                        Text("#\(childRun.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Text(childRun.summary.isEmpty ? "Delegated task" : childRun.summary)
                        .font(.callout)
                        .lineLimit(2)

                    Text("\(agentName(childRun.agentID))  |  \(workspaceName(childRun.workspaceID))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack {
                        StatusPill(text: childRun.status.rawValue.capitalized)
                        if childRun.detachedChildRun {
                            StatusPill(text: "Detached")
                        }
                        Spacer()
                        Button {
                            onOpen(childRun.id)
                        } label: {
                            Label("Open", systemImage: "arrow.right.circle")
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct OrchestrationRunMapInspectorContent: View {
    let runMap: OrchestrationRunMap
    let onOpenSession: (Int64) -> Void
    let onOpenChanges: (Int64?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            runSummary

            ForEach(runMap.nodes) { node in
                OrchestrationRunNodeCard(
                    node: node,
                    isSelected: node.id == runMap.selectedSessionID,
                    onOpenSession: { onOpenSession(node.id) },
                    onOpenChanges: { onOpenChanges(node.id) }
                )
                .padding(.leading, CGFloat(min(node.depth, 3)) * 14)
            }
        }
    }

    private var runSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDotPill(text: "\(runMap.summary.childRuns) child", color: .blue)
                StatusDotPill(text: "\(runMap.summary.pendingChanges) pending", color: .orange)
            }
            HStack(spacing: 8) {
                StatusDotPill(text: "\(runMap.summary.appliedChanges) applied", color: .green)
                if runMap.summary.blockedChanges > 0 {
                    StatusDotPill(text: "\(runMap.summary.blockedChanges) blocked", color: .red)
                }
                if runMap.summary.detachedRuns > 0 {
                    StatusDotPill(text: "\(runMap.summary.detachedRuns) detached", color: .secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct OrchestrationRunNodeCard: View {
    let node: OrchestrationRunNode
    let isSelected: Bool
    let onOpenSession: () -> Void
    let onOpenChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(node.roleTitle, systemImage: node.roleSymbol)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text("#\(node.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(node.title)
                .font(.callout)
                .lineLimit(2)

            Text("\(node.agentName)  |  \(node.workspaceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 7) {
                StatusPill(text: node.status.rawValue.capitalized)
                if node.detached {
                    StatusPill(text: "Detached")
                }
                if node.pendingChanges > 0 {
                    StatusDotPill(text: "\(node.pendingChanges) pending", color: .orange)
                }
                if node.blockedChanges > 0 {
                    StatusDotPill(text: "\(node.blockedChanges) blocked", color: .red)
                }
            }

            if !node.issues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(node.issues.prefix(3)) { issue in
                        Label(issue.title, systemImage: issue.severity == .blocked ? "xmark.octagon" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(issue.severity == .blocked ? .red : .secondary)
                    }
                }
            }

            HStack {
                Button {
                    onOpenChanges()
                } label: {
                    Label("Changes", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(node.pendingChanges + node.appliedChanges + node.rejectedChanges == 0)

                Spacer()

                Button {
                    onOpenSession()
                } label: {
                    Label(isSelected ? "Current" : "Open", systemImage: isSelected ? "largecircle.fill.circle" : "arrow.right.circle")
                }
                .disabled(isSelected)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.48) : Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ActivityInspectorContent: View {
    let toolCalls: [ToolCall]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if toolCalls.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Tool calls for this session will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ForEach(toolCalls) { toolCall in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Arguments")
                                .font(.caption.weight(.semibold))
                            Text(toolCall.argumentsJSON.isEmpty ? "-" : toolCall.argumentsJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text("Result")
                                .font(.caption.weight(.semibold))
                            Text(toolCall.resultJSON.isEmpty ? "-" : toolCall.resultJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: toolCall.successful ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(toolCall.successful ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(toolCall.toolName)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(toolCall.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

private struct ChangesInspectorContent: View {
    let fileChanges: [FileChange]
    let changeSetsByID: [Int64: ChangeSet]
    let preflightResults: [Int64: ChangePreflightResult]
    let workspaceName: (Int64?) -> String
    let onApprove: (Int64) -> Void
    let onReject: (Int64) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if fileChanges.isEmpty {
                ContentUnavailableView(
                    "No Proposed Changes",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("File proposals for this session will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ForEach(fileChanges) { fileChange in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(fileChange.filePath)
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            StatusPill(text: fileChange.status.capitalized)
                            if fileChange.pending, let preflight = preflightResults[fileChange.id] {
                                StatusPill(text: preflight.status.title)
                            }
                        }

                        if let changeSet = changeSetsByID[fileChange.changeSetID] {
                            Text(workspaceName(changeSet.workspaceID))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Text(fileChange.diffText.isEmpty ? "No diff preview available." : fileChange.diffText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(16)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        if fileChange.pending {
                            if let preflight = preflightResults[fileChange.id], !preflight.issues.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(preflight.issues.prefix(2)) { issue in
                                        Label(issue.title, systemImage: issue.severity == .blocked ? "xmark.octagon" : "exclamationmark.triangle")
                                            .font(.caption)
                                            .foregroundStyle(issue.severity == .blocked ? .red : .secondary)
                                    }
                                }
                            }

                            HStack {
                                Spacer()
                                Button("Reject", role: .destructive) {
                                    onReject(fileChange.id)
                                }
                                Button("Approve") {
                                    onApprove(fileChange.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(preflightResults[fileChange.id]?.canApprove == false)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct DetailValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.callout)
    }
}

private struct InlineHint: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
    }
}

private struct StatusDotPill: View {
    let text: String
    let color: Color

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
