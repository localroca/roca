import AppKit
import RocaCore
import SwiftUI

@MainActor
final class ChatPanelWindowController: NSWindowController, NSWindowDelegate {
    private let model: RocaAppModel
    private let visibilityDidChange: @MainActor () -> Void
    private var isChatOpen = false

    init(model: RocaAppModel, visibilityDidChange: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.visibilityDidChange = visibilityDidChange

        let contentView = ChatPanelView(model: model)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Roca"
        window.setContentSize(NSSize(width: 560, height: 680))
        window.minSize = NSSize(width: 420, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RocaChatPanelWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showChat() {
        guard let window else {
            return
        }
        setOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isOpen: Bool {
        isChatOpen
    }

    func closeChat() {
        setOpen(false)
        window?.close()
    }

    func owns(_ candidate: NSWindow?) -> Bool {
        candidate === window
    }

    func windowWillClose(_ notification: Notification) {
        setOpen(false)
    }

    private func setOpen(_ open: Bool) {
        guard isChatOpen != open else {
            return
        }
        isChatOpen = open
        visibilityDidChange()
    }
}

private struct ChatPanelView: View {
    @ObservedObject var model: RocaAppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(chatStatusColor(for: model.companionActivity))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text("Roca")
                    .font(.headline)
                Text(model.assistantStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                model.clearChatConversation()
            } label: {
                Label("Clear Conversation", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Clear Conversation")

            if model.isAssistantTurnActive || model.isAssistantActive {
                Button {
                    model.cancelAssistant()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.chatMessages) { message in
                        ChatMessageRow(message: message) { messageID, decision in
                            model.respondToAgentApproval(messageID: messageID, decision: decision)
                        }
                            .id(message.id)
                    }
                }
                .padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
            .onChange(of: model.chatMessages) { _, messages in
                guard let last = messages.last else {
                    return
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                model.toggleAssistant()
            } label: {
                Label(
                    model.isAssistantActive || model.isAssistantTurnActive ? "Stop" : "Speak",
                    systemImage: model.isAssistantActive || model.isAssistantTurnActive ? "stop.fill" : "mic.fill"
                )
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .help(model.isAssistantActive || model.isAssistantTurnActive ? "Stop Roca" : "Speak to Roca")

            TextField("Message Roca", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 5)
                .onSubmit(sendDraft)

            Button {
                sendDraft()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send")
        }
        .padding(14)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        draft = ""
        model.sendChatMessage(text)
    }

    private func chatStatusColor(for activity: RocaActivity) -> Color {
        switch activity {
        case .idle:
            .secondary
        case .readingSelection, .thinking, .preparingSpeech:
            Color(red: 0.98, green: 0.70, blue: 0.24)
        case .listening, .transcribing:
            Color(red: 0.25, green: 0.78, blue: 1.0)
        case .speaking:
            Color(red: 0.24, green: 0.78, blue: 0.48)
        case .interrupted, .muted:
            .secondary
        case .offline, .waitingForPermission:
            Color(red: 0.92, green: 0.32, blue: 0.28)
        }
    }
}

private struct ChatMessageRow: View {
    var message: ChatMessage
    var onApprovalDecision: (ChatMessageID, AgentApprovalDecision) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 48)
                bubble
            }
        case .assistant:
            assistantResponse
        case .action, .status:
            HStack(alignment: .top) {
                bubble
                Spacer(minLength: 48)
            }
        }
    }

    private var assistantResponse: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                bubble
                Spacer(minLength: 48)
            }

            if let details = message.detailsMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
               !details.isEmpty {
                AssistantMarkdownView(text: details)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            messageHeader
            messageBody
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var messageHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
            if message.status == .pending || message.status == .streaming {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
            }
        }
        .foregroundStyle(headerColor)
    }

