import Foundation

public enum AssistantDiagnosticEventKind: String, Codable, Sendable {
    case turnStarted
    case turnCompleted
    case turnCancelled
    case turnFailed
    case turnBlocked
    case directiveResolved
    case agentProjectLookupStarted
    case agentProjectLookupCompleted
    case agentProjectLookupFailed
    case agentProviderDiagnostic
    case skillRunStarted
    case skillRunCompleted
    case skillRunFailed
    case agentRunStarted
    case agentRunCompleted
    case agentRunFailed
}

public struct AssistantDiagnosticEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var turnID: BrainRequestID?
    public var kind: AssistantDiagnosticEventKind
    public var phase: String?
    public var providerID: ProviderID?
    public var modelID: String?
    public var directiveType: AssistantDirectiveType?
    public var outcome: String?
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        turnID: BrainRequestID? = nil,
        kind: AssistantDiagnosticEventKind,
        phase: String? = nil,
        providerID: ProviderID? = nil,
        modelID: String? = nil,
        directiveType: AssistantDirectiveType? = nil,
        outcome: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.turnID = turnID
        self.kind = kind
        self.phase = phase
        self.providerID = providerID
        self.modelID = modelID
        self.directiveType = directiveType
        self.outcome = outcome
        self.metadata = metadata
    }
}
