import Foundation

public protocol TTSProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: TTSCapabilities { get }

    func prepare() async throws
    func listVoices() async throws -> [TTSVoice]
    func synthesize(_ request: TTSRequest) async throws -> AsyncThrowingStream<TTSEvent, Error>
    func cancel(_ utteranceID: UtteranceID) async
}

public struct TTSCapabilities: Codable, Sendable {
    public var supportsStreaming: Bool
    public var supportedFormats: [AudioDescriptor]
    public var locality: ProviderLocality
    public var recommendedChunkCharacterLimit: Int?

    public init(
        supportsStreaming: Bool,
        supportedFormats: [AudioDescriptor],
        locality: ProviderLocality,
        recommendedChunkCharacterLimit: Int? = nil
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportedFormats = supportedFormats
        self.locality = locality
        self.recommendedChunkCharacterLimit = recommendedChunkCharacterLimit
    }
}

public struct TTSVoice: Codable, Hashable, Sendable {
    public var id: VoiceID
    public var displayName: String
    public var locale: String?
    public var traits: [String]

    public init(id: VoiceID, displayName: String, locale: String?, traits: [String]) {
        self.id = id
        self.displayName = displayName
        self.locale = locale
        self.traits = traits
    }
}

public struct TTSRequest: Codable, Sendable {
    public var utteranceID: UtteranceID
    public var text: String
    public var voice: VoiceID?
    public var format: AudioDescriptor
    public var speed: Double

    public init(utteranceID: UtteranceID, text: String, voice: VoiceID?, format: AudioDescriptor, speed: Double) {
        self.utteranceID = utteranceID
        self.text = text
        self.voice = voice
        self.format = format
        self.speed = speed
    }
}

public enum TTSEvent: Sendable {
    case started(utteranceID: UtteranceID)
    case audioChunk(AudioChunk)
    case finished(utteranceID: UtteranceID)
    case cancelled(utteranceID: UtteranceID)
}

public struct AudioChunk: Sendable {
    public var utteranceID: UtteranceID
    public var data: Data
    public var format: AudioDescriptor
    public var sequenceNumber: Int

    public init(utteranceID: UtteranceID, data: Data, format: AudioDescriptor, sequenceNumber: Int) {
        self.utteranceID = utteranceID
        self.data = data
        self.format = format
        self.sequenceNumber = sequenceNumber
    }
}

public struct AudioDescriptor: Codable, Hashable, Sendable {
    public var encoding: AudioEncoding
    public var mimeType: String
    public var sampleRate: Int?
    public var channels: Int?
    public var bitDepth: Int?

    public init(encoding: AudioEncoding, mimeType: String, sampleRate: Int?, channels: Int?, bitDepth: Int?) {
        self.encoding = encoding
        self.mimeType = mimeType
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
    }

    public static let mp3 = AudioDescriptor(
        encoding: .mp3,
        mimeType: "audio/mpeg",
        sampleRate: nil,
        channels: nil,
        bitDepth: nil
    )

    public static let wav16Mono = AudioDescriptor(
        encoding: .wav,
        mimeType: "audio/wav",
        sampleRate: 22_050,
        channels: 1,
        bitDepth: 16
    )

    public static let wav24Mono = AudioDescriptor(
        encoding: .wav,
        mimeType: "audio/wav",
        sampleRate: 24_000,
        channels: 1,
        bitDepth: 16
    )
}

public enum AudioEncoding: String, Codable, Sendable {
    case mp3
    case wav
    case pcm
    case opus
    case flac
}