    @ViewBuilder
    private var messageBody: some View {
        let text = message.text.isEmpty ? "..." : message.text
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.body)
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let approval = message.approvalRequest {
                ApprovalPromptView(
                    approval: approval,
                    isPending: message.status == .pending && approval.decision == nil,
                    onDecision: { decision in
                        onApprovalDecision(message.id, decision)
                    }
                )
            }
        }
    }

    private var title: String {
        switch message.role {
        case .user:
            message.source == .voice ? "You said" : "You"
        case .assistant:
            "Roca"
        case .action:
            "Action"
        case .status:
            "Status"
        }
    }

    private var iconName: String {
        switch message.role {
        case .user:
            message.source == .voice ? "waveform" : "person.fill"
        case .assistant:
            "sparkles"
        case .action:
            "bolt.fill"
        case .status:
            message.status == .failed ? "exclamationmark.circle" : "info.circle"
        }
    }

    private var headerColor: Color {
        switch message.status {
        case .failed:
            .red
        case .cancelled:
            .secondary
        case .pending, .streaming:
            .blue
        case .completed:
            message.role == .user ? .white.opacity(0.82) : .secondary
        }
    }

    private var background: Color {
        switch message.role {
        case .user:
            .blue
        case .assistant:
            Color(nsColor: .controlBackgroundColor)
        case .action:
            Color.accentColor.opacity(0.12)
        case .status:
            message.status == .failed ? Color.red.opacity(0.10) : Color.secondary.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch message.status {
        case .failed:
            .red.opacity(0.32)
        case .pending, .streaming:
            .blue.opacity(0.26)
        case .cancelled:
            .secondary.opacity(0.22)
        case .completed:
            .secondary.opacity(message.role == .user ? 0 : 0.16)
        }
    }
}

private struct ApprovalPromptView: View {
    var approval: ChatApprovalRequest
    var isPending: Bool
    var onDecision: (AgentApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if isPending {
                HStack(spacing: 8) {
                    Button {
                        onDecision(.approve)
                    } label: {
                        Label("Approve Once", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Approve this request once")

                    Button {
                        onDecision(.approveForSession)
                    } label: {
                        Label("Always Approve", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remember this approval")

                    Button(role: .destructive) {
                        onDecision(.deny)
                    } label: {
                        Label("Deny", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Deny this request")
                }
            } else if let decision = approval.decision {
                Label(resolvedText(for: decision), systemImage: resolvedIcon(for: decision))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resolvedColor(for: decision))
            }
        }
    }

    private func resolvedText(for decision: AgentApprovalDecision) -> String {
        switch decision {
        case .approve:
            "Approved once"
        case .approveForSession:
            "Remembered approval"
        case .deny:
            "Denied"
        case .cancel:
            "Cancelled"
        }
    }

    private func resolvedIcon(for decision: AgentApprovalDecision) -> String {
        switch decision {
        case .approve, .approveForSession:
            "checkmark.circle.fill"
        case .deny:
            "xmark.circle.fill"
        case .cancel:
            "minus.circle.fill"
        }
    }

    private func resolvedColor(for decision: AgentApprovalDecision) -> Color {
        switch decision {
        case .approve, .approveForSession:
            .green
        case .deny:
            .red
        case .cancel:
            .secondary
        }
    }
}

private struct AssistantMarkdownView: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text: text, font: headingFont(for: level))
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            InlineMarkdownText(text: text)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        InlineMarkdownText(text: item)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                        InlineMarkdownText(text: item)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                InlineMarkdownText(text: text, color: .secondary)
            }
            .padding(.vertical, 2)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            .title3.weight(.semibold)
        case 2:
            .headline
        default:
            .subheadline.weight(.semibold)
        }
    }
}

private struct InlineMarkdownText: View {
    var text: String
    var font: Font = .body
    var color: Color = .primary

