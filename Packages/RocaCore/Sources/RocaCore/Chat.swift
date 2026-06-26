import Foundation

public struct ChatMessageID: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func make() -> ChatMessageID {
        ChatMessageID(rawValue: UUID().uuidString)
    }
}

public enum ChatMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case action
    case status
}

public enum ChatMessageSource: String, Codable, Sendable {
    case typed
    case voice
    case assistant
    case localAction
    case status
}

public enum ChatMessageStatus: String, Codable, Sendable {
    case pending
    case streaming
    case completed
    case failed
    case cancelled
}

public enum AssistantInputMode: String, Codable, Sendable {
    case typed
    case voice
}

public enum AssistantOutputMode: String, Codable, Sendable {
    case textOnly
    case speakShortResponse
    case speakAll
}

public struct ChatMessageMetadata: Codable, Equatable, Sendable {
    public var inputMode: AssistantInputMode?
    public var outputMode: AssistantOutputMode?
    public var brainProviderID: ProviderID?
    public var brainModelID: String?
    public var brainDisplayName: String?
    public var directiveType: AssistantDirectiveType?
    public var directivePromptVersion: String?
    public var responsePromptVersion: String?

    public init(
        inputMode: AssistantInputMode? = nil,
        outputMode: AssistantOutputMode? = nil,
        brainProviderID: ProviderID? = nil,
        brainModelID: String? = nil,
        brainDisplayName: String? = nil,
        directiveType: AssistantDirectiveType? = nil,
        directivePromptVersion: String? = nil,
        responsePromptVersion: String? = nil
    ) {
        self.inputMode = inputMode
        self.outputMode = outputMode
        self.brainProviderID = brainProviderID
        self.brainModelID = brainModelID
        self.brainDisplayName = brainDisplayName
        self.directiveType = directiveType
        self.directivePromptVersion = directivePromptVersion
        self.responsePromptVersion = responsePromptVersion
    }
}

public struct ChatApprovalRequest: Codable, Equatable, Sendable {
    public var id: ChatMessageID
    public var title: String
    public var detail: String
    public var requirement: AgentApprovalRequirement
    public var allowsRememberedApproval: Bool?
    public var decision: AgentApprovalDecision?
    public var decidedAt: Date?

    public init(
        id: ChatMessageID,
        title: String,
        detail: String,
        requirement: AgentApprovalRequirement,
        allowsRememberedApproval: Bool? = nil,
        decision: AgentApprovalDecision? = nil,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.requirement = requirement
        self.allowsRememberedApproval = allowsRememberedApproval
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

public struct ChatQuestionRequest: Codable, Equatable, Sendable {
    public var id: ChatMessageID
    public var title: String
    public var prompt: AgentQuestionPrompt
    public var response: AgentQuestionResponse?
    public var answeredAt: Date?

    public init(
        id: ChatMessageID,
        title: String,
        prompt: AgentQuestionPrompt,
        response: AgentQuestionResponse? = nil,
        answeredAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.response = response
        self.answeredAt = answeredAt
    }
}

public struct AssistantSessionTurnRequest: Sendable, Equatable {
    public var turnID: BrainRequestID
    public var transcriptionID: TranscriptionID
    public var inputMode: AssistantInputMode
    public var outputMode: AssistantOutputMode
    public var sttProviderID: ProviderID?
    public var brainSelection: BrainProviderSelection
    public var roleSelections: [BrainRole: BrainProviderSelection]
    public var locale: String?
    public var mode: STTMode
    public var speechConfiguration: SpeechConfiguration

    public init(
        turnID: BrainRequestID,
        transcriptionID: TranscriptionID,
        inputMode: AssistantInputMode,
        outputMode: AssistantOutputMode,
        sttProviderID: ProviderID?,
        brainSelection: BrainProviderSelection,
        roleSelections: [BrainRole: BrainProviderSelection] = [:],
        locale: String?,
        mode: STTMode,
        speechConfiguration: SpeechConfiguration
    ) {
        self.turnID = turnID
        self.transcriptionID = transcriptionID
        self.inputMode = inputMode
        self.outputMode = outputMode
        self.sttProviderID = sttProviderID
        self.brainSelection = brainSelection
        self.roleSelections = roleSelections
        self.locale = locale
        self.mode = mode
        self.speechConfiguration = speechConfiguration
    }

    public func selection(for role: BrainRole) -> BrainProviderSelection {
        roleSelections[role] ?? brainSelection
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: ChatMessageID
    public var turnID: BrainRequestID?
    public var role: ChatMessageRole
    public var source: ChatMessageSource
    public var text: String
    public var detailsMarkdown: String?
    public var approvalRequest: ChatApprovalRequest?
    public var questionRequest: ChatQuestionRequest?
    public var status: ChatMessageStatus
    public var metadata: ChatMessageMetadata?
    public var createdAt: Date

    public init(
        id: ChatMessageID = .make(),
        turnID: BrainRequestID? = nil,
        role: ChatMessageRole,
        source: ChatMessageSource,
        text: String,
        detailsMarkdown: String? = nil,
        approvalRequest: ChatApprovalRequest? = nil,
        questionRequest: ChatQuestionRequest? = nil,
        status: ChatMessageStatus,
        metadata: ChatMessageMetadata? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.role = role
        self.source = source
        self.text = text
        self.detailsMarkdown = detailsMarkdown
        self.approvalRequest = approvalRequest
        self.questionRequest = questionRequest
        self.status = status
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
