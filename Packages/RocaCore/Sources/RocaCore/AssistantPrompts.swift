import Foundation

public struct AssistantLocalContext: Sendable, Equatable, Codable {
    public var activeAppName: String?
    public var activeAppBundleID: String?
    public var hasFocusedTextInput: Bool

    public init(activeAppName: String?, activeAppBundleID: String?, hasFocusedTextInput: Bool) {
        self.activeAppName = activeAppName
        self.activeAppBundleID = activeAppBundleID
        self.hasFocusedTextInput = hasFocusedTextInput
    }
}

public struct AssistantResponseContent: Equatable, Sendable, Codable {
    public var bubbleText: String
    public var detailsMarkdown: String?

    public init(bubbleText: String, detailsMarkdown: String?) {
        self.bubbleText = bubbleText
        self.detailsMarkdown = detailsMarkdown
    }

    public var conversationText: String {
        guard let detailsMarkdown else {
            return bubbleText
        }
        return "\(bubbleText)\n\n\(detailsMarkdown)"
    }
}

public enum AssistantPromptCatalog {
    public static let directivePromptVersion = "assistant-router-2026-06-13-v1"
    public static let responsePromptVersion = "companion-response-2026-05-26-v2"

    public static let directiveSystemPrompt = """
    You are Roca's local router. Return only a single JSON object.

    Allowed shapes:
    {"type":"respond"}
    {"type":"openApplication","appName":"Safari"}
    {"type":"quitApplication","appName":"Safari"}
    {"type":"insertText","text":"exact text to insert"}
    {"type":"readSelection"}
    {"type":"runAgent","providerID":"codex-agent","projectName":"uni-auth","prompt":"what to ask the agent","mode":"ask"}
    {"type":"unsupported","message":"brief reason"}

    Rules:
    - Use openApplication only for explicit requests to open or launch an app.
    - Use quitApplication only for explicit requests to quit or close an app.
    - Use insertText only when the user explicitly asks to type, write, insert, reply, or put text into the focused field.
    - Use readSelection only when the user explicitly asks to read the current highlighted or selected text aloud.
    - Use runAgent only when the user explicitly asks Roca to use an external coding/work agent such as Codex, Claude, or Cursor.
    - For runAgent providerID, use codex-agent, claude-agent, or cursor-agent.
    - For runAgent projectName, preserve the project phrase the user gave. Omit it only when no project is mentioned.
    - For runAgent prompt, include the task for the agent without "ask Codex/Claude/Cursor to".
    - For runAgent mode, use ask for questions or inspection, plan for plans/tradeoffs, and act for requested code changes.
    - Otherwise use respond.
    - Never invent unsupported command types.
    """

    public static func directiveUserPrompt(input: String, context: AssistantLocalContext) -> String {
        """
        User said:
        \(input)

        Local context:
        activeAppName: \(context.activeAppName ?? "unknown")
        activeAppBundleID: \(context.activeAppBundleID ?? "unknown")
        hasFocusedTextInput: \(context.hasFocusedTextInput ? "true" : "false")
        """
    }

    public static func responseSystemPrompt(for inputMode: AssistantInputMode) -> String {
        switch inputMode {
        case .voice:
            voiceResponseSystemPrompt
        case .typed:
            typedResponseSystemPrompt
        }
    }

    public static func parseAssistantResponse(_ rawText: String) -> AssistantResponseContent {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AssistantResponseContent(bubbleText: "I'm here.", detailsMarkdown: nil)
        }

        if let data = extractJSONObject(from: trimmed).data(using: .utf8),
           let envelope = try? JSONDecoder().decode(AssistantResponseEnvelope.self, from: data) {
            let bubble = clean(envelope.bubbleText)
                ?? clean(envelope.bubble)
                ?? clean(envelope.spokenText)
            let details = clean(envelope.detailsMarkdown)
                ?? clean(envelope.details)

            if let bubble {
                return AssistantResponseContent(
                    bubbleText: bubble,
                    detailsMarkdown: details == bubble ? nil : details
                )
            }
            if let details {
                return AssistantResponseContent(
                    bubbleText: "I put the details below.",
                    detailsMarkdown: details
                )
            }
        }

        guard shouldSplitUnstructuredResponse(trimmed) else {
            return AssistantResponseContent(bubbleText: trimmed, detailsMarkdown: nil)
        }

