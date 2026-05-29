import Foundation

public enum AssistantState: Equatable, Sendable {
    case idle
    case requestingPermission
    case listening
    case transcribing
    case thinking
    case acting(String)
    case speaking
    case stopped
    case failed(String)
}

public enum AssistantTurnOutcome: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

public struct AssistantTurnMetrics: Codable, Equatable, Identifiable, Sendable {
    public var id: String { turnID.rawValue }

    public var turnID: BrainRequestID
    public var startedAt: Date
    public var completedAt: Date
    public var outcome: AssistantTurnOutcome
    public var directiveType: AssistantDirectiveType?
    public var totalMilliseconds: Int
    public var setupMilliseconds: Int?
    public var recordingMilliseconds: Int?
    public var transcriptionMilliseconds: Int?
    public var directiveBrainMilliseconds: Int?
    public var responseBrainMilliseconds: Int?
    public var actionMilliseconds: Int?
    public var ttsPreparationMilliseconds: Int?
    public var ttsFirstAudioMilliseconds: Int?
    public var ttsSynthesisMilliseconds: Int?
    public var ttsAudioDurationMilliseconds: Int?
    public var ttsPlaybackMilliseconds: Int?
    public var ttsUtteranceCount: Int?
    public var ttsAudioChunkCount: Int?
    public var capturedAudioFrameCount: Int?
    public var droppedAudioFrameCount: Int?

    public init(
        turnID: BrainRequestID,
        startedAt: Date,
        completedAt: Date,
        outcome: AssistantTurnOutcome,
        directiveType: AssistantDirectiveType?,
        totalMilliseconds: Int,
        setupMilliseconds: Int?,
        recordingMilliseconds: Int?,
        transcriptionMilliseconds: Int?,
        directiveBrainMilliseconds: Int?,
        responseBrainMilliseconds: Int?,
        actionMilliseconds: Int?,
        ttsPreparationMilliseconds: Int?,
        ttsFirstAudioMilliseconds: Int?,
        ttsSynthesisMilliseconds: Int?,
        ttsAudioDurationMilliseconds: Int?,
        ttsPlaybackMilliseconds: Int?,
        ttsUtteranceCount: Int?,
        ttsAudioChunkCount: Int?,
        capturedAudioFrameCount: Int?,
        droppedAudioFrameCount: Int?
    ) {
        self.turnID = turnID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.directiveType = directiveType
        self.totalMilliseconds = totalMilliseconds
        self.setupMilliseconds = setupMilliseconds
        self.recordingMilliseconds = recordingMilliseconds
        self.transcriptionMilliseconds = transcriptionMilliseconds
        self.directiveBrainMilliseconds = directiveBrainMilliseconds
        self.responseBrainMilliseconds = responseBrainMilliseconds
        self.actionMilliseconds = actionMilliseconds
        self.ttsPreparationMilliseconds = ttsPreparationMilliseconds
        self.ttsFirstAudioMilliseconds = ttsFirstAudioMilliseconds
        self.ttsSynthesisMilliseconds = ttsSynthesisMilliseconds
        self.ttsAudioDurationMilliseconds = ttsAudioDurationMilliseconds
        self.ttsPlaybackMilliseconds = ttsPlaybackMilliseconds
        self.ttsUtteranceCount = ttsUtteranceCount
        self.ttsAudioChunkCount = ttsAudioChunkCount
        self.capturedAudioFrameCount = capturedAudioFrameCount
        self.droppedAudioFrameCount = droppedAudioFrameCount
    }
}

public struct AssistantTurnRequest: Sendable, Equatable {
    public var turnID: BrainRequestID
    public var transcriptionID: TranscriptionID
    public var sttProviderID: ProviderID?
    public var brainSelection: BrainProviderSelection
    public var locale: String?
    public var mode: STTMode
    public var speechConfiguration: SpeechConfiguration

    public init(
        turnID: BrainRequestID,
        transcriptionID: TranscriptionID,
        sttProviderID: ProviderID?,
        brainSelection: BrainProviderSelection,
        locale: String?,
        mode: STTMode,
        speechConfiguration: SpeechConfiguration
    ) {
        self.turnID = turnID
        self.transcriptionID = transcriptionID
        self.sttProviderID = sttProviderID
        self.brainSelection = brainSelection
        self.locale = locale
        self.mode = mode
        self.speechConfiguration = speechConfiguration
    }
}

public enum AssistantDirective: Equatable, Sendable {
    case respond
    case openApplication(ApplicationCommandTarget)
    case quitApplication(ApplicationCommandTarget)
    case insertText(String)
    case readSelection
    case unsupported(String)
}

public struct ApplicationCommandTarget: Codable, Equatable, Sendable {
    public var appName: String?
    public var bundleID: String?

    public init(appName: String? = nil, bundleID: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
    }

    public var displayName: String {
        appName ?? bundleID ?? "that app"
    }
}

public struct AssistantDirectiveEnvelope: Codable, Equatable, Sendable {
    public var type: AssistantDirectiveType
    public var text: String?
    public var appName: String?
    public var bundleID: String?
    public var message: String?

    public init(
        type: AssistantDirectiveType,
        text: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        message: String? = nil
    ) {
        self.type = type
        self.text = text
        self.appName = appName
        self.bundleID = bundleID
        self.message = message
    }

    public func directive() throws -> AssistantDirective {
        switch type {
        case .respond:
            return .respond
        case .openApplication:
            let target = ApplicationCommandTarget(appName: clean(appName), bundleID: clean(bundleID))
            guard target.appName != nil || target.bundleID != nil else {
                throw RocaError.selectionUnavailable("Open app directive needs an app name or bundle ID.")
            }
            return .openApplication(target)
        case .quitApplication:
            let target = ApplicationCommandTarget(appName: clean(appName), bundleID: clean(bundleID))
            guard target.appName != nil || target.bundleID != nil else {
                throw RocaError.selectionUnavailable("Quit app directive needs an app name or bundle ID.")
            }
            return .quitApplication(target)
        case .insertText:
            guard let text = clean(text), !text.isEmpty else {
                throw RocaError.selectionUnavailable("Insert text directive needs text.")
            }
            return .insertText(text)
        case .readSelection:
            return .readSelection
        case .unsupported:
            return .unsupported(clean(message) ?? "I cannot do that yet.")
        }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

public enum AssistantDirectiveType: String, Codable, Sendable {
    case respond
    case openApplication
    case quitApplication
    case insertText
    case readSelection
    case unsupported
}
