import Foundation
import RocaCore
import RocaServices
import Testing

@Test
func assistantSessionTypedTurnAddsChatMessagesWithoutSpeech() async throws {
    let brain = ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Sure thing.")
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("hello", request: sessionRequest(outputMode: .textOnly))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .user && $0.source == .typed && $0.text == "hello" })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Sure thing." && $0.status == .completed })
    #expect(await speech.speakCount == 0)
}

@Test
func assistantSessionStructuredResponseSplitsBubbleAndDetails() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"respond"}"#,
        responseText: ###"{"bubbleText":"Short version.","detailsMarkdown":"## Details\n- One\n- Two"}"###
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("give me details", request: sessionRequest(outputMode: .textOnly))

    let assistantMessage = try #require(await orchestrator.messageSnapshot.first { $0.role == .assistant })
    #expect(assistantMessage.text == "Short version.")
    #expect(assistantMessage.detailsMarkdown == "## Details\n- One\n- Two")
}

@Test
func assistantSessionSpeaksOnlyStructuredBubble() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"respond"}"#,
        responseText: ###"{"bubbleText":"Yep, I can help with that.","detailsMarkdown":"# Long Details\nThis part should stay visual."}"###
    )
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("explain it", request: sessionRequest(outputMode: .speakAll))

    #expect(await speech.spokenTexts == ["Yep, I can help with that."])
}

@Test
func assistantSessionMessagesIncludeBrainMetadata() async throws {
    let brain = ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Hey.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("hello", request: sessionRequest(outputMode: .textOnly))

    let messages = await orchestrator.messageSnapshot
    let user = try #require(messages.first { $0.role == .user })
    let assistant = try #require(messages.first { $0.role == .assistant })
    #expect(user.metadata?.inputMode == .typed)
    #expect(user.metadata?.outputMode == .textOnly)
    #expect(user.metadata?.brainProviderID == ProviderID(rawValue: "test-brain"))
    #expect(user.metadata?.brainModelID == "test-model")
    #expect(user.metadata?.brainDisplayName == "Test Model")
    #expect(user.metadata?.directivePromptVersion == "assistant-router-2026-05-26-v1")
    #expect(user.metadata?.responsePromptVersion == "companion-response-2026-05-26-v2")
    #expect(assistant.metadata?.directiveType == .respond)
    #expect(assistant.metadata?.brainModelID == "test-model")
}

@Test
func assistantSessionTextOnlySuppressesForcedVoiceActionSpeech() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"insertText","text":"hello"}"#,
        responseText: ""
    )
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "type hello",
        request: sessionRequest(inputMode: .voice, outputMode: .textOnly)
    )

    #expect(await speech.speakCount == 0)
}

@Test
func assistantSessionTextOnlyTurnReturnsCompanionToIdle() async throws {
    let brain = ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Sure thing.")
    let companionState = CompanionStateCenter()
    let eventsTask = Task {
        var activities: [RocaActivity] = []
        for await event in companionState.events {
            activities.append(event.activity)
            if activities.contains(.idle) {
                return activities
            }
        }
        return activities
    }
    try await Task.sleep(for: .milliseconds(20))

    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        companionState: companionState,
        stopSpeech: {}
    )

    await orchestrator.submitText("hello", request: sessionRequest(outputMode: .textOnly))

    let activities = try await value(from: eventsTask)
    #expect(activities.contains(.thinking))
    #expect(activities.contains(.idle))
}

@Test
func assistantSessionClearConversationRemovesPriorMessages() async throws {
    let brain = ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Done.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("hello", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.clearConversation()

    let messages = await orchestrator.messageSnapshot
    #expect(messages.count == 1)
    #expect(messages.first?.role == .status)
    #expect(messages.first?.text == "Conversation cleared.")
}

@Test
func assistantSessionVoiceTurnRespondsAndSpeaksFinalAnswer() async throws {
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            stt: RecordingSessionSTTProvider(text: "hello roca"),
            brain: ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Hello there.")
        ),
        audioInput: FakeSessionAudioInput(),
        inserter: NoopSessionInserter(),
        permissions: AllowingSessionPermissions(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    try await orchestrator.startVoice(sessionRequest(inputMode: .voice, outputMode: .speakAll))
    await orchestrator.stopVoice()

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .user && $0.source == .voice && $0.text == "hello roca" })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Hello there." && $0.status == .completed })
    #expect(await speech.spokenTexts == ["Hello there."])
}