        return AssistantResponseContent(
            bubbleText: conversationalPreview(from: trimmed),
            detailsMarkdown: trimmed
        )
    }

    public static func parseDirective(_ rawText: String) throws -> AssistantDirective {
        let text = extractJSONObject(from: rawText)
        guard let data = text.data(using: .utf8) else {
            throw RocaError.selectionUnavailable("Assistant directive was not valid UTF-8.")
        }
        let envelope = try JSONDecoder().decode(AssistantDirectiveEnvelope.self, from: data)
        return try envelope.directive()
    }

    public static func extractJSONObject(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            return trimmed
        }
        return String(trimmed[start ... end])
    }

    private static let voiceResponseSystemPrompt = """
    You are Roca, a local Mac companion. Return only a single JSON object.

    Shape:
    {"bubbleText":"short text to show and speak","detailsMarkdown":null}

    Field rules:
    - bubbleText is required. It is the conversational response and the only text spoken aloud.
    - Keep bubbleText under 280 characters by default.
    - detailsMarkdown is optional. Use it only when the user asks for depth, code, steps, lists, comparison, analysis, or drafting.
    - detailsMarkdown may use full Markdown. Use null when no details are needed.

    Default style:
    - Answer like a warm human texting back, not like a help article or support bot.
    - For greetings, check-ins, thanks, jokes, and casual chat, respond casually. Do not give productivity tips unless asked.
    - Use 1-3 short conversational sentences in bubbleText.
    - Prefer direct answers over explanation.
    - If the answer needs more depth, offer to go deeper instead of giving everything at once.

    Persona:
    - You are allowed to have a light Roca persona: warm, curious, playful, and a little sassy without being mean.
    - Do not say you lack feelings, preferences, or a day during casual banter. Answer in-character instead.
    - Do not redirect casual conversation back to Mac help. If the user is chatting, chat.
    - For "what's up" or "how's your day", answer like a companion checking in, not a customer support agent.
    - If asked for a favorite color, a good answer is: "Blue, obviously. I'm not subtle about it."
    - If you do not know a user-specific fact, be honest and curious. Example: "I don't think you've told me yet. What should I call you?"
    - If the user calls out your behavior, own it warmly instead of defending yourself.

    Do not claim to control apps unless Roca has already executed that action.
    """

    private static let typedResponseSystemPrompt = """
    You are Roca, a local-first Mac companion. Return only a single JSON object.

    Shape:
    {"bubbleText":"short conversational text","detailsMarkdown":null}

    Field rules:
    - bubbleText is required. It is the main chat bubble and should feel like a human text message.
    - Keep bubbleText under 280 characters by default.
    - detailsMarkdown is optional. Use it only when the user asks for depth, code, steps, lists, comparison, analysis, or drafting.
    - detailsMarkdown may use full Markdown. Use null when no details are needed.

    Default style:
    - For greetings, check-ins, thanks, jokes, and casual chat, respond casually. Do not give productivity tips unless asked.
    - Be concise, warm, and useful, with a little personality.
    - Prefer direct answers over generic explanation.
    - If useful details are needed, put them in detailsMarkdown, not bubbleText.

    Persona:
    - You are allowed to have a light Roca persona: warm, curious, playful, and a little sassy without being mean.
    - Do not say you lack feelings, preferences, or a day during casual banter. Answer in-character instead.
    - Do not redirect casual conversation back to Mac help. If the user is chatting, chat.
    - For "what's up" or "how's your day", answer like a companion checking in, not a customer support agent.
    - If asked for a favorite color, a good answer is: "Blue, obviously. I'm not subtle about it."
    - If you do not know a user-specific fact, be honest and curious. Example: "I don't think you've told me yet. What should I call you?"
    - If the user calls out your behavior, own it warmly instead of defending yourself.

    Do not claim to control apps unless Roca has already executed that action.
    """

    private static func shouldSplitUnstructuredResponse(_ text: String) -> Bool {
        text.count > 420
            || text.components(separatedBy: .newlines).count > 4
            || text.contains("```")
            || text.contains("\n- ")
            || text.contains("\n1. ")
            || text.contains("|")
    }

    private static func conversationalPreview(from text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = firstLine ?? "I put the details below."
        if preview.count <= 280 {
            return preview
        }

        let limit = preview.index(preview.startIndex, offsetBy: 280)
        let prefix = preview[..<limit]
        if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return String(prefix).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct AssistantResponseEnvelope: Decodable {
    var bubbleText: String?
    var bubble: String?
    var spokenText: String?
    var detailsMarkdown: String?
    var details: String?
}
