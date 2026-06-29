import Foundation
import RocaCore
import RocaServices

public struct SessionResolver: ProviderResolving {
    public var tts: (any TTSProvider)?
    public var stt: (any STTProvider)?
    public var brain: any BrainProvider
    public var agent: (any AgentProvider)?

    public init(
        tts: (any TTSProvider)? = nil,
        stt: (any STTProvider)? = nil,
        brain: any BrainProvider,
        agent: (any AgentProvider)? = nil
    ) {
        self.tts = tts
        self.stt = stt
        self.brain = brain
        self.agent = agent
    }

    public func ttsProvider(_ request: TTSResolutionRequest) async throws -> any TTSProvider {
        guard let tts else {
            throw RocaError.providerUnavailable(ProviderID(rawValue: "tts"))
        }
        return tts
    }

    public func sttProvider(_ request: STTResolutionRequest) async throws -> any STTProvider {
        guard let stt else {
            throw RocaError.providerUnavailable(ProviderID(rawValue: "stt"))
        }
        return stt
    }

    public func brainProvider(id: ProviderID?) async throws -> any BrainProvider {
        brain
    }

    public func agentProvider(id: ProviderID?) async throws -> any AgentProvider {
        guard let agent, agent.id == id else {
            throw RocaError.providerUnavailable(id ?? ProviderID(rawValue: "agent"))
        }
        try await agent.prepare()
        return agent
    }
}

public actor ScriptedSessionBrainProvider: BrainProvider {
    public let id = ProviderID(rawValue: "test-brain")
    public let displayName = "Test Brain"
    public let capabilities = BrainCapabilities(
        supportsStreaming: false,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )

    private let directiveJSON: String
    private let responseText: String
    public private(set) var recordedRequests: [BrainRequest] = []

    public init(directiveJSON: String, responseText: String) {
        self.directiveJSON = directiveJSON
        self.responseText = responseText
    }

    public func prepare() async throws {}

    public func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        recordedRequests.append(request)
        let text = request.role == .companionRouter ? directiveJSON : responseText
        return AsyncThrowingStream { continuation in
            continuation.yield(.final(BrainResponse(text: text, usedProvider: id, metadata: [:])))
            continuation.finish()
        }
    }

    public func cancel(_ requestID: BrainRequestID) async {}
}

public actor SequencedSessionBrainProvider: BrainProvider {
    public let id = ProviderID(rawValue: "test-brain")
    public let displayName = "Test Brain"
    public let capabilities = BrainCapabilities(
        supportsStreaming: false,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )

    private var directiveTexts: [String]
    private var responseTexts: [String]
    public private(set) var recordedRequests: [BrainRequest] = []

    public init(directiveTexts: [String], responseTexts: [String]) {
        self.directiveTexts = directiveTexts
        self.responseTexts = responseTexts
    }

    public func prepare() async throws {}

    public func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        recordedRequests.append(request)
        let text: String
        if request.role == .companionRouter {
            text = directiveTexts.isEmpty ? #"{"type":"respond"}"# : directiveTexts.removeFirst()
        } else {
            text = responseTexts.isEmpty ? #"{"bubbleText":"Done.","detailsMarkdown":null}"# : responseTexts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.final(BrainResponse(text: text, usedProvider: id, metadata: [:])))
            continuation.finish()
        }
    }

    public func cancel(_ requestID: BrainRequestID) async {}
}

public actor FailingSessionBrainProvider: BrainProvider {
    public let id = ProviderID(rawValue: "test-brain")
    public let displayName = "Test Brain"
    public let capabilities = BrainCapabilities(
        supportsStreaming: false,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )

    private let error: Error

    public init(error: Error) {
        self.error = error
    }

    public func prepare() async throws {}

    public func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        throw error
    }

    public func cancel(_ requestID: BrainRequestID) async {}
}

public actor RecordingSessionAgentProvider: AgentProvider, AgentProjectDiscovering {
    public let id: ProviderID
    public let displayName: String
    public let capabilities = AgentCapabilities(
        supportsStreaming: true,
        supportsToolApprovals: true,
        supportsLocalExecution: true,
        locality: .remote,
        supportedModes: AgentMode.allCases
    )

    public private(set) var recordedRequests: [AgentRunRequest] = []
    public private(set) var discoveryQueries: [ProjectDiscoveryQuery] = []
    private let responseText: String
    private let discoveryCandidates: [ProjectDiscoveryCandidate]
    private let discoveryError: Error?

    public init(
        id: ProviderID = ProviderID(rawValue: "codex-agent"),
        displayName: String = "Codex",
        responseText: String,
        discoveryCandidates: [ProjectDiscoveryCandidate] = [],
        discoveryError: Error? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.responseText = responseText
        self.discoveryCandidates = discoveryCandidates
        self.discoveryError = discoveryError
    }

    public func prepare() async throws {}

    public func discoverProjects(matching query: ProjectDiscoveryQuery) async throws -> [ProjectDiscoveryCandidate] {
        discoveryQueries.append(query)
        if let discoveryError {
            throw discoveryError
        }
        return discoveryCandidates
    }

    public func start(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        recordedRequests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(runID: request.runID, providerID: id))
            continuation.yield(.final(AgentResponse(text: responseText, usedProvider: id)))
            continuation.finish()
        }
    }

    public func cancel(_ runID: AgentRunID) async {}
}