@Test
func assistantSessionEmitsRedactedTurnMetrics() async throws {
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            stt: RecordingSessionSTTProvider(text: "hello"),
            brain: ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Hello there.")
        ),
        audioInput: FakeSessionAudioInput(metrics: AudioInputMetrics(capturedFrameCount: 3, droppedFrameCount: 1)),
        inserter: NoopSessionInserter(),
        permissions: AllowingSessionPermissions(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )
    let metricsTask = Task {
        var iterator = orchestrator.turnMetricsUpdates.makeAsyncIterator()
        return await iterator.next()
    }
    await Task.yield()

    try await orchestrator.startVoice(sessionRequest(inputMode: .voice, outputMode: .speakAll))
    await orchestrator.stopVoice()

    let metrics = await metricsTask.value
    #expect(metrics?.outcome == .completed)
    #expect(metrics?.directiveType == .respond)
    #expect(metrics?.capturedAudioFrameCount == 3)
    #expect(metrics?.droppedAudioFrameCount == 1)
    #expect(metrics?.transcriptionMilliseconds != nil)
    #expect(metrics?.directiveBrainMilliseconds != nil)
    #expect(metrics?.responseBrainMilliseconds != nil)
    #expect(metrics?.ttsPreparationMilliseconds != nil)
    #expect(metrics?.ttsFirstAudioMilliseconds == 5)
    #expect(metrics?.ttsSynthesisMilliseconds == 10)
    #expect(metrics?.ttsAudioDurationMilliseconds == 250)
    #expect(metrics?.ttsPlaybackMilliseconds != nil)
    #expect(metrics?.ttsUtteranceCount == 1)
    #expect(metrics?.ttsAudioChunkCount == 1)
}

@Test
func assistantSessionChunksLongSpokenResponses() async throws {
    let longResponse = Array(
        repeating: "This is a deliberately long assistant sentence that should be spoken in smaller pieces.",
        count: 14
    ).joined(separator: " ")
    let speech = RecordingSessionSpeech(chunkCharacterLimit: 420)
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"respond"}"#,
                responseText: #"{"bubbleText":"\#(longResponse)","detailsMarkdown":null}"#
            )
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("tell me about something", request: sessionRequest(outputMode: .speakAll))

    let spokenTexts = await speech.spokenTexts
    #expect(spokenTexts.count > 1)
    #expect(spokenTexts.allSatisfy { $0.count <= 420 })
    #expect(spokenTexts.joined(separator: " ") == longResponse)
}

@Test
func assistantSessionOpenAppExecutesLocalCommand() async throws {
    let commands = RecordingSessionAppCommands(result: .opened(ApplicationMatch(
        displayName: "Safari",
        bundleID: "com.apple.Safari",
        url: URL(fileURLWithPath: "/Applications/Safari.app")
    )))
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"openApplication","appName":"Safari"}"#,
                responseText: ""
            )
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        applicationCommands: commands,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("open safari", request: sessionRequest(inputMode: .voice, outputMode: .speakAll))

    #expect(await commands.commands == [.open(ApplicationCommandTarget(appName: "Safari"))])
    #expect(await speech.spokenTexts == ["Opened Safari."])
}

@Test
func assistantSessionSpeaksRecoveryWhenBrainIsUnavailableAfterTranscription() async throws {
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            stt: RecordingSessionSTTProvider(text: "hello"),
            brain: FailingSessionBrainProvider(error: RocaError.providerUnavailable(ProviderID(rawValue: "ollama")))
        ),
        audioInput: FakeSessionAudioInput(),
        inserter: NoopSessionInserter(),
        permissions: AllowingSessionPermissions(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    try await orchestrator.startVoice(sessionRequest(inputMode: .voice, outputMode: .speakAll))
    await orchestrator.stopVoice()

    #expect(await speech.spokenTexts == [
        "I can't reach your assistant brain right now. Start Ollama or choose a different model in Settings."
    ])
}

