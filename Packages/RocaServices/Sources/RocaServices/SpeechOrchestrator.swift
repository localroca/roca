import Foundation
import RocaCore

public actor DefaultSpeechOrchestrator: SpeechOrchestrating {
    private let resolver: any ProviderResolving
    private let playback: any SpeechPlaybackControlling
    private let companionState: CompanionStateCenter?
    private let fingerprinting: TextFingerprinting

    private var activeProvider: (any TTSProvider)?
    private var currentState: SpeechPlaybackState = .idle
    private var currentSession: ActiveSpeechSession?
    private var speechGeneration = 0
    private var playbackObservationTask: Task<Void, Never>?
    private var completionWaiters: [UtteranceID: [CheckedContinuation<Void, Error>]] = [:]
    private var completedMetrics: [UtteranceID: SpeechUtteranceMetrics] = [:]
    private var completedMetricOrder: [UtteranceID] = []

    public var state: SpeechPlaybackState {
        currentState
    }

    public var activeSession: ActiveSpeechSession? {
        currentSession
    }

    public init(
        resolver: any ProviderResolving,
        playback: any SpeechPlaybackControlling,
        companionState: CompanionStateCenter? = nil,
        fingerprinting: TextFingerprinting = TextFingerprinting()
    ) {
        self.resolver = resolver
        self.playback = playback
        self.companionState = companionState
        self.fingerprinting = fingerprinting
    }

    public func speak(_ request: SpeechRequest) async throws {
        beginObservingPlaybackIfNeeded()
        speechGeneration += 1
        let generation = speechGeneration
        let previousSession = currentSession
        let previousProvider = activeProvider
        currentSession = nil
        activeProvider = nil
        currentState = .loading

        if let previousSession {
            await previousProvider?.cancel(previousSession.utteranceID)
            finishCompletionWaiters(for: previousSession.utteranceID, result: .failure(RocaError.cancelled))
        }
        await playback.stop()
        guard isCurrent(generation) else {
            throw RocaError.cancelled
        }

        await emit(.thinking, message: "Preparing speech.", source: .tts, correlationID: request.utteranceID.rawValue)

        let provider = try await resolver.ttsProvider(
            TTSResolutionRequest(
                requestedProviderID: request.providerID,
                source: request.source,
                allowFallback: request.allowFallback
            )
        )
        guard isCurrent(generation) else {
            await provider.cancel(request.utteranceID)
            throw RocaError.cancelled
        }
        activeProvider = provider
        let voice = request.providerVoiceSelections[provider.id] ?? request.voice
        let format = Self.format(for: provider, requested: request.format)

        let ttsRequest = TTSRequest(
            utteranceID: request.utteranceID,
            text: request.text,
            voice: voice,
            format: format,
            speed: request.speed
        )
        let synthesisStartedAt = Date()
        let stream = try await provider.synthesize(ttsRequest)
        guard isCurrent(generation) else {
            await provider.cancel(request.utteranceID)
            throw RocaError.cancelled
        }
        let instrumentedStream = instrumentedEvents(
            stream,
            request: request,
            providerID: provider.id,
            synthesisStartedAt: synthesisStartedAt
        )

        currentSession = ActiveSpeechSession(
            utteranceID: request.utteranceID,
            providerID: provider.id,
            source: request.source,
            normalizedTextFingerprint: request.source == .selectedText ? fingerprinting.fingerprint(request.text) : nil,
            startedAt: Date()
        )

        currentState = .loading
        await emit(.preparingSpeech, message: "Preparing voice.", source: .tts, correlationID: request.utteranceID.rawValue)

        try await playback.play(instrumentedStream)
        guard isCurrent(generation) else {
            await provider.cancel(request.utteranceID)
            await playback.stop()
            throw RocaError.cancelled
        }
    }

    public func waitForCompletion(of utteranceID: UtteranceID) async throws {
        guard currentSession?.utteranceID == utteranceID else {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            guard currentSession?.utteranceID == utteranceID else {
                continuation.resume(returning: ())
                return
            }
            completionWaiters[utteranceID, default: []].append(continuation)
        }
    }

    public func recommendedChunkCharacterLimit(for request: SpeechRequest) async throws -> Int? {
        let provider = try await resolver.ttsProvider(
            TTSResolutionRequest(
                requestedProviderID: request.providerID,
                source: request.source,
                allowFallback: request.allowFallback
            )
        )
        return provider.capabilities.recommendedChunkCharacterLimit
    }

    public func metrics(for utteranceID: UtteranceID) async -> SpeechUtteranceMetrics? {
        completedMetrics[utteranceID]
    }

    public func stopSpeaking() async {
        speechGeneration += 1
        let session = currentSession
        let provider = activeProvider
        currentSession = nil
        activeProvider = nil
        currentState = .stopped

        if let session {
            await provider?.cancel(session.utteranceID)
            finishCompletionWaiters(for: session.utteranceID, result: .failure(RocaError.cancelled))
            await emit(.interrupted, message: "Speech stopped.", source: .tts, correlationID: session.utteranceID.rawValue)
        }
        await playback.stop()
    }

    public func fingerprint(_ text: String) -> String {
        fingerprinting.fingerprint(text)
    }

    private func emit(
        _ activity: RocaActivity,
        message: String,
        source: CompanionEventSource,
        correlationID: String?
    ) async {
        await companionState?.emit(
            CompanionStateEvent(
                activity: activity,
                message: message,
                source: source,
                correlationID: correlationID,
                sensitivity: .publicStatus
            )
        )
    }

    private func instrumentedEvents(
        _ events: AsyncThrowingStream<TTSEvent, Error>,
        request: SpeechRequest,
        providerID: ProviderID,
        synthesisStartedAt: Date
    ) -> AsyncThrowingStream<TTSEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var firstAudioAt: Date?
                var audioChunkCount = 0
                var audioDurationMilliseconds = 0

                do {
                    for try await event in events {
                        switch event {
                        case .audioChunk(let chunk):
                            audioChunkCount += 1
                            firstAudioAt = firstAudioAt ?? Date()
                            if let duration = AudioChunkDurationEstimator.durationMilliseconds(for: chunk) {
                                audioDurationMilliseconds += duration
                            }
                        case .finished:
                            let finishedAt = Date()
                            let metrics = SpeechUtteranceMetrics(
                                utteranceID: request.utteranceID,
                                providerID: providerID,
                                source: request.source,
                                requestedCharacterCount: request.text.count,
                                audioChunkCount: audioChunkCount,
                                firstAudioMilliseconds: firstAudioAt.map {
                                    Self.milliseconds(from: synthesisStartedAt, to: $0)
                                },
                                synthesisMilliseconds: Self.milliseconds(from: synthesisStartedAt, to: finishedAt),
                                audioDurationMilliseconds: audioDurationMilliseconds > 0 ? audioDurationMilliseconds : nil
                            )
                            self.storeCompletedMetrics(metrics)
                        case .started, .cancelled:
                            break
                        }

                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func storeCompletedMetrics(_ metrics: SpeechUtteranceMetrics) {
        if completedMetrics[metrics.utteranceID] == nil {
            completedMetricOrder.append(metrics.utteranceID)
        }
        completedMetrics[metrics.utteranceID] = metrics

        while completedMetricOrder.count > 50 {
            let oldestID = completedMetricOrder.removeFirst()
            completedMetrics.removeValue(forKey: oldestID)
        }
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private func handlePlaybackState(_ state: SpeechPlaybackState) async {
        switch state {
        case .idle:
            let session = currentSession
            currentSession = nil
            currentState = .idle

            if let session {
                finishCompletionWaiters(for: session.utteranceID, result: .success(()))
                await emit(.idle, message: "Ready", source: .tts, correlationID: session.utteranceID.rawValue)
            }
        case .loading:
            currentState = .loading
        case .playing:
            currentState = .playing
            if let session = currentSession {
                await emit(.speaking, message: "Speaking.", source: .tts, correlationID: session.utteranceID.rawValue)
            }
        case .stopped:
            let session = currentSession
            currentSession = nil
            currentState = .stopped
            if let session {
                finishCompletionWaiters(for: session.utteranceID, result: .failure(RocaError.cancelled))
            }
        case .failed(let message):
            let session = currentSession
            currentSession = nil
            currentState = .failed(message)
            if let session {
                finishCompletionWaiters(for: session.utteranceID, result: .failure(RocaError.synthesisFailed(message)))
            }
            await emit(
                .offline(reason: message),
                message: message,
                source: .tts,
                correlationID: session?.utteranceID.rawValue
            )
        }
    }

    private func beginObservingPlaybackIfNeeded() {
        guard playbackObservationTask == nil else {
            return
        }

        let playback = playback
        playbackObservationTask = Task { [weak self] in
            for await state in playback.stateUpdates {
                await self?.handlePlaybackState(state)
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == speechGeneration
    }

    private func finishCompletionWaiters(for utteranceID: UtteranceID, result: Result<Void, Error>) {
        let waiters = completionWaiters.removeValue(forKey: utteranceID) ?? []
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private nonisolated static func format(for provider: any TTSProvider, requested: AudioDescriptor) -> AudioDescriptor {
        let supportedFormats = provider.capabilities.supportedFormats
        if supportedFormats.contains(requested) {
            return requested
        }
        return supportedFormats.first ?? requested
    }
}
