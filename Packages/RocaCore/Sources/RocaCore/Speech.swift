import Foundation

public protocol SpeechOrchestrating: Sendable {
    var state: SpeechPlaybackState { get async }
    var activeSession: ActiveSpeechSession? { get async }

    func speak(_ request: SpeechRequest) async throws
    func recommendedChunkCharacterLimit(for request: SpeechRequest) async throws -> Int?
    func metrics(for utteranceID: UtteranceID) async -> SpeechUtteranceMetrics?
    func waitForCompletion(of utteranceID: UtteranceID) async throws
    func stopSpeaking() async
}

public struct SpeechRequest: Codable, Sendable {
    public var utteranceID: UtteranceID
    public var text: String
    public var providerID: ProviderID?
    public var voice: VoiceID?
    public var providerVoiceSelections: [ProviderID: VoiceID]
    public var format: AudioDescriptor
    public var speed: Double
    public var source: SpeechSource
    public var allowFallback: Bool

    public init(
        utteranceID: UtteranceID,
        text: String,
        providerID: ProviderID?,
        voice: VoiceID?,
        providerVoiceSelections: [ProviderID: VoiceID] = [:],
        format: AudioDescriptor,
        speed: Double,
        source: SpeechSource,
        allowFallback: Bool = true
    ) {
        self.utteranceID = utteranceID
        self.text = text
        self.providerID = providerID
        self.voice = voice
        self.providerVoiceSelections = providerVoiceSelections
        self.format = format
        self.speed = speed
        self.source = source
        self.allowFallback = allowFallback
    }
}

public enum SpeechSource: String, Codable, Sendable {
    case selectedText
    case assistantResponse
    case voicePreview
}

public struct ActiveSpeechSession: Sendable, Equatable {
    public var utteranceID: UtteranceID
    public var providerID: ProviderID
    public var source: SpeechSource
    public var normalizedTextFingerprint: String?
    public var startedAt: Date

    public init(
        utteranceID: UtteranceID,
        providerID: ProviderID,
        source: SpeechSource,
        normalizedTextFingerprint: String?,
        startedAt: Date
    ) {
        self.utteranceID = utteranceID
        self.providerID = providerID
        self.source = source
        self.normalizedTextFingerprint = normalizedTextFingerprint
        self.startedAt = startedAt
    }
}

public protocol SpeechPlaybackControlling: Sendable {
    var state: SpeechPlaybackState { get async }
    var stateUpdates: AsyncStream<SpeechPlaybackState> { get }
    var audioLevelUpdates: AsyncStream<Double> { get }

    func play(_ events: AsyncThrowingStream<TTSEvent, Error>) async throws
    func stop() async
}

public struct SpeechUtteranceMetrics: Codable, Equatable, Sendable {
    public var utteranceID: UtteranceID
    public var providerID: ProviderID
    public var source: SpeechSource
    public var requestedCharacterCount: Int
    public var audioChunkCount: Int
    public var firstAudioMilliseconds: Int?
    public var synthesisMilliseconds: Int?
    public var audioDurationMilliseconds: Int?

    public init(
        utteranceID: UtteranceID,
        providerID: ProviderID,
        source: SpeechSource,
        requestedCharacterCount: Int,
        audioChunkCount: Int,
        firstAudioMilliseconds: Int?,
        synthesisMilliseconds: Int?,
        audioDurationMilliseconds: Int?
    ) {
        self.utteranceID = utteranceID
        self.providerID = providerID
        self.source = source
        self.requestedCharacterCount = requestedCharacterCount
        self.audioChunkCount = audioChunkCount
        self.firstAudioMilliseconds = firstAudioMilliseconds
        self.synthesisMilliseconds = synthesisMilliseconds
        self.audioDurationMilliseconds = audioDurationMilliseconds
    }
}

public enum SpeechPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case stopped
    case failed(String)
}

public struct TextFingerprinting: Sendable {
    private let salt: Int

    public init(salt: Int = Int.random(in: Int.min ... Int.max)) {
        self.salt = salt
    }

    public func fingerprint(_ text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()

        var hasher = Hasher()
        hasher.combine(salt)
        hasher.combine(normalized)
        return String(hasher.finalize(), radix: 16)
    }
}
