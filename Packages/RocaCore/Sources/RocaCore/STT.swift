import Foundation

public protocol STTProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: STTCapabilities { get }

    func prepare() async throws
    func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        request: STTRequest
    ) async throws -> AsyncThrowingStream<TranscriptEvent, Error>
    func cancel(_ transcriptionID: TranscriptionID) async
}

public struct STTCapabilities: Codable, Sendable {
    public var supportsStreaming: Bool
    public var supportedLocales: [String]
    public var locality: ProviderLocality

    public init(supportsStreaming: Bool, supportedLocales: [String], locality: ProviderLocality) {
        self.supportsStreaming = supportsStreaming
        self.supportedLocales = supportedLocales
        self.locality = locality
    }
}

public struct AudioFrame: Sendable {
    public var pcm: Data
    public var sampleRate: Int
    public var channels: Int
    public var format: PCMFormat
    public var frameDurationMilliseconds: Int
    public var sequenceNumber: Int
    public var capturedAt: Date

    public init(
        pcm: Data,
        sampleRate: Int,
        channels: Int,
        format: PCMFormat,
        frameDurationMilliseconds: Int,
        sequenceNumber: Int,
        capturedAt: Date
    ) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.sequenceNumber = sequenceNumber
        self.capturedAt = capturedAt
    }
}

public struct PCMFormat: Codable, Hashable, Sendable {
    public var bitDepth: Int
    public var isFloat: Bool
    public var isInterleaved: Bool
    public var endian: PCMEndian

    public init(bitDepth: Int, isFloat: Bool, isInterleaved: Bool, endian: PCMEndian) {
        self.bitDepth = bitDepth
        self.isFloat = isFloat
        self.isInterleaved = isInterleaved
        self.endian = endian
    }
}

public enum PCMEndian: String, Codable, Sendable {
    case little
    case big
}

public struct STTRequest: Codable, Sendable {
    public var transcriptionID: TranscriptionID
    public var locale: String?
    public var mode: STTMode
    public var intent: VoiceInputIntent

    public init(transcriptionID: TranscriptionID, locale: String?, mode: STTMode, intent: VoiceInputIntent) {
        self.transcriptionID = transcriptionID
        self.locale = locale
        self.mode = mode
        self.intent = intent
    }
}

public enum STTMode: String, Codable, Sendable {
    case pushToTalk
    case toggleToTalk
}

public enum VoiceInputIntent: String, Codable, Sendable {
    case dictation
    case assistantPrompt
    case command
}

public enum TranscriptEvent: Equatable, Sendable {
    case partial(TranscriptRevision)
    case segment(TranscriptSegment)
    case final(TranscriptSegment)
    case finished
}

public struct TranscriptRevision: Codable, Equatable, Sendable {
    public var text: String
    public var revision: Int
    public var replacesRevision: Int?

    public init(text: String, revision: Int, replacesRevision: Int?) {
        self.text = text
        self.revision = revision
        self.replacesRevision = replacesRevision
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var text: String
    public var segmentIndex: Int
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var confidence: Double?

    public init(
        text: String,
        segmentIndex: Int,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        confidence: Double?
    ) {
        self.text = text
        self.segmentIndex = segmentIndex
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}