    var body: some View {
        renderedText
            .font(font)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var renderedText: Text {
        if let attributed = try? AttributedString(
            markdown: preservingSoftBreaks(text),
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

    private func preservingSoftBreaks(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "\n", with: "  \n")
    }
}

private struct CodeBlockView: View {
    var language: String?
    var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct MarkdownTableView: View {
    var headers: [String]
    var rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                row(headers, isHeader: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    row(cells, isHeader: false)
                    Divider().opacity(0.45)
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0 ..< max(headers.count, cells.count), id: \.self) { index in
                InlineMarkdownText(
                    text: index < cells.count ? cells[index] : "",
                    font: isHeader ? .callout.weight(.semibold) : .callout
                )
                .frame(minWidth: 96, maxWidth: 180, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }
}

private enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case divider

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = normalizedLines(markdown)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraphLines.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fenceStart(in: trimmed) {
                flushParagraph()
                let parsed = codeBlock(startingAt: index, lines: lines, fence: fence)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if let table = tableBlock(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let quote = quoteBlock(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(quote.block)
                index = quote.nextIndex
                continue
            }

            if let list = unorderedList(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(.unorderedList(list.items))
                index = list.nextIndex
                continue
            }

            if let list = orderedList(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(.orderedList(list.items))
                index = list.nextIndex
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks.isEmpty ? [.paragraph(markdown)] : blocks
    }

    private static func normalizedLines(_ markdown: String) -> [String] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }

        guard (1 ... 6).contains(level) else {
            return nil
        }

        let remainder = line.dropFirst(level)
        guard remainder.first == " " else {
            return nil
        }

        return (level, String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3,
              let first = compact.first,
              first == "-" || first == "*" || first == "_"
        else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func fenceStart(in line: String) -> (marker: String, language: String?)? {
        let marker: String
        if line.hasPrefix("```") {
            marker = "```"
        } else if line.hasPrefix("~~~") {
            marker = "~~~"
        } else {
            return nil
        }

        let language = line
            .dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
        return (marker, language.isEmpty ? nil : language)
    }

    private static func codeBlock(
        startingAt index: Int,
        lines: [String],
        fence: (marker: String, language: String?)
    ) -> (block: MarkdownBlock, nextIndex: Int) {
        var codeLines: [String] = []
        var cursor = index + 1
        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                return (.code(language: fence.language, code: codeLines.joined(separator: "\n")), cursor + 1)
            }
            codeLines.append(lines[cursor])
            cursor += 1
        }
        return (.code(language: fence.language, code: codeLines.joined(separator: "\n")), cursor)
    }

    private static func quoteBlock(startingAt index: Int, lines: [String]) -> (block: MarkdownBlock, nextIndex: Int)? {
        guard quoteText(lines[index]) != nil else {
            return nil
        }

        var quoteLines: [String] = []
        var cursor = index
        while cursor < lines.count, let text = quoteText(lines[cursor]) {
            quoteLines.append(text)
            cursor += 1
        }
        return (.quote(quoteLines.joined(separator: "\n")), cursor)
    }

    private static func quoteText(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == ">" else {
            return nil
        }
        return String(trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func unorderedList(startingAt index: Int, lines: [String]) -> (items: [String], nextIndex: Int)? {
        guard unorderedItem(in: lines[index]) != nil else {
            return nil
        }

        var items: [String] = []
        var cursor = index
        while cursor < lines.count {
            if let item = unorderedItem(in: lines[cursor]) {
                items.append(item)
                cursor += 1
            } else if isIndentedContinuation(lines[cursor]), !items.isEmpty {
                items[items.count - 1] += "\n" + lines[cursor].trimmingCharacters(in: .whitespaces)
                cursor += 1
            } else {
                break
            }
        }
        return (items, cursor)
    }

    private static func unorderedItem(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first,
              first == "-" || first == "*" || first == "+"
        else {
            return nil
        }
        let rest = trimmed.dropFirst()
        guard rest.first?.isWhitespace == true else {
            return nil
        }
        return String(rest.drop(while: { $0.isWhitespace }))
    }

    private static func orderedList(startingAt index: Int, lines: [String]) -> (items: [String], nextIndex: Int)? {
        guard orderedItem(in: lines[index]) != nil else {
            return nil
        }

        var items: [String] = []
        var cursor = index
        while cursor < lines.count {
            if let item = orderedItem(in: lines[cursor]) {
                items.append(item)
                cursor += 1
            } else if isIndentedContinuation(lines[cursor]), !items.isEmpty {
                items[items.count - 1] += "\n" + lines[cursor].trimmingCharacters(in: .whitespaces)
                cursor += 1
            } else {
                break
            }
        }
        return (items, cursor)
    }

    private static func orderedItem(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else {
            return nil
        }

        let markerIndex = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard markerIndex < trimmed.endIndex,
              trimmed[markerIndex] == "." || trimmed[markerIndex] == ")"
        else {
            return nil
        }

        let contentStart = trimmed.index(after: markerIndex)
        guard contentStart < trimmed.endIndex,
              trimmed[contentStart].isWhitespace
        else {
            return nil
        }

        return String(trimmed[contentStart...].drop(while: { $0.isWhitespace }))
    }

    private static func isIndentedContinuation(_ line: String) -> Bool {
        line.hasPrefix("  ") || line.hasPrefix("\t")
    }

    private static func tableBlock(startingAt index: Int, lines: [String]) -> (block: MarkdownBlock, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headers = tableRow(lines[index]),
              isTableSeparator(lines[index + 1])
        else {
            return nil
        }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count, let row = tableRow(lines[cursor]) {
            rows.append(row)
            cursor += 1
        }

        return (.table(headers: headers, rows: rows), cursor)
    }

    private static func tableRow(_ line: String) -> [String]? {
        guard line.contains("|") else {
            return nil
        }

        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }

        let cells = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableRow(line), !cells.isEmpty else {
            return false
        }
        return cells.allSatisfy { cell in
            let stripped = cell.filter { $0 != ":" && !$0.isWhitespace }
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }
    }
}