public actor RecordingLocalSkillWorker: LocalSkillWorking {
    public let skillID: SkillID
    public let displayName: String
    public private(set) var recordedRequests: [LocalSkillRunRequest] = []

    private let evidenceMarkdown: String
    private let metadata: [String: String]

    public init(
        skillID: SkillID = SkillID(rawValue: "codebase"),
        displayName: String = "Codebase Skill",
        evidenceMarkdown: String,
        metadata: [String: String] = ["toolCount": "3"]
    ) {
        self.skillID = skillID
        self.displayName = displayName
        self.evidenceMarkdown = evidenceMarkdown
        self.metadata = metadata
    }

    public func run(_ request: LocalSkillRunRequest) async throws -> LocalSkillRunResult {
        recordedRequests.append(request)
        return LocalSkillRunResult(
            runID: request.runID,
            skillID: skillID,
            evidenceMarkdown: evidenceMarkdown,
            metadata: metadata
        )
    }
}

public actor NoisySessionAgentProvider: AgentProvider, AgentProjectDiscovering {
    public let id: ProviderID
    public let displayName: String
    public let capabilities = AgentCapabilities(
        supportsStreaming: true,
        supportsToolApprovals: true,
        supportsLocalExecution: true,
        locality: .remote,
        supportedModes: AgentMode.allCases
    )

    public private(set) var recordedRequests: [AgentRunRequest] = []
    private let responseText: String
    private let discoveryCandidates: [ProjectDiscoveryCandidate]

    public init(
        id: ProviderID = ProviderID(rawValue: "codex-agent"),
        displayName: String = "Codex",
        responseText: String,
        discoveryCandidates: [ProjectDiscoveryCandidate] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.responseText = responseText
        self.discoveryCandidates = discoveryCandidates
    }

    public func prepare() async throws {}

    public func discoverProjects(matching query: ProjectDiscoveryQuery) async throws -> [ProjectDiscoveryCandidate] {
        discoveryCandidates
    }

    public func start(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        recordedRequests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(runID: request.runID, providerID: id))
            continuation.yield(.toolActivity(AgentToolActivity(kind: .command, title: "ls", status: "listing project files")))
            continuation.yield(.textDelta("I'll run ls and grep to inspect the project.\n"))
            continuation.yield(.toolActivity(AgentToolActivity(kind: .command, title: "grep", status: "searching passkey routes")))
            continuation.yield(.textDelta("grep found passkey routes.\n"))
            continuation.yield(.final(AgentResponse(text: responseText, usedProvider: id)))
            continuation.finish()
        }
    }

    public func cancel(_ runID: AgentRunID) async {}
}

public actor HangingSessionAgentProvider: AgentProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities = AgentCapabilities(
        supportsStreaming: true,
        supportsToolApprovals: true,
        supportsLocalExecution: true,
        locality: .remote,
        supportedModes: AgentMode.allCases
    )

    public private(set) var recordedRequests: [AgentRunRequest] = []
    public private(set) var cancelledRunIDs: [AgentRunID] = []
    private var continuations: [AgentRunID: AsyncThrowingStream<AgentEvent, Error>.Continuation] = [:]

    public init(id: ProviderID = ProviderID(rawValue: "codex-agent"), displayName: String = "Codex") {
        self.id = id
        self.displayName = displayName
    }

    public func prepare() async throws {}

    public func start(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        recordedRequests.append(request)
        let stream = AsyncThrowingStream<AgentEvent, Error>.makeStream(of: AgentEvent.self)
        continuations[request.runID] = stream.continuation
        stream.continuation.yield(.started(runID: request.runID, providerID: id))
        return stream.stream
    }

    public func cancel(_ runID: AgentRunID) async {
        cancelledRunIDs.append(runID)
        guard let continuation = continuations.removeValue(forKey: runID) else {
            return
        }
        continuation.yield(.cancelled(runID: runID))
        continuation.finish(throwing: RocaError.cancelled)
    }
}

public actor SetupRequiredSessionAgentProvider: AgentProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities = AgentCapabilities(
        supportsStreaming: true,
        supportsToolApprovals: true,
        supportsLocalExecution: true,
        locality: .remote,
        supportedModes: AgentMode.allCases
    )

    private let status: AgentProviderSetupStatus

    public init(
        id: ProviderID = ProviderID(rawValue: "claude-code"),
        displayName: String = "Claude",
        state: AgentProviderSetupState = .runtimeMissing,
        summary: String = "Claude Code CLI is not installed.",
        guidance: String = "Install Claude Code, sign in with a Claude Code-capable account, then recheck Claude Code."
    ) {
        self.id = id
        self.displayName = displayName
        self.status = AgentProviderSetupStatus(
            providerID: id,
            displayName: displayName,
            state: state,
            summary: summary,
            guidance: guidance,
            installCommand: state == .ready ? nil : "curl -fsSL https://claude.ai/install.sh | bash"
        )
    }

    public func prepare() async throws {
        throw RocaError.agentProviderSetupRequired(status)
    }

    public func start(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        throw RocaError.agentProviderSetupRequired(status)
    }

    public func cancel(_ runID: AgentRunID) async {}
}