@Test
func assistantSessionCancelStopsAudioAndCancelsSTT() async throws {
    let stt = RecordingSessionSTTProvider(text: "still listening")
    let audio = FakeSessionAudioInput()
    let speech = RecordingSessionSpeech()
    let request = sessionRequest(inputMode: .voice, outputMode: .speakAll)
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(stt: stt, brain: ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "")),
        audioInput: audio,
        inserter: NoopSessionInserter(),
        permissions: AllowingSessionPermissions(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    try await orchestrator.startVoice(request)
    await orchestrator.cancel()

    #expect(await audio.state == .stopped)
    #expect(await stt.cancelled == [request.transcriptionID])
    #expect(await speech.state == .stopped)
}

private enum TestTimeoutError: Error {
    case timedOut
}

private func value<T: Sendable>(from task: Task<T, Never>, timeout: Duration = .seconds(1)) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestTimeoutError.timedOut
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func sessionRequest(
    inputMode: AssistantInputMode = .typed,
    outputMode: AssistantOutputMode
) -> AssistantSessionTurnRequest {
    AssistantSessionTurnRequest(
        turnID: BrainRequestID(rawValue: UUID().uuidString),
        transcriptionID: TranscriptionID(rawValue: UUID().uuidString),
        inputMode: inputMode,
        outputMode: outputMode,
        sttProviderID: nil,
        brainSelection: BrainProviderSelection(
            providerID: ProviderID(rawValue: "test-brain"),
            modelID: "test-model",
            displayName: "Test Model"
        ),
        locale: "en-US",
        mode: .toggleToTalk,
        speechConfiguration: SpeechConfiguration(providerID: nil, providerVoiceSelections: [:], speed: 1.0, allowFallback: true)
    )
}

private struct SessionResolver: ProviderResolving {
    var stt: (any STTProvider)?
    var brain: any BrainProvider

    func ttsProvider(_ request: TTSResolutionRequest) async throws -> any TTSProvider {
        throw RocaError.providerUnavailable(ProviderID(rawValue: "tts"))
    }

    func sttProvider(_ request: STTResolutionRequest) async throws -> any STTProvider {
        guard let stt else {
            throw RocaError.providerUnavailable(ProviderID(rawValue: "stt"))
        }
        return stt
    }

    func brainProvider(id: ProviderID?) async throws -> any BrainProvider {
        brain
    }
}

private actor ScriptedSessionBrainProvider: BrainProvider {
    let id = ProviderID(rawValue: "test-brain")
    let displayName = "Test Brain"
    let capabilities = BrainCapabilities(
        supportsStreaming: false,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )

    private let directiveJSON: String
    private let responseText: String

    init(directiveJSON: String, responseText: String) {
        self.directiveJSON = directiveJSON
        self.responseText = responseText
    }

    func prepare() async throws {}

    func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        let text = request.role == .companionRouter ? directiveJSON : responseText
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .final(BrainResponse(text: text, usedProvider: id, metadata: [:]))
            )
            continuation.finish()
        }
    }

    func cancel(_ requestID: BrainRequestID) async {}
}

private actor FailingSessionBrainProvider: BrainProvider {
    let id = ProviderID(rawValue: "test-brain")
    let displayName = "Test Brain"
    let capabilities = BrainCapabilities(
        supportsStreaming: false,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func prepare() async throws {}

    func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        throw error
    }

    func cancel(_ requestID: BrainRequestID) async {}
}

private actor RecordingSessionSTTProvider: STTProvider {
    let id = ProviderID(rawValue: "stt")
    let displayName = "STT"
    let capabilities = STTCapabilities(supportsStreaming: true, supportedLocales: ["en-US"], locality: .local)
    private(set) var cancelled: [TranscriptionID] = []
    private let text: String

    init(text: String) {
        self.text = text
    }

    func prepare() async throws {}

    func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        request: STTRequest
    ) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.final(TranscriptSegment(text: text, segmentIndex: 0, startTime: nil, endTime: nil, confidence: nil)))
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    func cancel(_ transcriptionID: TranscriptionID) async {
        cancelled.append(transcriptionID)
    }
}

