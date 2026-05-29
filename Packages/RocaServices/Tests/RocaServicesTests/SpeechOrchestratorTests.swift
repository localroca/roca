import Foundation
import RocaCore
import RocaServices
import Testing

@Test
func speechOrchestratorUsesResolvedProviderSupportedFormat() async throws {
    let provider = RecordingTTSProvider(
        id: ProviderID(rawValue: "tts.wav16"),
        capabilities: TTSCapabilities(
            supportsStreaming: false,
            supportedFormats: [.wav16Mono],
            locality: .local
        )
    )
    let orchestrator = DefaultSpeechOrchestrator(
        resolver: StaticProviderResolver(provider: provider),
        playback: RecordingPlayback()
    )

    try await orchestrator.speak(
        SpeechRequest(
            utteranceID: .make(),
            text: "Hello",
            providerID: nil,
            voice: nil,
            format: .wav24Mono,
            speed: 1.0,
            source: .selectedText
        )
    )

    let request = try #require(await provider.lastRequest)
    #expect(request.format == .wav16Mono)
}

@Test
func speechOrchestratorExposesResolvedProviderChunkLimit() async throws {
    let provider = RecordingTTSProvider(
        id: ProviderID(rawValue: "tts.chunked"),
        capabilities: TTSCapabilities(
            supportsStreaming: false,
            supportedFormats: [.wav24Mono],
            locality: .local,
            recommendedChunkCharacterLimit: 420
        )
    )
    let orchestrator = DefaultSpeechOrchestrator(
        resolver: StaticProviderResolver(provider: provider),
        playback: RecordingPlayback()
    )

    let limit = try await orchestrator.recommendedChunkCharacterLimit(
        for: SpeechRequest(
            utteranceID: .make(),
            text: "Hello",
            providerID: nil,
            voice: nil,
            format: .wav24Mono,
            speed: 1.0,
            source: .assistantResponse
        )
    )

    #expect(limit == 420)
}

@Test
func speechOrchestratorRecordsUtteranceMetrics() async throws {
    let utteranceID = UtteranceID.make()
    let provider = RecordingTTSProvider(
        id: ProviderID(rawValue: "tts.metrics"),
        capabilities: TTSCapabilities(
            supportsStreaming: false,
            supportedFormats: [.wav24Mono],
            locality: .local
        ),
        audioData: testWAVData(sampleRate: 24_000, frames: 24_000)
    )
    let orchestrator = DefaultSpeechOrchestrator(
        resolver: StaticProviderResolver(provider: provider),
        playback: RecordingPlayback()
    )

    try await orchestrator.speak(
        SpeechRequest(
            utteranceID: utteranceID,
            text: "Hello",
            providerID: nil,
            voice: nil,
            format: .wav24Mono,
            speed: 1.0,
            source: .assistantResponse
        )
    )

    let metrics = try #require(await orchestrator.metrics(for: utteranceID))
    #expect(metrics.providerID == provider.id)
    #expect(metrics.source == .assistantResponse)
    #expect(metrics.requestedCharacterCount == 5)
    #expect(metrics.audioChunkCount == 1)
    #expect(metrics.firstAudioMilliseconds != nil)
    #expect(metrics.synthesisMilliseconds != nil)
    #expect(metrics.audioDurationMilliseconds == 1_000)
}

private actor RecordingTTSProvider: TTSProvider {
    let id: ProviderID
    let displayName: String
    let capabilities: TTSCapabilities
    let audioData: Data
    private(set) var lastRequest: TTSRequest?

    init(id: ProviderID, capabilities: TTSCapabilities, audioData: Data = Data()) {
        self.id = id
        self.displayName = id.rawValue
        self.capabilities = capabilities
        self.audioData = audioData
    }

    func prepare() async throws {}

    func listVoices() async throws -> [TTSVoice] {
        []
    }

    func synthesize(_ request: TTSRequest) async throws -> AsyncThrowingStream<TTSEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(utteranceID: request.utteranceID))
            continuation.yield(
                .audioChunk(
                    AudioChunk(
                        utteranceID: request.utteranceID,
                        data: audioData,
                        format: request.format,
                        sequenceNumber: 0
                    )
                )
            )
            continuation.yield(.finished(utteranceID: request.utteranceID))
            continuation.finish()
        }
    }

    func cancel(_ utteranceID: UtteranceID) async {}
}

private struct StaticProviderResolver: ProviderResolving {
    var provider: any TTSProvider

    func ttsProvider(_ request: TTSResolutionRequest) async throws -> any TTSProvider {
        provider
    }

    func sttProvider(_ request: STTResolutionRequest) async throws -> any STTProvider {
        throw RocaError.providerUnavailable(request.requestedProviderID ?? ProviderID(rawValue: "stt.default"))
    }

    func brainProvider(id: ProviderID?) async throws -> any BrainProvider {
        throw RocaError.providerUnavailable(id ?? ProviderID(rawValue: "brain.default"))
    }
}

private actor RecordingPlayback: SpeechPlaybackControlling {
    var state: SpeechPlaybackState = .idle

    nonisolated var stateUpdates: AsyncStream<SpeechPlaybackState> {
        AsyncStream { _ in }
    }

    nonisolated var audioLevelUpdates: AsyncStream<Double> {
        AsyncStream { _ in }
    }

    func play(_ events: AsyncThrowingStream<TTSEvent, Error>) async throws {
        state = .playing
        for try await _ in events {}
    }

    func stop() async {
        state = .stopped
    }
}

private func testWAVData(sampleRate: Int, frames: Int) -> Data {
    let channels = 1
    let bitDepth = 16
    let bytesPerFrame = channels * bitDepth / 8
    let dataByteCount = frames * bytesPerFrame

    var data = Data()
    appendASCII("RIFF", to: &data)
    appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
    appendASCII("WAVE", to: &data)
    appendASCII("fmt ", to: &data)
    appendUInt32LE(16, to: &data)
    appendUInt16LE(1, to: &data)
    appendUInt16LE(UInt16(channels), to: &data)
    appendUInt32LE(UInt32(sampleRate), to: &data)
    appendUInt32LE(UInt32(sampleRate * bytesPerFrame), to: &data)
    appendUInt16LE(UInt16(bytesPerFrame), to: &data)
    appendUInt16LE(UInt16(bitDepth), to: &data)
    appendASCII("data", to: &data)
    appendUInt32LE(UInt32(dataByteCount), to: &data)
    data.append(Data(count: dataByteCount))
    return data
}

private func appendASCII(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0x00ff))
    data.append(UInt8((value & 0xff00) >> 8))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0x000000ff))
    data.append(UInt8((value & 0x0000ff00) >> 8))
    data.append(UInt8((value & 0x00ff0000) >> 16))
    data.append(UInt8((value & 0xff000000) >> 24))
}
