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
    private let projectCatalog: (any ProjectIdentityCatalog)?
    private let projectWriter: (any ProjectIdentityWriting)?
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
    private var activeAgentProvider: (any AgentProvider)?
    private var activeAgentRunID: AgentRunID?
    private var cancelledTurnIDs: Set<BrainRequestID> = []
    private var conversationMessages: [BrainMessage] = []
    private var stateContinuations: [UUID: AsyncStream<AssistantState>.Continuation] = [:]
    private var messageContinuations: [UUID: AsyncStream<[ChatMessage]>.Continuation] = [:]
    private var metricsContinuations: [UUID: AsyncStream<AssistantTurnMetrics>.Continuation] = [:]
    private var diagnosticsContinuations: [UUID: AsyncStream<AssistantDiagnosticEvent>.Continuation] = [:]
    private var approvalContinuations: [ChatMessageID: CheckedContinuation<AgentApprovalDecision, Never>] = [:]

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

    public nonisolated var diagnosticUpdates: AsyncStream<AssistantDiagnosticEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.addDiagnosticsContinuation(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeDiagnosticsContinuation(id)
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
        projectCatalog: (any ProjectIdentityCatalog)? = nil,
        projectWriter: (any ProjectIdentityWriting)? = nil,
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
        self.projectCatalog = projectCatalog
        self.projectWriter = projectWriter ?? (projectCatalog as? any ProjectIdentityWriting)
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
            emitDiagnostic(
                kind: .turnBlocked,
                turnID: request.turnID,
                phase: "submit",
                metadata: diagnosticMetadata(for: request)
            )
            appendStatus("Still finishing the current turn. Try again in a moment.", status: .failed, request: request)
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
            await cancel()
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
            recordTurnCancellation(session.request.turnID)
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
            recordTurnCancellation(activeTurnID)
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

    public func requestAgentApprovalDecision(for prompt: AgentApprovalPrompt) async -> AgentApprovalDecision {
        let messageID = appendAgentApprovalMessage(prompt)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalContinuations[messageID] = continuation
            }
        } onCancel: {
            Task {
                await self.submitAgentApprovalDecision(messageID, decision: .cancel)
            }
        }
    }

    public func submitAgentApprovalDecision(_ messageID: ChatMessageID, decision: AgentApprovalDecision) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var approval = messages[index].approvalRequest,
              approval.decision == nil
        else {
            return
        }

        approval.decision = decision
        approval.decidedAt = Date()
        messages[index].approvalRequest = approval
        messages[index].text = Self.agentApprovalDecisionText(decision)
        messages[index].status = Self.agentApprovalMessageStatus(decision)
        publishMessages()

        approvalContinuations.removeValue(forKey: messageID)?.resume(returning: decision)
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
        emitDiagnostic(
            kind: .turnStarted,
            turnID: request.turnID,
            phase: "start",
            metadata: diagnosticMetadata(for: request)
        )
        defer {
            if activeTurnID == request.turnID {
                activeTurnID = nil
            }
            activeBrainProvider = nil
            activeBrainRequestID = nil
            activeAgentProvider = nil
            activeAgentRunID = nil
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
            emitDiagnostic(
                kind: .directiveResolved,
                turnID: request.turnID,
                phase: "routing",
                directiveType: directive.metricType,
                metadata: diagnosticMetadata(for: request)
            )
            try Task.checkCancellation()
            try checkTurnStillActive(request.turnID)
            try await handleDirective(
                directive,
                input: input,
                request: request,
                context: context,
                provider: brainProvider,
                timing: &timing
            )
            try Task.checkCancellation()
            try checkTurnStillActive(request.turnID)
            emitDiagnostic(
                kind: .turnCompleted,
                turnID: request.turnID,
                phase: "finish",
                directiveType: timing.directiveType,
                outcome: AssistantTurnOutcome.completed.rawValue,
                metadata: diagnosticMetadata(for: request)
            )
            emitMetrics(timing.snapshot(outcome: .completed))
        } catch {
            if Self.isCancellation(error) || isTurnCancelled(request.turnID) {
                setState(.stopped)
                await emit(.interrupted, message: "Assistant cancelled.", correlationID: request.turnID.rawValue)
                markTurnMessages(request.turnID, status: .cancelled)
                emitDiagnostic(
                    kind: .turnCancelled,
                    turnID: request.turnID,
                    phase: "cancel",
                    directiveType: timing.directiveType,
                    outcome: AssistantTurnOutcome.cancelled.rawValue,
                    metadata: diagnosticMetadata(for: request)
                )
                emitMetrics(timing.snapshot(outcome: .cancelled))
                return
            }

            let failurePhase = Self.brainFailurePhase(from: timing)
            let recoveryMessage = Self.brainRecoveryMessage(for: error, phase: failurePhase)
            let message = recoveryMessage ?? error.localizedDescription
            appendStatus(message, status: .failed, request: request)
            setState(.failed(message))
            await emit(.offline(reason: message), message: message, correlationID: request.turnID.rawValue)
            emitDiagnostic(
                kind: .turnFailed,
                turnID: request.turnID,
                phase: String(describing: failurePhase),
                directiveType: timing.directiveType,
                outcome: AssistantTurnOutcome.failed.rawValue,
                metadata: diagnosticMetadata(for: request, error: error)
            )
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
            messages: directiveMessages(input: input, context: context),
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

    private func directiveMessages(input: String, context: AssistantLocalContext) -> [BrainMessage] {
        var messages = [BrainMessage(role: .system, content: AssistantPromptCatalog.directiveSystemPrompt)]
        messages.append(contentsOf: conversationMessages)
        messages.append(
            BrainMessage(
                role: .user,
                content: AssistantPromptCatalog.directiveUserPrompt(input: input, context: context)
            )
        )
        return messages
    }

    private func handleDirective(
        _ directive: AssistantDirective,
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        provider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder
    ) async throws {
        try checkTurnStillActive(request.turnID)
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
            try checkTurnStillActive(request.turnID)
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
            try checkTurnStillActive(request.turnID)
            completeMessage(actionID, text: result.spokenSummary, status: .completed)
            try await speak(result.spokenSummary, request: request, timing: &timing, force: request.inputMode == .voice)
        case .quitApplication(let target):
            setState(.acting("Quitting \(target.displayName)"))
            let actionID = appendActionMessage("Quitting \(target.displayName)...", status: .pending, request: request, directiveType: directive.metricType)
            timing.actionStartedAt = Date()
            let result = await applicationCommands.execute(.quit(target))
            timing.actionFinishedAt = Date()
            try checkTurnStillActive(request.turnID)
            completeMessage(actionID, text: result.spokenSummary, status: .completed)
            try await speak(result.spokenSummary, request: request, timing: &timing, force: request.inputMode == .voice)
        case .insertText(let text):
            setState(.acting("Inserting text"))
            let actionID = appendActionMessage("Inserting text...", status: .pending, request: request, directiveType: directive.metricType)
            do {
                timing.actionStartedAt = Date()
                try await inserter.insertIntoFocusedApp(text)
                timing.actionFinishedAt = Date()
                try checkTurnStillActive(request.turnID)
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
            try checkTurnStillActive(request.turnID)
            let summary = Self.readSelectionSummary(for: result)
            completeMessage(actionID, text: summary.text, status: summary.status)
            if summary.status == .failed, request.inputMode == .voice {
                try await speak(summary.text, request: request, timing: &timing, force: true)
            } else {
                setState(.stopped)
            }
        case .runAgent(let agentRequest):
            try await handleAgentDirective(
                agentRequest,
                input: input,
                request: request,
                context: context,
                brainProvider: provider,
                timing: &timing
            )
        case .unsupported(let message):
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: directive.metricType)
            completeMessage(id, text: message, status: .completed)
            try await speak(message, request: request, timing: &timing)
        }
    }

    private func handleAgentDirective(
        _ directive: AgentDirectiveRequest,
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        brainProvider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder
    ) async throws {
        try checkTurnStillActive(request.turnID)
        let providerName = directive.providerDisplayName
        if directive.mode != .ask, directive.projectName == nil {
            let message = "Which project should \(providerName) use?"
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
            completeMessage(id, text: message, status: .completed)
            try await speak(message, request: request, timing: &timing)
            return
        }

        guard let providerID = directive.resolvedProviderID else {
            let message = "I don't know which agent provider to use yet."
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
            completeMessage(id, text: message, status: .completed)
            try await speak(message, request: request, timing: &timing)
            return
        }

        let provider: any AgentProvider
        do {
            provider = try await resolver.agentProvider(id: providerID)
            try checkTurnStillActive(request.turnID)
        } catch {
            if Self.isCancellation(error) || isTurnCancelled(request.turnID) {
                throw RocaError.cancelled
            }
            let message = "I couldn't start \(providerName): \(error.localizedDescription)"
            let id = appendAssistantMessage(message, status: .failed, request: request, directiveType: .runAgent)
            completeMessage(id, text: message, status: .failed)
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
            return
        }

        let resolvedProject = try await resolveProject(
            for: directive,
            providerName: providerName,
            provider: provider,
            request: request,
            timing: &timing
        )
        try Task.checkCancellation()
        try checkTurnStillActive(request.turnID)
        guard resolvedProject.shouldContinue else {
            return
        }

        let intro = Self.agentIntroText(providerName: providerName, project: resolvedProject.project)
        let introID = appendAssistantMessage(intro, status: .completed, request: request, directiveType: .runAgent)
        completeMessage(introID, text: intro, status: .completed)

        setState(.acting("Interacting with \(providerName)"))
        let actionID = appendActionMessage("Interacting with \(providerName)...", status: .streaming, request: request, directiveType: .runAgent)
        timing.actionStartedAt = Date()
        do {
            let runID = AgentRunID.make()
            activeAgentProvider = provider
            activeAgentRunID = runID
            let agentRunRequest = AgentRunRequest(
                runID: runID,
                prompt: directive.prompt,
                mode: directive.mode,
                role: .coding,
                workspacePath: resolvedProject.project?.localPath,
                dataScopes: [.prompt],
                actionScopes: [],
                metadata: resolvedProject.project.map { ["projectID": $0.id.rawValue, "projectName": $0.displayName] } ?? [:]
            )
            emitDiagnostic(
                kind: .agentRunStarted,
                turnID: request.turnID,
                phase: "agentRun",
                providerID: providerID,
                directiveType: .runAgent,
                metadata: diagnosticMetadata(
                    for: request,
                    extra: [
                        "agentMode": directive.mode.rawValue,
                        "workspaceResolved": resolvedProject.project == nil ? "false" : "true"
                    ]
                )
            )
            let events = try await provider.start(agentRunRequest)
            var accumulatedText = ""
            var finalText: String?
            var didFinish = false
            var wasCancelled = false
            for try await event in events {
                try Task.checkCancellation()
                try checkTurnStillActive(request.turnID)
                switch event {
                case .started:
                    continue
                case .status:
                    continue
                case .textDelta(let delta):
                    accumulatedText += delta
                case .toolActivity:
                    continue
                case .approvalRequired:
                    completeMessage(actionID, text: "Waiting for approval.", status: .streaming)
                case .final(let response):
                    finalText = response.text
                    didFinish = true
                case .cancelled:
                    completeMessage(actionID, text: "\(providerName) cancelled.", status: .cancelled)
                    rememberAssistantObservation("\(providerName) was cancelled.")
                    wasCancelled = true
                }
            }
            try Task.checkCancellation()
            try checkTurnStillActive(request.turnID)
            if wasCancelled {
                timing.actionFinishedAt = Date()
                throw RocaError.cancelled
            }
            let rawAgentText = (finalText ?? accumulatedText).trimmingCharacters(in: .whitespacesAndNewlines)
            completeMessage(actionID, text: "\(providerName) finished.", status: .completed)
            timing.actionFinishedAt = Date()
            let assistantMessageID = appendAssistantMessage(
                "",
                status: .streaming,
                request: request,
                directiveType: .runAgent,
                brainRole: .generalChat
            )
            let response: AssistantResponseContent
            if rawAgentText.isEmpty {
                response = AssistantResponseContent(
                    bubbleText: "\(providerName) finished, but I didn't get any details back.",
                    detailsMarkdown: nil
                )
                completeMessage(assistantMessageID, text: response.bubbleText, status: .completed)
            } else {
                timing.responseBrainStartedAt = Date()
                do {
                    response = try await completeAssistantResponse(
                        input: Self.agentResultFormattingPrompt(
                            userInput: input,
                            providerName: providerName,
                            project: resolvedProject.project,
                            rawAgentText: rawAgentText
                        ),
                        request: request,
                        context: context,
                        provider: brainProvider,
                        messageID: assistantMessageID
                    )
                    timing.responseBrainFinishedAt = Date()
                } catch {
                    timing.responseBrainFinishedAt = Date()
                    if Self.isCancellation(error) {
                        throw error
                    }
                    response = Self.fallbackAgentResponse(providerName: providerName, rawAgentText: rawAgentText)
                    emitDiagnostic(
                        kind: .agentProviderDiagnostic,
                        turnID: request.turnID,
                        phase: "agentResultFormatting",
                        providerID: providerID,
                        directiveType: .runAgent,
                        outcome: "fallback",
                        metadata: diagnosticMetadata(for: request, error: error)
                    )
                }
                try checkTurnStillActive(request.turnID)
                completeMessage(
                    assistantMessageID,
                    text: response.bubbleText,
                    detailsMarkdown: response.detailsMarkdown,
                    status: .completed
                )
            }
            remember(userText: input, assistantText: response.conversationText)
            try await speak(response.bubbleText, request: request, timing: &timing)
            emitDiagnostic(
                kind: .agentRunCompleted,
                turnID: request.turnID,
                phase: "agentRun",
                providerID: providerID,
                directiveType: .runAgent,
                outcome: AssistantTurnOutcome.completed.rawValue,
                metadata: diagnosticMetadata(
                    for: request,
                    extra: [
                        "agentMode": directive.mode.rawValue,
                        "agentDidFinish": String(didFinish)
                    ]
                )
            )
        } catch RocaError.approvalRequired(let detail) {
            timing.actionFinishedAt = Date()
            let message = "I need approval before I hand this to \(providerName): \(detail)"
            completeMessage(actionID, text: message, status: .failed)
            rememberAssistantObservation(message)
            emitDiagnostic(
                kind: .agentRunFailed,
                turnID: request.turnID,
                phase: "approval",
                providerID: providerID,
                directiveType: .runAgent,
                outcome: AssistantTurnOutcome.failed.rawValue,
                metadata: diagnosticMetadata(for: request, error: RocaError.approvalRequired(detail))
            )
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
        } catch {
            timing.actionFinishedAt = Date()
            if Self.isCancellation(error) {
                throw error
            }
            let message = "I couldn't finish that with \(providerName): \(error.localizedDescription)"
            completeMessage(actionID, text: message, status: .failed)
            rememberAssistantObservation(message)
            emitDiagnostic(
                kind: .agentRunFailed,
                turnID: request.turnID,
                phase: "agentRun",
                providerID: providerID,
                directiveType: .runAgent,
                outcome: AssistantTurnOutcome.failed.rawValue,
                metadata: diagnosticMetadata(for: request, error: error)
            )
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
        }
    }

    private func resolveProject(
        for directive: AgentDirectiveRequest,
        providerName: String,
        provider: any AgentProvider,
        request: AssistantSessionTurnRequest,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> (project: ProjectIdentity?, shouldContinue: Bool) {
        guard let projectName = directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectName.isEmpty
        else {
            return (nil, true)
        }

        let projects = try await projectCatalog?.projects() ?? []
        try checkTurnStillActive(request.turnID)
        switch ProjectIdentityResolver(projects: projects).resolve(projectName) {
        case .resolved(let project):
            return (project, true)
        case .ambiguous(_, let candidates):
            let names = candidates.map(\.displayName).joined(separator: ", ")
            let message = "Which project do you mean: \(names)?"
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
            completeMessage(id, text: message, status: .completed)
            rememberAssistantObservation(message)
            try await speak(message, request: request, timing: &timing)
            return (nil, false)
        case .missing:
            if let discoverer = provider as? any AgentProjectDiscovering {
                let lookupID = appendActionMessage("Looking for \(projectName) in \(providerName)...", status: .pending, request: request, directiveType: .runAgent)
                emitDiagnostic(
                    kind: .agentProjectLookupStarted,
                    turnID: request.turnID,
                    phase: "projectLookup",
                    providerID: directive.resolvedProviderID,
                    directiveType: .runAgent,
                    metadata: diagnosticMetadata(for: request, extra: ["projectQueryPresent": "true"])
                )
                do {
                    let candidates = try await discoverer.discoverProjects(
                        matching: ProjectDiscoveryQuery(projectName: projectName, prompt: directive.prompt)
                    )
                    try checkTurnStillActive(request.turnID)
                    switch Self.discoveryResolution(for: candidates, query: projectName) {
                    case .resolved(let project):
                        try? await projectWriter?.upsert(project)
                        try checkTurnStillActive(request.turnID)
                        completeMessage(lookupID, text: "Found \(project.displayName).", status: .completed)
                        rememberAssistantObservation("Found \(project.displayName) in \(providerName).")
                        emitDiagnostic(
                            kind: .agentProjectLookupCompleted,
                            turnID: request.turnID,
                            phase: "projectLookup",
                            providerID: directive.resolvedProviderID,
                            directiveType: .runAgent,
                            outcome: "resolved",
                            metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(candidates.count)])
                        )
                        return (project, true)
                    case .ambiguous(_, let candidates):
                        completeMessage(lookupID, text: "Found multiple project matches.", status: .completed)
                        let names = candidates.map(\.displayName).joined(separator: ", ")
                        let message = "Which project do you mean: \(names)?"
                        let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
                        completeMessage(id, text: message, status: .completed)
                        rememberAssistantObservation(message)
                        emitDiagnostic(
                            kind: .agentProjectLookupCompleted,
                            turnID: request.turnID,
                            phase: "projectLookup",
                            providerID: directive.resolvedProviderID,
                            directiveType: .runAgent,
                            outcome: "ambiguous",
                            metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(candidates.count)])
                        )
                        try await speak(message, request: request, timing: &timing)
                        return (nil, false)
                    case .missing:
                        completeMessage(lookupID, text: "No \(providerName) project match found.", status: .completed)
                        emitDiagnostic(
                            kind: .agentProjectLookupCompleted,
                            turnID: request.turnID,
                            phase: "projectLookup",
                            providerID: directive.resolvedProviderID,
                            directiveType: .runAgent,
                            outcome: "missing",
                            metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(candidates.count)])
                        )
                        break
                    }
                } catch {
                    completeMessage(lookupID, text: "\(providerName) project lookup failed.", status: .failed)
                    emitDiagnostic(
                        kind: .agentProjectLookupFailed,
                        turnID: request.turnID,
                        phase: "projectLookup",
                        providerID: directive.resolvedProviderID,
                        directiveType: .runAgent,
                        outcome: AssistantTurnOutcome.failed.rawValue,
                        metadata: diagnosticMetadata(for: request, error: error, extra: ["projectQueryPresent": "true"])
                    )
                    // Discovery is a convenience fallback. If it fails, ask for the folder.
                    let message = "I couldn't read \(providerName)'s project list in time, so I don't know the \(projectName) project folder yet. Please give me the local folder or try again."
                    let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
                    completeMessage(id, text: message, status: .completed)
                    rememberAssistantObservation(message)
                    try await speak(message, request: request, timing: &timing)
                    return (nil, false)
                }
            }
            let message = "I don't know the \(projectName) project folder yet. Please give me the local folder before I hand this to \(providerName)."
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
            completeMessage(id, text: message, status: .completed)
            rememberAssistantObservation(message)
            try await speak(message, request: request, timing: &timing)
            return (nil, false)
        }
    }

    private static func discoveryResolution(
        for candidates: [ProjectDiscoveryCandidate],
        query: String
    ) -> ProjectResolution {
        let usable = candidates
            .filter { $0.confidence != .low }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.project.displayName.localizedCaseInsensitiveCompare($1.project.displayName) == .orderedAscending
            }
        guard let best = usable.first else {
            return .missing(query: query)
        }
        if let runnerUp = usable.dropFirst().first, best.score - runnerUp.score < 25 {
            return .ambiguous(query: query, candidates: uniqueProjects(usable.map(\.project)))
        }
        return .resolved(best.project)
    }

    private static func uniqueProjects(_ projects: [ProjectIdentity]) -> [ProjectIdentity] {
        var seen = Set<String>()
        return projects
            .filter { seen.insert(ProjectIdentityResolver.normalizedKey($0.localPath)).inserted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
            try Task.checkCancellation()
            try checkTurnStillActive(request.turnID)
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
            try Task.checkCancellation()
            try checkTurnStillActive(request.turnID)

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
        if let activeAgentRunID {
            await activeAgentProvider?.cancel(activeAgentRunID)
        }
        activeBrainProvider = nil
        activeBrainRequestID = nil
        activeAgentProvider = nil
        activeAgentRunID = nil
        await speechOrchestrator.stopSpeaking()
    }

    private func remember(userText: String, assistantText: String) {
        conversationMessages.append(BrainMessage(role: .user, content: userText))
        conversationMessages.append(BrainMessage(role: .assistant, content: assistantText))
        trimConversationMessages()
    }

    private func rememberAssistantObservation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        conversationMessages.append(BrainMessage(role: .assistant, content: "Roca action/status: \(trimmed)"))
        trimConversationMessages()
    }

    private func trimConversationMessages() {
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
    private func appendAgentApprovalMessage(_ prompt: AgentApprovalPrompt) -> ChatMessageID {
        let messageID = ChatMessageID.make()
        return appendMessage(
            ChatMessage(
                id: messageID,
                turnID: activeTurnID,
                role: .action,
                source: .localAction,
                text: prompt.title,
                approvalRequest: ChatApprovalRequest(
                    id: messageID,
                    title: prompt.title,
                    detail: prompt.detail,
                    requirement: prompt.requirement
                ),
                status: .pending
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

    private func emitDiagnostic(
        kind: AssistantDiagnosticEventKind,
        turnID: BrainRequestID?,
        phase: String? = nil,
        providerID: ProviderID? = nil,
        modelID: String? = nil,
        directiveType: AssistantDirectiveType? = nil,
        outcome: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let event = AssistantDiagnosticEvent(
            turnID: turnID,
            kind: kind,
            phase: phase,
            providerID: providerID,
            modelID: modelID,
            directiveType: directiveType,
            outcome: outcome,
            metadata: metadata
        )
        for continuation in diagnosticsContinuations.values {
            continuation.yield(event)
        }
    }

    private func recordTurnCancellation(_ turnID: BrainRequestID) {
        cancelledTurnIDs.insert(turnID)
        if activeTurnID == turnID {
            activeTurnID = nil
        }
        if !messages.contains(where: { $0.turnID == turnID && $0.text == "Assistant cancelled." && $0.status == .cancelled }) {
            appendStatus("Assistant cancelled.", status: .cancelled, turnID: turnID)
        }
        markTurnMessages(turnID, status: .cancelled)
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

    private func addDiagnosticsContinuation(
        _ continuation: AsyncStream<AssistantDiagnosticEvent>.Continuation,
        id: UUID
    ) {
        diagnosticsContinuations[id] = continuation
    }

    private func removeDiagnosticsContinuation(_ id: UUID) {
        diagnosticsContinuations.removeValue(forKey: id)
    }

    private func isTurnCancelled(_ turnID: BrainRequestID) -> Bool {
        cancelledTurnIDs.contains(turnID)
    }

    private func checkTurnStillActive(_ turnID: BrainRequestID) throws {
        if isTurnCancelled(turnID) {
            throw RocaError.cancelled
        }
    }

    private func diagnosticMetadata(
        for request: AssistantSessionTurnRequest,
        error: Error? = nil,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var metadata = extra
        metadata["inputMode"] = request.inputMode.rawValue
        metadata["outputMode"] = request.outputMode.rawValue
        let routerSelection = request.selection(for: .companionRouter)
        metadata["routerProviderID"] = routerSelection.providerID.rawValue
        if let modelID = routerSelection.modelID {
            metadata["routerModelID"] = modelID
        }
        let chatSelection = request.selection(for: .generalChat)
        metadata["chatProviderID"] = chatSelection.providerID.rawValue
        if let modelID = chatSelection.modelID {
            metadata["chatModelID"] = modelID
        }
        if let error {
            metadata["errorType"] = Self.diagnosticErrorType(error)
        }
        return metadata
    }

    private nonisolated static func diagnosticErrorType(_ error: Error) -> String {
        if isCancellation(error) {
            return "cancelled"
        }
        if case RocaError.providerTimedOut = error {
            return "providerTimedOut"
        }
        if case RocaError.providerUnavailable = error {
            return "providerUnavailable"
        }
        if case RocaError.approvalRequired = error {
            return "approvalRequired"
        }
        if case RocaError.approvalDenied = error {
            return "approvalDenied"
        }
        return String(describing: type(of: error))
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

    private nonisolated static func agentApprovalDecisionText(_ decision: AgentApprovalDecision) -> String {
        switch decision {
        case .approve:
            "Approved once."
        case .approveForSession:
            "Remembered approval."
        case .deny:
            "Denied."
        case .cancel:
            "Cancelled."
        }
    }

    private nonisolated static func agentApprovalMessageStatus(_ decision: AgentApprovalDecision) -> ChatMessageStatus {
        switch decision {
        case .approve, .approveForSession:
            .completed
        case .deny:
            .failed
        case .cancel:
            .cancelled
        }
    }

    private nonisolated static func agentIntroText(providerName: String, project: ProjectIdentity?) -> String {
        if let project {
            return "I'll ask \(providerName) to inspect \(project.displayName) and summarize what it finds."
        }
        return "I'll ask \(providerName) and summarize what it finds."
    }

    private nonisolated static func agentResultFormattingPrompt(
        userInput: String,
        providerName: String,
        project: ProjectIdentity?,
        rawAgentText: String
    ) -> String {
        let projectText = project.map { "\($0.displayName) at \($0.localPath)" } ?? "No specific project"
        return """
        The user asked Roca to use \(providerName).

        User request:
        \(userInput)

        Project:
        \(projectText)

        \(providerName)'s raw result:
        \(rawAgentText)

        Return Roca's final response as JSON using the required bubbleText/detailsMarkdown shape.
        Keep bubbleText short, conversational, and suitable for speech.
        Put tables, endpoints, long lists, and implementation details in detailsMarkdown.
        Do not include raw tool progress, shell commands, or narration about how \(providerName) searched unless it is essential to the answer.
        """
    }

    private nonisolated static func fallbackAgentResponse(
        providerName: String,
        rawAgentText: String
    ) -> AssistantResponseContent {
        let parsed = AssistantPromptCatalog.parseAssistantResponse(rawAgentText)
        guard parsed.detailsMarkdown != nil else {
            return parsed
        }
        return AssistantResponseContent(
            bubbleText: "\(providerName) finished. I put the details below.",
            detailsMarkdown: parsed.detailsMarkdown
        )
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
        case .runAgent:
            .runAgent
        case .unsupported:
            .unsupported
        }
    }
}