private struct AllowingSessionPermissions: PermissionsServicing {
    func isAccessibilityTrusted() async -> Bool { true }
    func requestAccessibilityIfNeeded() async -> Bool { true }
    func microphonePermissionStatus() async -> MicrophonePermissionStatus { .allowed }
    func requestMicrophoneIfNeeded() async -> Bool { true }
    func speechRecognitionPermissionStatus() async -> SpeechRecognitionPermissionStatus { .allowed }
    func requestSpeechRecognitionIfNeeded() async -> Bool { true }
}

private actor RecordingSessionSpeech: SpeechOrchestrating {
    var state: SpeechPlaybackState = .idle
    var activeSession: ActiveSpeechSession?
    private(set) var speakCount = 0
    private(set) var spokenTexts: [String] = []
    private var utteranceMetrics: [UtteranceID: SpeechUtteranceMetrics] = [:]
    private let chunkCharacterLimit: Int?

    init(chunkCharacterLimit: Int? = nil) {
        self.chunkCharacterLimit = chunkCharacterLimit
    }

    func speak(_ request: SpeechRequest) async throws {
        speakCount += 1
        spokenTexts.append(request.text)
        utteranceMetrics[request.utteranceID] = SpeechUtteranceMetrics(
            utteranceID: request.utteranceID,
            providerID: request.providerID ?? ProviderID(rawValue: "tts.fake"),
            source: request.source,
            requestedCharacterCount: request.text.count,
            audioChunkCount: 1,
            firstAudioMilliseconds: 5,
            synthesisMilliseconds: 10,
            audioDurationMilliseconds: 250
        )
        state = .playing
    }

    func recommendedChunkCharacterLimit(for request: SpeechRequest) async throws -> Int? {
        chunkCharacterLimit
    }

    func metrics(for utteranceID: UtteranceID) async -> SpeechUtteranceMetrics? {
        utteranceMetrics[utteranceID]
    }

    func waitForCompletion(of utteranceID: UtteranceID) async throws {
        state = .idle
    }

    func stopSpeaking() async {
        state = .stopped
    }
}

private actor NoopSessionAudioInput: AudioInputSession {
    var state: AudioInputState {
        .idle
    }

    var metrics: AudioInputMetrics {
        AudioInputMetrics()
    }

    func start(_ request: AudioInputRequest) async throws -> AsyncThrowingStream<AudioFrame, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func stop() async {}
}

private actor FakeSessionAudioInput: AudioInputSession {
    var state: AudioInputState = .idle
    var metrics: AudioInputMetrics

    init(metrics: AudioInputMetrics = AudioInputMetrics()) {
        self.metrics = metrics
    }

    func start(_ request: AudioInputRequest) async throws -> AsyncThrowingStream<AudioFrame, Error> {
        state = .recording
        return AsyncThrowingStream { _ in }
    }

    func stop() async {
        state = .stopped
    }
}

private struct NoopSessionInserter: FocusedTextInserting {
    func insertIntoFocusedApp(_ text: String) async throws {}
}

private actor RecordingSessionAppCommands: ApplicationCommandExecuting {
    private(set) var commands: [ApplicationCommand] = []
    private let result: ApplicationCommandExecutionResult

    init(result: ApplicationCommandExecutionResult = .opened(ApplicationMatch(
        displayName: "App",
        bundleID: "app",
        url: URL(fileURLWithPath: "/Applications/App.app")
    ))) {
        self.result = result
    }

    func execute(_ command: ApplicationCommand) async -> ApplicationCommandExecutionResult {
        commands.append(command)
        return result
    }
}

private struct StaticSessionContextProvider: AssistantContextProviding {
    func currentContext() async -> AssistantLocalContext {
        AssistantLocalContext(activeAppName: "TextEdit", activeAppBundleID: "com.apple.TextEdit", hasFocusedTextInput: true)
    }
}