public actor RecordingProjectWriter: ProjectIdentityWriting {
    public private(set) var upsertedProjects: [ProjectIdentity] = []

    public init() {}

    public func upsert(_ project: ProjectIdentity) async throws {
        upsertedProjects.append(project)
    }
}

public actor RecordingSessionSTTProvider: STTProvider {
    public let id = ProviderID(rawValue: "stt")
    public let displayName = "STT"
    public let capabilities = STTCapabilities(supportsStreaming: true, supportedLocales: ["en-US"], locality: .local)
    public private(set) var cancelled: [TranscriptionID] = []
    private let text: String

    public init(text: String) {
        self.text = text
    }

    public func prepare() async throws {}

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        request: STTRequest
    ) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.final(TranscriptSegment(text: text, segmentIndex: 0, startTime: nil, endTime: nil, confidence: nil)))
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    public func cancel(_ transcriptionID: TranscriptionID) async {
        cancelled.append(transcriptionID)
    }
}

public struct AllowingSessionPermissions: PermissionsServicing {
    public init() {}

    public func isAccessibilityTrusted() async -> Bool { true }
    public func requestAccessibilityIfNeeded() async -> Bool { true }
    public func microphonePermissionStatus() async -> MicrophonePermissionStatus { .allowed }
    public func requestMicrophoneIfNeeded() async -> Bool { true }
    public func speechRecognitionPermissionStatus() async -> SpeechRecognitionPermissionStatus { .allowed }
    public func requestSpeechRecognitionIfNeeded() async -> Bool { true }
}

public actor RecordingSessionSpeech: SpeechOrchestrating {
    public var state: SpeechPlaybackState = .idle
    public var activeSession: ActiveSpeechSession?
    public private(set) var speakCount = 0
    public private(set) var spokenTexts: [String] = []
    private var utteranceMetrics: [UtteranceID: SpeechUtteranceMetrics] = [:]
    private let chunkCharacterLimit: Int?

    public init(chunkCharacterLimit: Int? = nil) {
        self.chunkCharacterLimit = chunkCharacterLimit
    }

    public func speak(_ request: SpeechRequest) async throws {
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

    public func recommendedChunkCharacterLimit(for request: SpeechRequest) async throws -> Int? {
        chunkCharacterLimit
    }

    public func metrics(for utteranceID: UtteranceID) async -> SpeechUtteranceMetrics? {
        utteranceMetrics[utteranceID]
    }

    public func waitForCompletion(of utteranceID: UtteranceID) async throws {
        state = .idle
    }

    public func stopSpeaking() async {
        state = .stopped
    }
}

public actor NoopSessionAudioInput: AudioInputSession {
    public var state: AudioInputState {
        .idle
    }

    public var metrics: AudioInputMetrics {
        AudioInputMetrics()
    }

    public init() {}

    public func start(_ request: AudioInputRequest) async throws -> AsyncThrowingStream<AudioFrame, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    public func stop() async {}
}

public actor FakeSessionAudioInput: AudioInputSession {
    public var state: AudioInputState = .idle
    public var metrics: AudioInputMetrics

    public init(metrics: AudioInputMetrics = AudioInputMetrics()) {
        self.metrics = metrics
    }

    public func start(_ request: AudioInputRequest) async throws -> AsyncThrowingStream<AudioFrame, Error> {
        state = .recording
        return AsyncThrowingStream { _ in }
    }

    public func stop() async {
        state = .stopped
    }
}

public struct NoopSessionInserter: FocusedTextInserting {
    public init() {}

    public func insertIntoFocusedApp(_ text: String) async throws {}
}

public actor RecordingSessionAppCommands: ApplicationCommandExecuting {
    public private(set) var commands: [ApplicationCommand] = []
    private let result: ApplicationCommandExecutionResult

    public init(result: ApplicationCommandExecutionResult = .opened(ApplicationMatch(
        displayName: "App",
        bundleID: "app",
        url: URL(fileURLWithPath: "/Applications/App.app")
    ))) {
        self.result = result
    }

    public func execute(_ command: ApplicationCommand) async -> ApplicationCommandExecutionResult {
        commands.append(command)
        return result
    }
}

public struct StaticSessionContextProvider: AssistantContextProviding {
    public var context: AssistantLocalContext

    public init(
        context: AssistantLocalContext = AssistantLocalContext(
            activeAppName: "TextEdit",
            activeAppBundleID: "com.apple.TextEdit",
            hasFocusedTextInput: true
        )
    ) {
        self.context = context
    }

    public func currentContext() async -> AssistantLocalContext {
        context
    }
}
