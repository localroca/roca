import Foundation
import RocaCore
import RocaServices
import Testing

@Test
func dictationStopInsertsFinalTranscriptAndStopsSpeechFirst() async throws {
    let provider = RecordingSTTProvider(events: [
        .final(
            TranscriptSegment(
                text: "hello world",
                segmentIndex: 0,
                startTime: nil,
                endTime: nil,
                confidence: nil
            )
        ),
        .finished
    ])
    let audio = FakeAudioInputSession()
    let inserter = RecordingInserter()
    let stopRecorder = StopSpeechRecorder()
    let orchestrator = DefaultDictationOrchestrator(
        resolver: StaticSTTResolver(provider: provider),
        audioInput: audio,
        inserter: inserter,
        permissions: AllowingPermissions(),
        stopSpeech: {
            await stopRecorder.stop()
        }
    )

    try await orchestrator.start(dictationRequest())
    await orchestrator.stop()

    #expect(await stopRecorder.stopCount == 1)
    #expect(await audio.startCount == 1)
    #expect(await audio.stopCount == 1)
    #expect(await inserter.insertedText == "hello world")
    #expect(await orchestrator.recoverableTranscript() == nil)
}

@Test
func dictationInsertionFailureKeepsRecoverableTranscript() async throws {
    let provider = RecordingSTTProvider(events: [
        .final(
            TranscriptSegment(
                text: "recover me",
                segmentIndex: 0,
                startTime: nil,
                endTime: nil,
                confidence: nil
            )
        ),
        .finished
    ])
    let inserter = RecordingInserter(error: RocaError.permission(.accessibility))
    let orchestrator = DefaultDictationOrchestrator(
        resolver: StaticSTTResolver(provider: provider),
        audioInput: FakeAudioInputSession(),
        inserter: inserter,
        permissions: AllowingPermissions(),
        stopSpeech: {}
    )

    try await orchestrator.start(dictationRequest())
    await orchestrator.stop()

    let recovery = try #require(await orchestrator.recoverableTranscript())
    #expect(recovery.text == "recover me")
}

@Test
func dictationRecoveryTranscriptExpires() async throws {
    let provider = RecordingSTTProvider(events: [
        .final(
            TranscriptSegment(
                text: "temporary recovery",
                segmentIndex: 0,
                startTime: nil,
                endTime: nil,
                confidence: nil
            )
        ),
        .finished
    ])
    let orchestrator = DefaultDictationOrchestrator(
        resolver: StaticSTTResolver(provider: provider),
        audioInput: FakeAudioInputSession(),
        inserter: RecordingInserter(error: RocaError.permission(.accessibility)),
        permissions: AllowingPermissions(),
        stopSpeech: {},
        recoveryExpirationSeconds: 0.05
    )

    try await orchestrator.start(dictationRequest())
    await orchestrator.stop()
    #expect(await orchestrator.recoverableTranscript() != nil)

    try await Task.sleep(nanoseconds: 120_000_000)
    #expect(await orchestrator.recoverableTranscript() == nil)
}

@Test
func dictationCancelStopsAudioAndCancelsProvider() async throws {
    let transcriptionID = TranscriptionID(rawValue: "dictation-test")
    let provider = RecordingSTTProvider(events: [.finished])
    let audio = FakeAudioInputSession()
    let orchestrator = DefaultDictationOrchestrator(
        resolver: StaticSTTResolver(provider: provider),
        audioInput: audio,
        inserter: RecordingInserter(),
        permissions: AllowingPermissions(),
        stopSpeech: {}
    )

    try await orchestrator.start(dictationRequest(transcriptionID: transcriptionID))
    await orchestrator.cancel()

    #expect(await audio.stopCount == 1)
    #expect(await provider.cancelledIDs == [transcriptionID])
}

