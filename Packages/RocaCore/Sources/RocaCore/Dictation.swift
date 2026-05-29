import Foundation

public protocol DictationOrchestrating: Sendable {
    var state: DictationState { get async }

    func start(_ request: DictationRequest) async throws
    func stop() async
    func cancel() async
}

public struct DictationRequest: Codable, Sendable, Equatable {
    public var transcriptionID: TranscriptionID
    public var providerID: ProviderID?
    public var locale: String?
    public var mode: STTMode
    public var intent: VoiceInputIntent
    public var insertionTarget: DictationInsertionTarget

    public init(
        transcriptionID: TranscriptionID,
        providerID: ProviderID?,
        locale: String?,
        mode: STTMode,
        intent: VoiceInputIntent,
        insertionTarget: DictationInsertionTarget
    ) {
        self.transcriptionID = transcriptionID
        self.providerID = providerID
        self.locale = locale
        self.mode = mode
        self.intent = intent
        self.insertionTarget = insertionTarget
    }
}

public enum DictationInsertionTarget: String, Codable, Sendable {
    case focusedApp
    case clipboardOnly
    case assistantInput
    case commandHandler
}

public enum DictationState: Equatable, Sendable {
    case idle
    case requestingPermission
    case listening
    case transcribing
    case inserting
    case stopped
    case failed(String)
}

public struct RecoverableDictationTranscript: Equatable, Sendable {
    public var transcriptionID: TranscriptionID
    public var text: String
    public var createdAt: Date
    public var failureMessage: String

    public init(transcriptionID: TranscriptionID, text: String, createdAt: Date, failureMessage: String) {
        self.transcriptionID = transcriptionID
        self.text = text
        self.createdAt = createdAt
        self.failureMessage = failureMessage
    }
}

public struct DictationConfiguration: Codable, Equatable, Sendable {
    public var providerID: ProviderID?
    public var mode: STTMode
    public var locale: String?
    public var allowFallback: Bool

    public init(providerID: ProviderID?, mode: STTMode, locale: String?, allowFallback: Bool) {
        self.providerID = providerID
        self.mode = mode
        self.locale = locale
        self.allowFallback = allowFallback
    }
}
