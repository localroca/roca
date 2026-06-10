import Foundation
import RocaCore

private enum BrainFailurePhase {
    case setup
    case routing
    case response

    func timeoutMessage(modelID: String) -> String {
        switch self {
        case .routing:
            return "\(modelID) timed out during routing. Try a faster model for Roca assistant routing."
        case .response:
            return "\(modelID) timed out while generating a response. Try again or choose a faster model."
        case .setup:
            return "\(modelID) timed out while preparing the assistant brain. Try again or choose a faster model."
        }
    }
}

public actor DefaultAssistantSessionOrchestrator {
    public typealias StopSpeechHandler = @Sendable () async -> Void

    private let resolver: any ProviderResolving
    private let audioInput: any AudioInputSession
    private let inserter: any FocusedTextInserting
    private let permissions: any PermissionsServicing
    private let speechOrchestrator: any SpeechOrchestrating
    private let applicationCommands: any ApplicationCommandExecuting
    private let contextProvider: any AssistantContextProviding
    private let readSelectionCommand: ReadSelectionCommand?
    private let companionState: CompanionStateCenter?
    private let stopSpeech: StopSpeechHandler

    private var currentState: AssistantState = .idle
    private var messages: [ChatMessage] = [
        ChatMessage(
            role: .status,
            source: .status,
            text: "Ask Roca by typing or speaking.",
            status: .completed
        )
    ]
    private var activeSession: ActiveAssistantSessionListeningSession?
    private var activeTurnID: BrainRequestID?
    private var activeBrainProvider: (any BrainProvider)?
    private var activeBrainRequestID: BrainRequestID?
    private var cancelledTurnIDs: Set<BrainRequestID> = []
    private var conversationMessages: [BrainMessage] = []
    private var stateContinuations: [UUID: AsyncStream<AssistantState>.Continuation] = [:]
    private var messageContinuations: [UUID: AsyncStream<[ChatMessage]>.Continuation] = [:]
    private var metricsContinuations: [UUID: AsyncStream<AssistantTurnMetrics>.Continuation] = [:]

    public nonisolated var stateUpdates: AsyncStream<AssistantState> {
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

    public nonisolated var messageUpdates: AsyncStream<[ChatMessage]> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.addMessageContinuation(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeMessageContinuation(id)
                }
            }
        }
    }

    public nonisolated var turnMetricsUpdates: AsyncStream<AssistantTurnMetrics> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.addMetricsContinuation(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeMetricsContinuation(id)
                }
            }
        }
    }

    public var state: AssistantState {
        currentState
    }

    public var messageSnapshot: [ChatMessage] {
        messages
    }

    public init(
        resolver: any ProviderResolving,
        audioInput: any AudioInputSession,
        inserter: any FocusedTextInserting,
        permissions: any PermissionsServicing = DefaultPermissionsService(),
        speechOrchestrator: any SpeechOrchestrating,
        applicationCommands: any ApplicationCommandExecuting = DefaultApplicationCommandExecutor(),
        contextProvider: any AssistantContextProviding = DefaultAssistantContextProvider(),
        readSelectionCommand: ReadSelectionCommand? = nil,
        companionState: CompanionStateCenter? = nil,
        stopSpeech: @escaping StopSpeechHandler
    ) {
        self.resolver = resolver
        self.audioInput = audioInput
        self.inserter = inserter
        self.permissions = permissions
        self.speechOrchestrator = speechOrchestrator
        self.applicationCommands = applicationCommands
        self.contextProvider = contextProvider
        self.readSelectionCommand = readSelectionCommand
        self.companionState = companionState
        self.stopSpeech = stopSpeech
    }

    public func submitText(_ text: String, request: AssistantSessionTurnRequest) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard activeSession == nil, activeTurnID == nil else {
            appendStatus("Finish the current turn first.", status: .failed, request: request)
            return
        }

        await stopSpeech()
        var timing = AssistantTurnTimingBuilder(turnID: request.turnID)
        timing.listeningStartedAt = timing.startedAt
        timing.stopRequestedAt = timing.startedAt
        timing.transcriptReadyAt = timing.startedAt
        await runAssistantTurn(input: trimmed, request: request, timing: timing)
    }

    public func startVoice(_ request: AssistantSessionTurnRequest) async throws {
        guard activeSession == nil, activeTurnID == nil else {
            return
        }

        var timing = AssistantTurnTimingBuilder(turnID: request.turnID)
        cancelledTurnIDs.remove(request.turnID)

        await stopSpeech()
        let listeningMessageID = appendStatus("Listening...", status: .pending, request: request)
        if await permissions.microphonePermissionStatus() != .allowed {
            setState(.requestingPermission)
            await emit(.waitingForPermission(.microphone), message: "Microphone permission needed.", correlationID: request.turnID.rawValue)
        }

        guard await permissions.requestMicrophoneIfNeeded() else {
            completeMessage(listeningMessageID, text: "Microphone permission needed.", status: .failed)
            setState(.failed("Microphone permission needed"))
            throw RocaError.permission(.microphone)
        }

        do {
            let provider = try await resolver.sttProvider(
                STTResolutionRequest(
                    requestedProviderID: request.sttProviderID,
                    locale: request.locale,
                    intent: .assistantPrompt,
                    allowFallback: request.sttProviderID == nil,
                    requireLocal: true
                )
            )
            let audio = try await audioInput.start(
                AudioInputRequest(mode: request.mode, preferredSampleRate: 16_000, preferredChannels: 1)
            )
            do {
                let transcriptEvents = try await provider.transcribe(
                    audio,
                    request: STTRequest(
                        transcriptionID: request.transcriptionID,
                        locale: request.locale,
                        mode: request.mode,
                        intent: .assistantPrompt
                    )
                )
                let transcriptTask = Task {
                    try await Self.finalizedTranscript(from: transcriptEvents) { [weak self] in
                        await self?.setStateFromTask(.transcribing)
                    }
                }
                timing.listeningStartedAt = Date()
                activeSession = ActiveAssistantSessionListeningSession(
                    request: request,
                    provider: provider,
                    transcriptTask: transcriptTask,
                    timing: timing,
                    listeningMessageID: listeningMessageID
                )
                setState(.listening)
                await emit(.listening, message: "Listening.", correlationID: request.turnID.rawValue)
            } catch {
                await audioInput.stop()
                await provider.cancel(request.transcriptionID)
                throw error
            }
        } catch {
            let message = error.localizedDescription
            completeMessage(listeningMessageID, text: message, status: .failed)
            setState(.failed(message))
            await emit(.offline(reason: message), message: message, correlationID: request.turnID.rawValue)
            throw error
        }
    }

    public func stopVoice() async {
        guard let session = activeSession else {
            await cancelActiveBrainAndSpeech()
            setState(.stopped)
            return
        }
        var timing = session.timing
        activeSession = nil
        timing.stopRequestedAt = Date()
        await audioInput.stop()
        timing.audioMetrics = await audioInput.metrics

        let transcript: String
        do {
            transcript = try await session.transcriptTask.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            timing.transcriptReadyAt = Date()
        } catch {
            await session.provider.cancel(session.request.transcriptionID)
            completeMessage(session.listeningMessageID, text: "Assistant transcription failed.", status: .failed)
            setState(.failed("Assistant transcription failed."))
            await emit(.offline(reason: "Assistant transcription failed."), message: "Assistant transcription failed.", correlationID: session.request.turnID.rawValue)
            emitMetrics(timing.snapshot(outcome: .failed))
            return
        }

        guard !transcript.isEmpty else {
            completeMessage(session.listeningMessageID, text: "No speech detected.", status: .completed)
            setState(.stopped)
            await emit(.idle, message: "Ready", correlationID: session.request.turnID.rawValue)
            emitMetrics(timing.snapshot(outcome: .completed))
            return
        }

        removeMessage(session.listeningMessageID)
        await runAssistantTurn(input: transcript, request: session.request, timing: timing)
    }

    public func cancel() async {
        if let session = activeSession {
            activeSession = nil
            cancelledTurnIDs.insert(session.request.turnID)
            var timing = session.timing
            timing.stopRequestedAt = timing.stopRequestedAt ?? Date()
            session.transcriptTask.cancel()
            await audioInput.stop()
            timing.audioMetrics = await audioInput.metrics
            await session.provider.cancel(session.request.transcriptionID)
            completeMessage(session.listeningMessageID, text: "Voice turn cancelled.", status: .cancelled)
            emitMetrics(timing.snapshot(outcome: .cancelled))
        }
        if let activeTurnID {
            cancelledTurnIDs.insert(activeTurnID)
            markTurnMessages(activeTurnID, status: .cancelled)
        }
        await cancelActiveBrainAndSpeech()
        setState(.stopped)
        await emit(.interrupted, message: "Assistant cancelled.", correlationID: nil)
    }

    public func clearConversation() {
        messages = [
            ChatMessage(
                role: .status,
                source: .status,
                text: "Conversation cleared.",
                status: .completed
            )
        ]
        conversationMessages = []
        publishMessages()
    }

    public func postStatus(_ text: String, status: ChatMessageStatus = .completed) {
        appendStatus(text, status: status)
    }

    private func runAssistantTurn(
        input: String,
        request: AssistantSessionTurnRequest,
        timing incomingTiming: AssistantTurnTimingBuilder
    ) async {
        var timing = incomingTiming
        activeTurnID = request.turnID
        cancelledTurnIDs.remove(request.turnID)
        appendUserMessage(input, request: request)
        defer {
            if activeTurnID == request.turnID {
                activeTurnID = nil
            }
            activeBrainProvider = nil
            activeBrainRequestID = nil
            cancelledTurnIDs.remove(request.turnID)
        }

        setState(.thinking)
        await emit(.thinking, message: "Thinking.", correlationID: request.turnID.rawValue)
        do {
            let context = await contextProvider.currentContext()
            let brainProvider = try await resolver.brainProvider(id: request.selection(for: .companionRouter).providerID)
            activeBrainProvider = brainProvider
            activeBrainRequestID = request.turnID

            timing.directiveStartedAt = Date()
            let directive = try await resolveDirective(
                input: input,
                request: request,
                context: context,
                provider: brainProvider
            )
            timing.directiveFinishedAt = Date()
            timing.directiveType = directive.metricType
            try Task.checkCancellation()
            try await handleDirective(
                directive,
                input: input,
                request: request,
                context: context,
                provider: brainProvider,
                timing: &timing
            )
            emitMetrics(timing.snapshot(outcome: .completed))
        } catch {
            if Self.isCancellation(error) || isTurnCancelled(request.turnID) {
                setState(.stopped)
                await emit(.interrupted, message: "Assistant cancelled.", correlationID: request.turnID.rawValue)
                markTurnMessages(request.turnID, status: .cancelled)
                emitMetrics(timing.snapshot(outcome: .cancelled))
                return
            }

            let failurePhase = Self.brainFailurePhase(from: timing)
            let recoveryMessage = Self.brainRecoveryMessage(for: error, phase: failurePhase)
            let message = recoveryMessage ?? error.localizedDescription
            appendStatus(message, status: .failed, request: request)
            setState(.failed(message))
            await emit(.offline(reason: message), message: message, correlationID: request.turnID.rawValue)
            if recoveryMessage != nil, request.outputMode != .textOnly {
                try? await speak(message, request: request, timing: &timing, force: true)
            }
            emitMetrics(timing.snapshot(outcome: .failed))
        }
    }

    private func resolveDirective(
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        provider: any BrainProvider
    ) async throws -> AssistantDirective {
        let brainRequest = BrainRequest(
            requestID: request.turnID,
            messages: [
                BrainMessage(role: .system, content: AssistantPromptCatalog.directiveSystemPrompt),
                BrainMessage(
                    role: .user,
                    content: AssistantPromptCatalog.directiveUserPrompt(input: input, context: context)
                )
            ],
            role: .companionRouter,
            modelID: request.selection(for: .companionRouter).modelID,
            context: RequestContext(
                selectedText: nil,
                activeAppBundleID: context.activeAppBundleID,
                activeAppName: context.activeAppName,
                memoryIDs: []
            ),
            metadata: ["responseFormat": "json"]
        )
        let events = try await provider.complete(brainRequest)
        let response = try await Self.finalBrainText(from: events)
        return try AssistantPromptCatalog.parseDirective(response)
    }

    private func handleDirective(
        _ directive: AssistantDirective,
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        provider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder
    ) async throws {
        switch directive {
        case .respond:
            timing.responseBrainStartedAt = Date()
            let assistantMessageID = appendAssistantMessage(
                "",
                status: .streaming,
                request: request,
                directiveType: directive.metricType,
                brainRole: .generalChat
            )
            let response = try await completeAssistantResponse(
                input: input,
                request: request,
                context: context,
                provider: provider,
                messageID: assistantMessageID
            )
            timing.responseBrainFinishedAt = Date()
            completeMessage(
                assistantMessageID,
                text: response.bubbleText,
                detailsMarkdown: response.detailsMarkdown,
                status: .completed
            )
            remember(userText: input, assistantText: response.conversationText)
            try await speak(response.bubbleText, request: request, timing: &timing)
        case .openApplication(let target):
            setState(.acting("Opening \(target.displayName)"))
            let actionID = appendActionMessage("Opening \(target.displayName)...", status: .pending, request: request, directiveType: directive.metricType)
            timing.actionStartedAt = Date()
            let result = await applicationCommands.execute(.open(target))
            timing.actionFinishedAt = Date()
            completeMessage(actionID, text: result.spokenSummary, status: .completed)
            try await speak(result.spokenSummary, request: request, timing: &timing, force: request.inputMode == .voice)
        case .quitApplication(let target):
            setState(.acting("Quitting \(target.displayName)"))
            let actionID = appendActionMessage("Quitting \(target.displayName)...", status: .pending, request: request, directiveType: directive.metricType)
            timing.actionStartedAt = Date()
            let result = await applicationCommands.execute(.quit(target))
            timing.actionFinishedAt = Date()
            completeMessage(actionID, text: result.spokenSummary, status: .completed)
            try await speak(result.spokenSummary, request: request, timing: &timing, force: request.inputMode == .voice)
        case .insertText(let text):
            setState(.acting("Inserting text"))
            let actionID = appendActionMessage("Inserting text...", status: .pending, request: request, directiveType: directive.metricType)
            do {
                timing.actionStartedAt = Date()
                try await inserter.insertIntoFocusedApp(text)
                timing.actionFinishedAt = Date()
            } catch {
                timing.actionFinishedAt = Date()
                if Self.isCancellation(error) {
                    throw error
                }
                let message = "I couldn't insert that. Check that a text field is focused and Accessibility is allowed."
                completeMessage(actionID, text: message, status: .failed)
                try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
                return
            }
            completeMessage(actionID, text: "Inserted that.", status: .completed)
            try await speak("Inserted that.", request: request, timing: &timing, force: request.inputMode == .voice)
        case .readSelection:
            setState(.acting("Reading selection"))
            let actionID = appendActionMessage("Reading selected text...", status: .pending, request: request, directiveType: directive.metricType)
            guard let readSelectionCommand else {
                let message = "I can't read selected text from this surface yet."
                completeMessage(actionID, text: message, status: .failed)
                try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
                return
            }
            timing.actionStartedAt = Date()
            let result = try await readSelectionCommand.run()
            timing.actionFinishedAt = Date()
            let summary = Self.readSelectionSummary(for: result)
            completeMessage(actionID, text: summary.text, status: summary.status)
            if summary.status == .failed, request.inputMode == .voice {
                try await speak(summary.text, request: request, timing: &timing, force: true)
            } else {
                setState(.stopped)
            }
        case .unsupported(let message):
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: directive.metricType)
            completeMessage(id, text: message, status: .completed)
            try await speak(message, request: request, timing: &timing)
        }
    }

    private func completeAssistantResponse(
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        provider: any BrainProvider,
        messageID: ChatMessageID
    ) async throws -> AssistantResponseContent {
        var messages = [
            BrainMessage(role: .system, content: AssistantPromptCatalog.responseSystemPrompt(for: request.inputMode))
        ]
        messages.append(contentsOf: conversationMessages)
        messages.append(BrainMessage(role: .user, content: input))
        let brainRequest = BrainRequest(
            requestID: request.turnID,
            messages: messages,
            role: .generalChat,
            modelID: request.selection(for: .generalChat).modelID,
            context: RequestContext(
                selectedText: nil,
                activeAppBundleID: context.activeAppBundleID,
                activeAppName: context.activeAppName,
                memoryIDs: []
            ),
            metadata: ["responseFormat": "json"]
        )
        let events = try await provider.complete(brainRequest)
        var accumulated = ""
        var finalText: String?
        for try await event in events {
            switch event {
            case .started:
                continue
            case .textDelta(let delta):
                accumulated += delta
            case .final(let response):
                finalText = response.text
            case .cancelled:
                throw RocaError.cancelled
            }
        }
        let rawText = (finalText ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        let response = AssistantPromptCatalog.parseAssistantResponse(rawText)
        completeMessage(
            messageID,
            text: response.bubbleText,
            detailsMarkdown: response.detailsMarkdown,
            status: .streaming
        )
        return response
    }

    private func speak(
        _ text: String,
        request: AssistantSessionTurnRequest,
        timing: inout AssistantTurnTimingBuilder,
        force: Bool = false
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await finishTurn(request)
            return
        }
        guard request.outputMode != .textOnly else {
            await finishTurn(request)
            return
        }
        guard force || shouldSpeak(trimmed, outputMode: request.outputMode) else {
            await finishTurn(request)
            return
        }

        setState(.speaking)
        let baseSpeechRequest = speechRequest(text: trimmed, utteranceID: UtteranceID.make(), request: request)
        let chunkPlanStartedAt = Date()
        let chunkLimit = try await speechOrchestrator.recommendedChunkCharacterLimit(for: baseSpeechRequest)
        let chunks = chunkLimit.map { AssistantSpeechChunker.chunks(from: trimmed, maxCharacters: max(1, $0)) } ?? [trimmed]
        timing.recordTTSPreparation(from: chunkPlanStartedAt, to: Date())

        for chunk in chunks {
            if isTurnCancelled(request.turnID) {
                throw RocaError.cancelled
            }
            try Task.checkCancellation()

            let utteranceID = UtteranceID.make()
            let preparationStartedAt = Date()
            try await speechOrchestrator.speak(
                speechRequest(text: chunk, utteranceID: utteranceID, request: request)
            )
            let preparationFinishedAt = Date()
            timing.recordTTSPreparation(from: preparationStartedAt, to: preparationFinishedAt)

            try Task.checkCancellation()
            try await speechOrchestrator.waitForCompletion(of: utteranceID)
            if let utteranceMetrics = await speechOrchestrator.metrics(for: utteranceID) {
                timing.recordTTSUtteranceMetrics(utteranceMetrics)
            }
            timing.recordTTSPlayback(from: preparationFinishedAt, to: Date())
            try Task.checkCancellation()
        }
        await finishTurn(request)
    }

    private func finishTurn(_ request: AssistantSessionTurnRequest) async {
        setState(.stopped)
        await emit(.idle, message: "Ready", correlationID: request.turnID.rawValue)
    }

    private func shouldSpeak(_ text: String, outputMode: AssistantOutputMode) -> Bool {
        switch outputMode {
        case .textOnly:
            return false
        case .speakAll:
            return true
        case .speakShortResponse:
            return text.count <= 420 && text.components(separatedBy: .newlines).count <= 4
        }
    }

    private func speechRequest(
        text: String,
        utteranceID: UtteranceID,
        request: AssistantSessionTurnRequest
    ) -> SpeechRequest {
        SpeechRequest(
            utteranceID: utteranceID,
            text: text,
            providerID: request.speechConfiguration.providerID,
            voice: nil,
            providerVoiceSelections: request.speechConfiguration.providerVoiceSelections,
            format: .wav24Mono,
            speed: request.speechConfiguration.speed,
            source: .assistantResponse,
            allowFallback: request.speechConfiguration.allowFallback
        )
    }

    private func cancelActiveBrainAndSpeech() async {
        if let activeBrainRequestID {
            cancelledTurnIDs.insert(activeBrainRequestID)
            await activeBrainProvider?.cancel(activeBrainRequestID)
        }
        activeBrainProvider = nil
        activeBrainRequestID = nil
        await speechOrchestrator.stopSpeaking()
    }

    private func remember(userText: String, assistantText: String) {
        conversationMessages.append(BrainMessage(role: .user, content: userText))
        conversationMessages.append(BrainMessage(role: .assistant, content: assistantText))
        if conversationMessages.count > 10 {
            conversationMessages.removeFirst(conversationMessages.count - 10)
        }
    }

    @discardableResult
    private func appendUserMessage(_ text: String, request: AssistantSessionTurnRequest) -> ChatMessageID {
        appendMessage(
            ChatMessage(
                turnID: request.turnID,
                role: .user,
                source: request.inputMode == .voice ? .voice : .typed,
                text: text,
                status: .completed,
                metadata: turnMetadata(for: request)
            )
        )
    }

    @discardableResult
    private func appendAssistantMessage(
        _ text: String,
        status: ChatMessageStatus,
        request: AssistantSessionTurnRequest,
        directiveType: AssistantDirectiveType?,
        brainRole: BrainRole = .companionRouter
    ) -> ChatMessageID {
        appendMessage(
            ChatMessage(
                turnID: request.turnID,
                role: .assistant,
                source: .assistant,
                text: text,
                status: status,
                metadata: turnMetadata(for: request, brainRole: brainRole, directiveType: directiveType)
            )
        )
    }

    @discardableResult
    private func appendActionMessage(
        _ text: String,
        status: ChatMessageStatus,
        request: AssistantSessionTurnRequest,
        directiveType: AssistantDirectiveType?
    ) -> ChatMessageID {
        appendMessage(
            ChatMessage(
                turnID: request.turnID,
                role: .action,
                source: .localAction,
                text: text,
                status: status,
                metadata: turnMetadata(for: request, directiveType: directiveType)
            )
        )
    }

    @discardableResult
    private func appendStatus(
        _ text: String,
        status: ChatMessageStatus,
        turnID: BrainRequestID? = nil,
        request: AssistantSessionTurnRequest? = nil
    ) -> ChatMessageID {
        appendMessage(
            ChatMessage(
                turnID: request?.turnID ?? turnID,
                role: .status,
                source: .status,
                text: text,
                status: status,
                metadata: request.map { turnMetadata(for: $0) }
            )
        )
    }

    private func turnMetadata(
        for request: AssistantSessionTurnRequest,
        brainRole: BrainRole = .companionRouter,
        directiveType: AssistantDirectiveType? = nil
    ) -> ChatMessageMetadata {
        let brainSelection = request.selection(for: brainRole)
        return ChatMessageMetadata(
            inputMode: request.inputMode,
            outputMode: request.outputMode,
            brainProviderID: brainSelection.providerID,
            brainModelID: brainSelection.modelID,
            brainDisplayName: brainSelection.displayName,
            directiveType: directiveType,
            directivePromptVersion: AssistantPromptCatalog.directivePromptVersion,
            responsePromptVersion: AssistantPromptCatalog.responsePromptVersion
        )
    }

    @discardableResult
    private func appendMessage(_ message: ChatMessage) -> ChatMessageID {
        messages.append(message)
        if messages.count > 120 {
            messages.removeFirst(messages.count - 120)
        }
        publishMessages()
        return message.id
    }

    private func completeMessage(
        _ id: ChatMessageID,
        text: String,
        detailsMarkdown: String? = nil,
        status: ChatMessageStatus
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].text = text
        messages[index].detailsMarkdown = detailsMarkdown
        messages[index].status = status
        publishMessages()
    }

    private func removeMessage(_ id: ChatMessageID) {
        messages.removeAll { $0.id == id }
        publishMessages()
    }

    private func markTurnMessages(_ turnID: BrainRequestID, status: ChatMessageStatus) {
        var changed = false
        for index in messages.indices where messages[index].turnID == turnID && messages[index].status != .completed {
            messages[index].status = status
            changed = true
        }
        if changed {
            publishMessages()
        }
    }

    private func publishMessages() {
        for continuation in messageContinuations.values {
            continuation.yield(messages)
        }
    }

    private func setState(_ state: AssistantState) {
        currentState = state
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func setStateFromTask(_ state: AssistantState) {
        setState(state)
    }

    private func addStateContinuation(_ continuation: AsyncStream<AssistantState>.Continuation, id: UUID) {
        stateContinuations[id] = continuation
        continuation.yield(currentState)
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func addMessageContinuation(_ continuation: AsyncStream<[ChatMessage]>.Continuation, id: UUID) {
        messageContinuations[id] = continuation
        continuation.yield(messages)
    }

    private func removeMessageContinuation(_ id: UUID) {
        messageContinuations.removeValue(forKey: id)
    }

    private func emitMetrics(_ metrics: AssistantTurnMetrics) {
        for continuation in metricsContinuations.values {
            continuation.yield(metrics)
        }
    }

    private func addMetricsContinuation(
        _ continuation: AsyncStream<AssistantTurnMetrics>.Continuation,
        id: UUID
    ) {
        metricsContinuations[id] = continuation
    }

    private func removeMetricsContinuation(_ id: UUID) {
        metricsContinuations.removeValue(forKey: id)
    }

    private func isTurnCancelled(_ turnID: BrainRequestID) -> Bool {
        cancelledTurnIDs.contains(turnID)
    }

    private func emit(_ activity: RocaActivity, message: String, correlationID: String?) async {
        await companionState?.emit(
            CompanionStateEvent(
                activity: activity,
                message: message,
                source: .assistant,
                correlationID: correlationID,
                sensitivity: .publicStatus
            )
        )
    }

    private nonisolated static func finalBrainText(
        from events: AsyncThrowingStream<BrainEvent, Error>
    ) async throws -> String {
        var accumulated = ""
        var finalText: String?
        for try await event in events {
            switch event {
            case .started:
                continue
            case .textDelta(let delta):
                accumulated += delta
            case .final(let response):
                finalText = response.text
            case .cancelled:
                throw RocaError.cancelled
            }
        }
        return (finalText ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func brainFailurePhase(from timing: AssistantTurnTimingBuilder) -> BrainFailurePhase {
        if timing.responseBrainStartedAt != nil {
            return .response
        }
        if timing.directiveStartedAt != nil {
            return .routing
        }
        return .setup
    }

    private nonisolated static func brainRecoveryMessage(for error: Error, phase: BrainFailurePhase) -> String? {
        if isCancellation(error) {
            return nil
        }
        if case RocaError.providerTimedOut(providerID: _, modelID: let modelID) = error {
            return phase.timeoutMessage(modelID: modelID)
        }
        if case RocaError.providerUnavailable = error {
            return "I can't reach your assistant brain right now. Start Ollama or choose a different model in Settings."
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "I can't reach your assistant brain right now. Start Ollama or choose a different model in Settings."
        }

        let description = error.localizedDescription.lowercased()
        if description.contains("could not connect")
            || description.contains("cannot connect")
            || description.contains("connection was lost")
            || description.contains("server") {
            return "I can't reach your assistant brain right now. Start Ollama or choose a different model in Settings."
        }

        return nil
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if case RocaError.cancelled = error {
            return true
        }
        return false
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

    private nonisolated static func readSelectionSummary(
        for result: SelectionReadResult
    ) -> (text: String, status: ChatMessageStatus) {
        switch result {
        case .text:
            ("Reading selected text.", .completed)
        case .empty:
            ("No selected text found.", .failed)
        case .permissionDenied:
            ("Accessibility permission is needed before I can read selected text.", .failed)
        case .failed(let message):
            (message, .failed)
        }
    }
}

private struct ActiveAssistantSessionListeningSession: Sendable {
    var request: AssistantSessionTurnRequest
    var provider: any STTProvider
    var transcriptTask: Task<String, Error>
    var timing: AssistantTurnTimingBuilder
    var listeningMessageID: ChatMessageID
}

private extension AssistantDirective {
    var metricType: AssistantDirectiveType {
        switch self {
        case .respond:
            .respond
        case .openApplication:
            .openApplication
        case .quitApplication:
            .quitApplication
        case .insertText:
            .insertText
        case .readSelection:
            .readSelection
        case .unsupported:
            .unsupported
        }
    }
}
