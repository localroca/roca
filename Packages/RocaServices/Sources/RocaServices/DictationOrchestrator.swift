import Foundation
import RocaCore

public actor DefaultDictationOrchestrator: DictationOrchestrating {
    public typealias StopSpeechHandler = @Sendable () async -> Void

    private let resolver: any ProviderResolving
    private let audioInput: any AudioInputSession
    private let inserter: any FocusedTextInserting
    private let permissions: any PermissionsServicing
    private let stopSpeech: StopSpeechHandler
    private let companionState: CompanionStateCenter?
    private let recoveryExpirationNanoseconds: UInt64?

    private var currentState: DictationState = .idle
    private var activeSession: ActiveDictationSession?
    private var recoveryTranscript: RecoverableDictationTranscript?
    private var recoveryExpirationTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<DictationState>.Continuation] = [:]

    public nonisolated var stateUpdates: AsyncStream<DictationState> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.addStateContinuation(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeStateContinuation(id)
                }
            }
        }
    }

    public var state: DictationState {
        currentState
    }

    public init(
        resolver: any ProviderResolving,
        audioInput: any AudioInputSession,
        inserter: any FocusedTextInserting,
        permissions: any PermissionsServicing = DefaultPermissionsService(),
        stopSpeech: @escaping StopSpeechHandler,
        companionState: CompanionStateCenter? = nil,
        recoveryExpirationSeconds: TimeInterval = 600
    ) {
        self.resolver = resolver
        self.audioInput = audioInput
        self.inserter = inserter
        self.permissions = permissions
        self.stopSpeech = stopSpeech
        self.companionState = companionState
        if recoveryExpirationSeconds > 0 {
            self.recoveryExpirationNanoseconds = UInt64(recoveryExpirationSeconds * 1_000_000_000)
        } else {
            self.recoveryExpirationNanoseconds = nil
        }
    }

    public func start(_ request: DictationRequest) async throws {
        guard activeSession == nil else {
            return
        }
        guard request.intent == .dictation, request.insertionTarget == .focusedApp else {
            throw RocaError.selectionUnavailable("Phase 2 only supports focused-app dictation.")
        }

        await stopSpeech()
        if await permissions.microphonePermissionStatus() != .allowed {
            setState(.requestingPermission)
            await emit(
                .waitingForPermission(.microphone),
                message: "Microphone permission needed.",
                correlationID: request.transcriptionID.rawValue
            )
        }

        guard await permissions.requestMicrophoneIfNeeded() else {
            setState(.failed("Microphone permission needed"))
            throw RocaError.permission(.microphone)
        }

        do {
            let provider = try await resolver.sttProvider(
                STTResolutionRequest(
                    requestedProviderID: request.providerID,
                    locale: request.locale,
                    intent: request.intent,
                    allowFallback: request.providerID == nil,
                    requireLocal: true
                )
            )
            let audio = try await audioInput.start(
                AudioInputRequest(
                    mode: request.mode,
                    preferredSampleRate: 16_000,
                    preferredChannels: 1
                )
            )
            do {
                try Task.checkCancellation()
                let transcriptEvents = try await provider.transcribe(
                    audio,
                    request: STTRequest(
                        transcriptionID: request.transcriptionID,
                        locale: request.locale,
                        mode: request.mode,
                        intent: request.intent
                    )
                )
                try Task.checkCancellation()

                let transcriptTask = Task {
                    try await Self.finalizedTranscript(from: transcriptEvents) { [weak self] in
                        await self?.setStateFromTask(.transcribing)
                    }
                }
                activeSession = ActiveDictationSession(
                    request: request,
                    provider: provider,
                    transcriptTask: transcriptTask
                )
                setState(.listening)
                await emit(.listening, message: "Listening.", correlationID: request.transcriptionID.rawValue)
            } catch {
                await audioInput.stop()
                await provider.cancel(request.transcriptionID)
                throw error
            }
        } catch {
            let message = error.localizedDescription
            setState(.failed(message))
            await emit(.offline(reason: message), message: message, correlationID: request.transcriptionID.rawValue)
            throw error
        }
    }

    public func stop() async {
        guard let session = activeSession else {
            setState(.stopped)
            return
        }
        activeSession = nil

        await audioInput.stop()
        let transcript: String
        do {
            transcript = try await session.transcriptTask.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await session.provider.cancel(session.request.transcriptionID)
            setState(.failed("Dictation failed."))
            await emit(.offline(reason: "Dictation failed."), message: "Dictation failed.", correlationID: session.request.transcriptionID.rawValue)
            return
        }

        guard !transcript.isEmpty else {
            setState(.stopped)
            await emit(.idle, message: "Ready", correlationID: session.request.transcriptionID.rawValue)
            return
        }

        setState(.inserting)
        do {
            try await inserter.insertIntoFocusedApp(transcript)
            clearRecoveryTranscript()
            setState(.stopped)
            await emit(.idle, message: "Dictation inserted.", correlationID: session.request.transcriptionID.rawValue)
        } catch {
            recoveryTranscript = RecoverableDictationTranscript(
                transcriptionID: session.request.transcriptionID,
                text: transcript,
                createdAt: Date(),
                failureMessage: error.localizedDescription
            )
            scheduleRecoveryExpiration(for: session.request.transcriptionID)
            setState(.failed("Dictation insertion failed. Transcript is recoverable."))
            await emit(
                .offline(reason: "Dictation insertion failed."),
                message: "Dictation insertion failed. Transcript is recoverable.",
                correlationID: session.request.transcriptionID.rawValue
            )
        }
    }

    public func cancel() async {
        guard let session = activeSession else {
            setState(.stopped)
            return
        }
        activeSession = nil
        session.transcriptTask.cancel()
        await audioInput.stop()
        await session.provider.cancel(session.request.transcriptionID)
        setState(.stopped)
        await emit(.interrupted, message: "Dictation cancelled.", correlationID: session.request.transcriptionID.rawValue)
    }

    public func recoverableTranscript() -> RecoverableDictationTranscript? {
        recoveryTranscript
    }

    public func retryRecoverableTranscript() async throws {
        guard let transcript = recoveryTranscript else {
            return
        }
        setState(.inserting)
        try await inserter.insertIntoFocusedApp(transcript.text)
        clearRecoveryTranscript()
        setState(.stopped)
    }

    public func discardRecoverableTranscript() {
        clearRecoveryTranscript()
    }

    private func clearRecoveryTranscript() {
        recoveryExpirationTask?.cancel()
        recoveryExpirationTask = nil
        recoveryTranscript = nil
    }

    private func scheduleRecoveryExpiration(for transcriptionID: TranscriptionID) {
        recoveryExpirationTask?.cancel()
        guard let recoveryExpirationNanoseconds else {
            recoveryExpirationTask = nil
            return
        }
        recoveryExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: recoveryExpirationNanoseconds)
            } catch {
                return
            }
            await self?.expireRecoveryTranscript(transcriptionID)
        }
    }

    private func expireRecoveryTranscript(_ transcriptionID: TranscriptionID) {
        guard recoveryTranscript?.transcriptionID == transcriptionID else {
            return
        }
        clearRecoveryTranscript()
        setState(.stopped)
    }

    private func setState(_ state: DictationState) {
        currentState = state
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func setStateFromTask(_ state: DictationState) {
        setState(state)
    }

    private func addStateContinuation(_ continuation: AsyncStream<DictationState>.Continuation, id: UUID) {
        stateContinuations[id] = continuation
        continuation.yield(currentState)
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func emit(_ activity: RocaActivity, message: String, correlationID: String?) async {
        await companionState?.emit(
            CompanionStateEvent(
                activity: activity,
                message: message,
                source: .stt,
                correlationID: correlationID,
                sensitivity: .publicStatus
            )
        )
    }

    private nonisolated static func finalizedTranscript(
        from events: AsyncThrowingStream<TranscriptEvent, Error>,
        onTranscribing: @escaping @Sendable () async -> Void
    ) async throws -> String {
        var segments: [Int: String] = [:]
        var finalText: String?
        var didMarkTranscribing = false

        for try await event in events {
            if !didMarkTranscribing {
                didMarkTranscribing = true
                await onTranscribing()
            }

            switch event {
            case .partial:
                continue
            case .segment(let segment):
                segments[segment.segmentIndex] = segment.text
            case .final(let segment):
                finalText = segment.text
            case .finished:
                break
            }
        }

        if let finalText {
            return finalText
        }

        return segments
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined(separator: " ")
    }
}

private struct ActiveDictationSession: Sendable {
    var request: DictationRequest
    var provider: any STTProvider
    var transcriptTask: Task<String, Error>
}
