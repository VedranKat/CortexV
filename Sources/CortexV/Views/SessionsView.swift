import AppKit
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedAgentForNewSession: Int64?
    @State private var selectedWorkspaceForNewSession: Int64?
    @State private var isInspectorExpanded = false
    @State private var composerText = ""
    @State private var composerFocusToken = 0

    private var selectedSession: Session? {
        appModel.sessions.first { $0.id == appModel.selectedSessionID }
    }

    private var agentOptions: [Agent] {
        appModel.sessionAgentOptions(for: selectedWorkspaceForNewSession)
    }

    private var canOpenSession: Bool {
        selectedAgentForNewSession != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            HStack(spacing: 0) {
                if let selectedSession {
                    ChatPane(
                        session: selectedSession,
                        messages: appModel.messages,
                        isSending: appModel.isSendingMessage,
                        composerText: $composerText,
                        focusToken: composerFocusToken,
                        agentName: appModel.agentName(for: selectedSession.agentID),
                        workspaceName: appModel.workspaceName(for: selectedSession.workspaceID),
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
                    agentName: selectedSession.map { appModel.agentName(for: $0.agentID) } ?? "",
                    workspaceName: selectedSession.map { appModel.workspaceName(for: $0.workspaceID) } ?? "",
                    workspaceNameForID: appModel.workspaceName(for:),
                    onApprove: appModel.approveFileChange(id:),
                    onReject: appModel.rejectFileChange(id:)
                )
                .frame(width: isInspectorExpanded ? (compact ? 280 : 330) : 44)
            }
        }
        .navigationTitle(selectedSession == nil ? "Start Session" : "Session")
        .toolbar {
            ToolbarItemGroup {
                Button(role: .destructive) {
                    appModel.deleteSelectedSession()
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
                .disabled(selectedSession == nil)
            }
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
    let isSending: Bool
    @Binding var composerText: String
    let focusToken: Int
    let agentName: String
    let workspaceName: String
    let onSend: () -> Void

    @State private var composerHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            chatHeader(session: session)
            Divider()
            messageList
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func chatHeader(session: Session) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.summary.isEmpty ? "Session #\(session.id)" : session.summary)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(agentName)  |  \(workspaceName)")
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "No Messages",
                            systemImage: "message",
                            description: Text("Send the first message to start this session.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(18)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
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
                    Text("Choose a workspace first, then pick an agent bound to that folder.")
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
                    .disabled(!hasWorkspace)

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

    private var roleLabel: String {
        if isUser {
            return "Me"
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
            .background(isUser ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !isUser { Spacer(minLength: 56) }
        }
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
        }

        func updateHeight(_ height: CGFloat) {
            guard abs(parent.calculatedHeight - height) > 0.5 else { return }
            parent.calculatedHeight = height
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
                style.paragraphSpacing = 8
                style.lineSpacing = 2
                let font: NSFont = level == 1
                    ? .systemFont(ofSize: 17, weight: .semibold)
                    : .systemFont(ofSize: 14, weight: .semibold)
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
                style.headIndent = 17
                let font = NSFont.systemFont(ofSize: 14.5)
                return attributedInlineMarkdown(
                    "• \(block.text)",
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
                        .paragraphStyle: style
                    ]
                )
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
                output.append(NSAttributedString(
                    string: buffer,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraphStyle
                    ]
                ))
                buffer.removeAll()
            }

            while index < text.endIndex {
                if text[index...].hasPrefix("**") {
                    flush()
                    isBold.toggle()
                    index = text.index(index, offsetBy: 2)
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
            return output
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
        textView.textContainer?.containerSize = NSSize(width: max(bounds.width, 1), height: CGFloat.greatestFiniteMagnitude)
        recalculateHeight()
    }

    func recalculateHeight() {
        guard let textContainer = textView.textContainer else { return }
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedRect = textView.layoutManager?.usedRect(for: textContainer) ?? .zero
        onHeightChanged?(max(28, ceil(usedRect.height) + 4))
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case bullet
        case code
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

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCodeBlock {
                    flushCode()
                    inCodeBlock = false
                } else {
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
                flushParagraph()
                continue
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
        flushParagraph()

        return blocks.isEmpty ? [MarkdownBlock(kind: .paragraph, text: content)] : blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let markerCount = line.prefix { $0 == "#" }.count
        guard (1...3).contains(markerCount) else { return nil }
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
}

private struct SessionInspectorPanel: View {
    let session: Session?
    @Binding var isExpanded: Bool
    let messagesCount: Int
    let toolCalls: [ToolCall]
    let fileChanges: [FileChange]
    let changeSetsByID: [Int64: ChangeSet]
    let agentName: String
    let workspaceName: String
    let workspaceNameForID: (Int64?) -> String
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
                            HStack {
                                Spacer()
                                Button("Reject", role: .destructive) {
                                    onReject(fileChange.id)
                                }
                                Button("Approve") {
                                    onApprove(fileChange.id)
                                }
                                .buttonStyle(.borderedProminent)
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