@Test
func dictationStartFailureAfterAudioStartStopsAudioAndCancelsProvider() async throws {
    let transcriptionID = TranscriptionID(rawValue: "dictation-start-failure")
    let provider = RecordingSTTProvider(
        events: [],
        transcribeError: RocaError.selectionUnavailable("STT stream failed.")
    )
    let audio = FakeAudioInputSession()
    let orchestrator = DefaultDictationOrchestrator(
        resolver: StaticSTTResolver(provider: provider),
        audioInput: audio,
        inserter: RecordingInserter(),
        permissions: AllowingPermissions(),
        stopSpeech: {}
    )

    await #expect(throws: RocaError.selectionUnavailable("STT stream failed.")) {
        try await orchestrator.start(dictationRequest(transcriptionID: transcriptionID))
    }

    #expect(await audio.startCount == 1)
    #expect(await audio.stopCount == 1)
    #expect(await provider.cancelledIDs == [transcriptionID])
}

private func dictationRequest(transcriptionID: TranscriptionID = "dictation-test") -> DictationRequest {
    DictationRequest(
        transcriptionID: transcriptionID,
        providerID: nil,
        locale: "en-US",
        mode: .toggleToTalk,
        intent: .dictation,
        insertionTarget: .focusedApp
    )
}

private actor RecordingSTTProvider: STTProvider {
    let id = ProviderID(rawValue: "stt")
    let displayName = "STT"
    let capabilities = STTCapabilities(supportsStreaming: true, supportedLocales: ["en-US"], locality: .local)
    private let events: [TranscriptEvent]
    private let transcribeError: Error?
    private(set) var cancelledIDs: [TranscriptionID] = []

    init(events: [TranscriptEvent], transcribeError: Error? = nil) {
        self.events = events
        self.transcribeError = transcribeError
    }

    func prepare() async throws {}

    func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        request: STTRequest
    ) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        if let transcribeError {
            throw transcribeError
        }
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func cancel(_ transcriptionID: TranscriptionID) async {
        cancelledIDs.append(transcriptionID)
    }
}

private actor FakeAudioInputSession: AudioInputSession {
    var state: AudioInputState = .idle
    var metrics = AudioInputMetrics()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?

    func start(_ request: AudioInputRequest) async throws -> AsyncThrowingStream<AudioFrame, Error> {
        startCount += 1
        state = .recording
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        stopCount += 1
        state = .stopped
        continuation?.finish()
        continuation = nil
    }
}

private actor RecordingInserter: FocusedTextInserting {
    private(set) var insertedText: String?
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func insertIntoFocusedApp(_ text: String) async throws {
        if let error {
            throw error
        }
        insertedText = text
    }
}

private actor StopSpeechRecorder {
    private(set) var stopCount = 0

    func stop() {
        stopCount += 1
    }
}

private struct AllowingPermissions: PermissionsServicing {
    func isAccessibilityTrusted() async -> Bool {
        true
    }

    func requestAccessibilityIfNeeded() async -> Bool {
        true
    }

    func microphonePermissionStatus() async -> MicrophonePermissionStatus {
        .allowed
    }

    func requestMicrophoneIfNeeded() async -> Bool {
        true
    }

    func speechRecognitionPermissionStatus() async -> SpeechRecognitionPermissionStatus {
        .allowed
    }

    func requestSpeechRecognitionIfNeeded() async -> Bool {
        true
    }
}

private struct StaticSTTResolver: ProviderResolving {
    var provider: any STTProvider

    func ttsProvider(_ request: TTSResolutionRequest) async throws -> any TTSProvider {
        throw RocaError.providerUnavailable(request.requestedProviderID ?? ProviderID(rawValue: "tts.default"))
    }

    func sttProvider(_ request: STTResolutionRequest) async throws -> any STTProvider {
        provider
    }

    func brainProvider(id: ProviderID?) async throws -> any BrainProvider {
        throw RocaError.providerUnavailable(id ?? ProviderID(rawValue: "brain.default"))
    }
}
