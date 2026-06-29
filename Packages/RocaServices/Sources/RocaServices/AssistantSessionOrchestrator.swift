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
    private let workspaceResolver: WorkspaceResolutionService
    private let localSkillWorkers: [SkillID: any LocalSkillWorking]
    private let taskLedger: any AssistantTaskLedger
    private let readSelectionCommand: ReadSelectionCommand?
    private let providerSetupInstaller: any ProviderSetupInstalling
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
    private var activeAssistantTaskID: AssistantTaskID?
    private var cancelledTurnIDs: Set<BrainRequestID> = []
    private var conversationMessages: [BrainMessage] = []
    private var lastContextPacket: AssistantContextPacket?
    private var pendingProjectClarification: PendingProjectClarification?
    private var pendingDirectiveRetry: PendingDirectiveRetry?
    private var stateContinuations: [UUID: AsyncStream<AssistantState>.Continuation] = [:]
    private var messageContinuations: [UUID: AsyncStream<[ChatMessage]>.Continuation] = [:]
    private var metricsContinuations: [UUID: AsyncStream<AssistantTurnMetrics>.Continuation] = [:]
    private var diagnosticsContinuations: [UUID: AsyncStream<AssistantDiagnosticEvent>.Continuation] = [:]
    private var approvalContinuations: [ChatMessageID: CheckedContinuation<AgentApprovalDecision, Never>] = [:]
    private var questionContinuations: [ChatMessageID: CheckedContinuation<AgentQuestionResponse, Never>] = [:]

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
        localSkillWorkers: [any LocalSkillWorking] = [CodebaseSkillWorker()],
        taskLedger: any AssistantTaskLedger = InMemoryAssistantTaskLedger(),
        readSelectionCommand: ReadSelectionCommand? = nil,
        providerSetupInstaller: any ProviderSetupInstalling = DefaultProviderSetupInstaller(),
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
        let resolvedProjectWriter = projectWriter ?? (projectCatalog as? any ProjectIdentityWriting)
        self.workspaceResolver = WorkspaceResolutionService(catalog: projectCatalog, writer: resolvedProjectWriter)
        self.localSkillWorkers = Dictionary(uniqueKeysWithValues: localSkillWorkers.map { ($0.skillID, $0) })
        self.taskLedger = taskLedger
        self.readSelectionCommand = readSelectionCommand
        self.providerSetupInstaller = providerSetupInstaller
        self.companionState = companionState
        self.stopSpeech = stopSpeech
    }

    public func taskSnapshot() async -> [AssistantTaskRecord] {
        await taskLedger.tasks()
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
        cancelPendingQuestions()
        await cancelActiveBrainAndSpeech()
        setState(.stopped)
        await emit(.interrupted, message: "Assistant cancelled.", correlationID: nil)
    }

    public func clearConversation() async {
        messages = [
            ChatMessage(
                role: .status,
                source: .status,
                text: "Conversation cleared.",
                status: .completed
            )
        ]
        conversationMessages = []
        lastContextPacket = nil
        pendingProjectClarification = nil
        await taskLedger.clear()
        publishMessages()
    }

    public func postStatus(_ text: String, status: ChatMessageStatus = .completed) {
        appendStatus(text, status: status)
    }

    public func requestAgentApprovalDecision(
        for prompt: AgentApprovalPrompt,
        allowsRememberedApproval: Bool = true
    ) async -> AgentApprovalDecision {
        let messageID = appendAgentApprovalMessage(prompt, allowsRememberedApproval: allowsRememberedApproval)
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

    public func submitAgentApprovalDecision(_ messageID: ChatMessageID, decision: AgentApprovalDecision) async {
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

        if let activeAssistantTaskID {
            await recordTaskEvent(
                activeAssistantTaskID,
                kind: decision == .cancel || decision == .deny ? .failed : .approvalResolved,
                status: decision == .cancel || decision == .deny ? .failed : .running,
                turnID: activeTurnID,
                phase: "approval",
                summary: Self.agentApprovalDecisionText(decision)
            ) { task in
                task.approvalDecision = decision
                if decision == .cancel || decision == .deny {
                    task.failurePhase = "approval"
                    task.failureMessage = Self.agentApprovalDecisionText(decision)
                }
            }
        }

        approvalContinuations.removeValue(forKey: messageID)?.resume(returning: decision)
    }

    public func requestAgentQuestionAnswer(for prompt: AgentQuestionPrompt) async -> AgentQuestionResponse {
        let messageID = appendAgentQuestionMessage(prompt)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                questionContinuations[messageID] = continuation
            }
        } onCancel: {
            Task {
                await self.submitAgentQuestionResponse(messageID, response: .cancelled)
            }
        }
    }

    public func submitAgentQuestionResponse(_ messageID: ChatMessageID, response: AgentQuestionResponse) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var question = messages[index].questionRequest,
              question.response == nil
        else {
            return
        }

        question.response = response
        question.answeredAt = Date()
        messages[index].questionRequest = question
        messages[index].text = response.isCancelled ? "Cancelled." : "Answered."
        messages[index].status = response.isCancelled ? .cancelled : .completed
        publishMessages()

        if let activeAssistantTaskID {
            await recordTaskEvent(
                activeAssistantTaskID,
                kind: response.isCancelled ? .cancelled : .clarificationResolved,
                status: response.isCancelled ? .cancelled : .running,
                turnID: activeTurnID,
                phase: "agentQuestion",
                summary: response.isCancelled ? "Question cancelled." : "Question answered."
            )
        }

        questionContinuations.removeValue(forKey: messageID)?.resume(returning: response)
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
            if try await handleLocalProviderSetupInstallIfNeeded(input: input, request: request, timing: &timing) {
                emitDiagnostic(
                    kind: .turnCompleted,
                    turnID: request.turnID,
                    phase: "finish",
                    directiveType: timing.directiveType,
                    outcome: AssistantTurnOutcome.completed.rawValue,
                    metadata: diagnosticMetadata(for: request)
                )
                emitMetrics(timing.snapshot(outcome: .completed))
                return
            }

            if let setupResponse = Self.localProviderSetupHelpResponse(for: input) {
                timing.directiveStartedAt = Date()
                timing.directiveFinishedAt = Date()
                timing.directiveType = .respond
                emitDiagnostic(
                    kind: .directiveResolved,
                    turnID: request.turnID,
                    phase: "routing",
                    directiveType: .respond,
                    metadata: diagnosticMetadata(for: request)
                )
                let messageID = appendAssistantMessage(
                    "",
                    status: .streaming,
                    request: request,
                    directiveType: .respond,
                    brainRole: .generalChat
                )
                completeMessage(
                    messageID,
                    text: setupResponse.bubbleText,
                    detailsMarkdown: setupResponse.detailsMarkdown,
                    status: .completed
                )
                remember(userText: input, assistantText: setupResponse.conversationText)
                try await speak(setupResponse.bubbleText, request: request, timing: &timing)
                emitDiagnostic(
                    kind: .turnCompleted,
                    turnID: request.turnID,
                    phase: "finish",
                    directiveType: .respond,
                    outcome: AssistantTurnOutcome.completed.rawValue,
                    metadata: diagnosticMetadata(for: request)
                )
                emitMetrics(timing.snapshot(outcome: .completed))
                return
            }

            let context = await contextProvider.currentContext()
            let brainProvider = try await resolver.brainProvider(id: request.selection(for: .companionRouter).providerID)
            activeBrainProvider = brainProvider
            activeBrainRequestID = request.turnID

            timing.directiveStartedAt = Date()
            if try await handlePendingDirectiveRetryIfNeeded(
                input: input,
                request: request,
                context: context,
                brainProvider: brainProvider,
                timing: &timing
            ) {
                if timing.directiveFinishedAt == nil {
                    timing.directiveFinishedAt = Date()
                }
                emitDiagnostic(
                    kind: .turnCompleted,
                    turnID: request.turnID,
                    phase: "finish",
                    directiveType: timing.directiveType,
                    outcome: AssistantTurnOutcome.completed.rawValue,
                    metadata: diagnosticMetadata(for: request)
                )
                emitMetrics(timing.snapshot(outcome: .completed))
                return
            }
            if try await handlePendingProjectClarificationIfNeeded(
                input: input,
                request: request,
                context: context,
                brainProvider: brainProvider,
                timing: &timing
            ) {
                if timing.directiveFinishedAt == nil {
                    timing.directiveFinishedAt = Date()
                }
                emitDiagnostic(
                    kind: .turnCompleted,
                    turnID: request.turnID,
                    phase: "finish",
                    directiveType: timing.directiveType,
                    outcome: AssistantTurnOutcome.completed.rawValue,
                    metadata: diagnosticMetadata(for: request)
                )
                emitMetrics(timing.snapshot(outcome: .completed))
                return
            }
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
            if !completeUnfinishedAssistantMessages(turnID: request.turnID, text: message, status: .failed) {
                appendStatus(message, status: .failed, request: request)
            }
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
        if Self.shouldAnswerFromConversation(input) {
            return .respond
        }
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
        do {
            let directive = try AssistantPromptCatalog.parseDirective(response)
            return recoveredLocalSkillFollowUpDirective(from: directive, input: input)
        } catch {
            if let repaired = Self.repairedDirective(from: response) {
                return recoveredLocalSkillFollowUpDirective(from: repaired, input: input)
            }
            throw AssistantRoutingRecoveryError()
        }
    }

    private func handleLocalProviderSetupInstallIfNeeded(
        input: String,
        request: AssistantSessionTurnRequest,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> Bool {
        guard Self.isClaudeCodeInstallRequest(input, recentMessages: conversationMessages) else {
            return false
        }

        timing.directiveStartedAt = Date()
        timing.directiveFinishedAt = Date()
        timing.directiveType = .respond
        emitDiagnostic(
            kind: .directiveResolved,
            turnID: request.turnID,
            phase: "routing",
            directiveType: .respond,
            metadata: diagnosticMetadata(for: request)
        )

        let providerID = ProviderID(rawValue: "claude-code")
        let status: AgentProviderSetupStatus
        do {
            _ = try await resolver.agentProvider(id: providerID)
            let message = "Claude Code is already installed."
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .respond)
            completeMessage(id, text: message, status: .completed)
            remember(userText: input, assistantText: message)
            try await speak(message, request: request, timing: &timing)
            return true
        } catch RocaError.agentProviderSetupRequired(let setupStatus) {
            status = setupStatus
        } catch {
            let message = "I couldn't check Claude Code setup: \(error.localizedDescription)"
            let id = appendAssistantMessage(message, status: .failed, request: request, directiveType: .respond)
            completeMessage(id, text: message, status: .failed)
            rememberAssistantObservation(message)
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
            return true
        }

        guard status.providerID.rawValue == "claude-code",
              status.state == .runtimeMissing,
              let installCommand = status.installCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !installCommand.isEmpty else {
            let response = Self.agentProviderSetupResponse(status)
            let id = appendAssistantMessage(response.bubbleText, status: .failed, request: request, directiveType: .respond)
            completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .failed)
            remember(userText: input, assistantText: response.conversationText)
            try await speak(response.bubbleText, request: request, timing: &timing, force: request.inputMode == .voice)
            return true
        }

        let approval = AgentApprovalPrompt(
            requirement: AgentApprovalRequirement(
                providerID: status.providerID,
                role: .localPrivate,
                mode: .act,
                workspacePath: nil,
                dataScopes: [.prompt],
                actionScopes: [.runCommands, .useNetwork]
            ),
            title: "Install Claude Code",
            detail: """
            Roca will run this installer command, then add `~/.local/bin` to your shell PATH if needed:

            \(installCommand)
            """
        )
        let decision = await requestAgentApprovalDecision(for: approval, allowsRememberedApproval: false)
        guard decision == .approve || decision == .approveForSession else {
            let message = "No problem. I won't install Claude Code."
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .respond)
            completeMessage(id, text: message, status: .completed)
            remember(userText: input, assistantText: message)
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
            return true
        }

        let startedMessage = "Got it. I'll let you know once Claude Code is done installing."
        let startedID = appendAssistantMessage(startedMessage, status: .completed, request: request, directiveType: .respond)
        completeMessage(startedID, text: startedMessage, status: .completed)
        do {
            try await speak(
                startedMessage,
                request: request,
                timing: &timing,
                force: request.inputMode == .voice,
                finishWhenDone: false
            )
        } catch {
            if Self.isCancellation(error) || isTurnCancelled(request.turnID) {
                throw RocaError.cancelled
            }
        }

        setState(.acting("Installing Claude Code"))
        let actionID = appendActionMessage("Installing Claude Code...", status: .pending, request: request, directiveType: .respond)
        timing.actionStartedAt = Date()
        do {
            try checkTurnStillActive(request.turnID)
            let result = try await providerSetupInstaller.install(
                ProviderSetupInstallRequest(
                    providerID: status.providerID,
                    displayName: status.displayName,
                    installCommand: installCommand
                )
            )
            timing.actionFinishedAt = Date()
            try checkTurnStillActive(request.turnID)

            if result.succeeded {
                completeMessage(actionID, text: "Claude Code installer finished.", status: .completed)
                let response = AssistantResponseContent(
                    bubbleText: "Claude Code installer finished. Open a new Terminal, sign in if it asks, then recheck Claude Code in Settings.",
                    detailsMarkdown: Self.installerOutputDetails(result)
                )
                let id = appendAssistantMessage(response.bubbleText, status: .completed, request: request, directiveType: .respond)
                completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .completed)
                remember(userText: input, assistantText: response.conversationText)
                try await speak(response.bubbleText, request: request, timing: &timing, force: request.inputMode == .voice)
                return true
            }

            let response = AssistantResponseContent(
                bubbleText: "I couldn't install Claude Code. The installer exited with code \(result.exitCode).",
                detailsMarkdown: Self.installerOutputDetails(result)
            )
            completeMessage(actionID, text: "Claude Code installer failed.", status: .failed)
            let id = appendAssistantMessage(response.bubbleText, status: .failed, request: request, directiveType: .respond)
            completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .failed)
            remember(userText: input, assistantText: response.conversationText)
            try await speak(response.bubbleText, request: request, timing: &timing, force: request.inputMode == .voice)
            return true
        } catch {
            timing.actionFinishedAt = Date()
            if Self.isCancellation(error) || isTurnCancelled(request.turnID) {
                completeMessage(actionID, text: "Claude Code install cancelled.", status: .cancelled)
                throw RocaError.cancelled
            }
            let response = AssistantResponseContent(
                bubbleText: "I couldn't install Claude Code: \(error.localizedDescription)",
                detailsMarkdown: nil
            )
            completeMessage(actionID, text: "Claude Code installer failed.", status: .failed)
            let id = appendAssistantMessage(response.bubbleText, status: .failed, request: request, directiveType: .respond)
            completeMessage(id, text: response.bubbleText, status: .failed)
            remember(userText: input, assistantText: response.conversationText)
            try await speak(response.bubbleText, request: request, timing: &timing, force: request.inputMode == .voice)
            return true
        }
    }

    private nonisolated static func localProviderSetupHelpResponse(for input: String) -> AssistantResponseContent? {
        let normalized = input.lowercased()
        guard normalized.contains("claude") else {
            return nil
        }

        let setupTopicPatterns = [
            "api key",
            "provider auth",
            "auth",
            "authenticate",
            "credentials",
            "login",
            "sign in",
            "claude code",
            "claude cli"
        ]
        let helpIntentPatterns = [
            "how",
            "configure",
            "configuration",
            "where do",
            "what do i",
            "help me",
            "set up",
            "setup"
        ]
        let agentWorkPatterns = [
            "ask claude to inspect",
            "ask claude to review",
            "ask claude to summarize",
            "ask claude in"
        ]
        let isSetupTopic = setupTopicPatterns.contains { normalized.contains($0) }
        let isHelpIntent = helpIntentPatterns.contains { normalized.contains($0) }
        let isLikelyAgentWork = agentWorkPatterns.contains { normalized.contains($0) }
        guard isSetupTopic, isHelpIntent, !isLikelyAgentWork else {
            return nil
        }

        return AssistantResponseContent(
            bubbleText: "Use Claude Code for Roca. Install the Claude CLI, sign in, then recheck Claude Code in Settings.",
            detailsMarkdown: """
            ## Claude Code setup

            1. Install Claude Code:

            ```sh
            curl -fsSL https://claude.ai/install.sh | bash
            ```

            2. Sign in with Claude Code in Terminal.
            3. Open `Settings > Assistant > Agent Providers` and click `Recheck Agent Providers`.

            Roca uses your installed Claude Code CLI for Claude handoffs. Claude Code requires a Claude account with Claude Code access.

            Reference: [Claude Code setup](https://code.claude.com/docs/en/setup)
            """
        )
    }

    private nonisolated static func isClaudeCodeInstallRequest(
        _ input: String,
        recentMessages: [BrainMessage]
    ) -> Bool {
        let normalized = input.lowercased()
        let selfInstallPatterns = [
            "install it myself",
            "install claude myself",
            "install it yourself",
            "how do i install",
            "how to install",
            "show me how"
        ]
        if selfInstallPatterns.contains(where: { normalized.contains($0) }) {
            return false
        }

        let explicitInstallPatterns = [
            "can you install",
            "could you install",
            "please install",
            "install claude",
            "install the claude",
            "go ahead and install",
            "set it up for me",
            "install it for me",
            "do the install"
        ]
        let asksRocaToInstall = explicitInstallPatterns.contains { normalized.contains($0) }
            || normalized.trimmingCharacters(in: .whitespacesAndNewlines) == "install it"
        guard asksRocaToInstall else {
            return false
        }

        if normalized.contains("claude") {
            return true
        }
        return recentMessages.suffix(6).contains { message in
            let content = message.content.lowercased()
            return content.contains("claude code cli is not installed")
                || content.contains("claude code setup")
                || content.contains("https://claude.ai/install.sh")
        }
    }

    private nonisolated static func installerOutputDetails(_ result: ProviderSetupInstallResult) -> String? {
        let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = result.postInstallNotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedOutput.isEmpty || !notes.isEmpty else {
            return nil
        }

        var sections: [String] = []
        if !notes.isEmpty {
            sections.append(
                """
                ## Setup Notes

                \(notes.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }
        if !trimmedOutput.isEmpty {
            sections.append(
                """
                ## Installer Output

                ```text
                \(trimmedOutput)
                ```
                """
            )
        }
        return sections.joined(separator: "\n\n")
    }

    private func handlePendingDirectiveRetryIfNeeded(
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        brainProvider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> Bool {
        guard Self.isRetryRequest(input) else {
            return false
        }
        guard let retry = pendingDirectiveRetry, retry.isFresh else {
            pendingDirectiveRetry = nil
            return false
        }

        pendingDirectiveRetry = nil
        timing.directiveType = retry.directive.metricType
        timing.directiveFinishedAt = Date()
        emitDiagnostic(
            kind: .directiveResolved,
            turnID: request.turnID,
            phase: "retry",
            directiveType: retry.directive.metricType,
            outcome: "retry",
            metadata: diagnosticMetadata(for: request)
        )

        switch retry.directive {
        case .runSkill(let directive):
            try await handleSkillDirective(
                directive,
                input: retry.originalUserInput,
                request: request,
                context: context,
                brainProvider: brainProvider,
                timing: &timing,
                resolvedProjectOverride: retry.resolvedProject
            )
            return true
        case .runAgent(let directive):
            try await handleAgentDirective(
                directive,
                input: retry.originalUserInput,
                request: request,
                context: context,
                brainProvider: brainProvider,
                timing: &timing,
                resolvedProjectOverride: retry.resolvedProject
            )
            return true
        default:
            return false
        }
    }

    private func handlePendingProjectClarificationIfNeeded(
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        brainProvider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> Bool {
        guard let pending = pendingProjectClarification else {
            return false
        }

        if Self.isProjectClarificationCancellation(input) {
            pendingProjectClarification = nil
            timing.directiveType = pending.directiveType
            timing.directiveFinishedAt = Date()
            let message = "No problem, I won't run \(pending.providerName)."
            await recordTaskEvent(
                pending.taskID,
                kind: .cancelled,
                status: .cancelled,
                turnID: request.turnID,
                phase: "projectClarification",
                summary: message
            )
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: pending.directiveType)
            completeMessage(id, text: message, status: .completed)
            rememberAssistantObservation(message)
            try await speak(message, request: request, timing: &timing)
            return true
        }

        var currentPending = pending
        let correctedQuery = Self.correctedProjectQuery(from: input, fallback: currentPending.query)
        if correctedQuery != currentPending.query {
            currentPending.query = correctedQuery
            currentPending.directive.projectName = correctedQuery
            pendingProjectClarification = currentPending
        }

        if Self.looksLikeProjectFolderHint(input) {
            switch try await workspaceResolver.resolveFromLocalFolders(query: correctedQuery, hint: input) {
            case .resolved(let resolved):
                pendingProjectClarification = nil
                var directive = currentPending.directive
                directive.projectName = resolved.project.displayName
                timing.directiveType = currentPending.directiveType
                timing.directiveFinishedAt = Date()
                await recordTaskEvent(
                    currentPending.taskID,
                    kind: .clarificationResolved,
                    status: .resolvingProject,
                    turnID: request.turnID,
                    phase: "projectFolderHint",
                    summary: "Found \(resolved.project.displayName) from the folder hint.",
                    metadata: [
                        "projectQuery": correctedQuery,
                        "projectID": resolved.project.id.rawValue,
                        "projectPath": resolved.project.localPath
                    ]
                ) { task in
                    task.resolvedProject = resolved.project
                }
                emitDiagnostic(
                    kind: .agentProjectLookupCompleted,
                    turnID: request.turnID,
                    phase: "projectFolderHint",
                    providerID: currentPending.providerID,
                    directiveType: currentPending.directiveType,
                    outcome: "resolved",
                    metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(resolved.candidateCount ?? 0)])
                )
                try await resumePendingProjectClarification(
                    currentPending,
                    directive: directive,
                    input: currentPending.originalUserInput,
                    request: request,
                    context: context,
                    brainProvider: brainProvider,
                    timing: &timing,
                    resolvedProject: resolved.project
                )
                return true
            case .ambiguous(_, let candidates, _):
                let response = Self.projectClarificationResponse(for: candidates, query: correctedQuery)
                let id = appendAssistantMessage(response.bubbleText, status: .completed, request: request, directiveType: currentPending.directiveType)
                completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .completed)
                currentPending.candidates = candidates
                currentPending.questionMessageID = id
                pendingProjectClarification = currentPending
                timing.directiveType = currentPending.directiveType
                timing.directiveFinishedAt = Date()
                await recordTaskEvent(
                    currentPending.taskID,
                    kind: .clarificationRequested,
                    status: .waitingForClarification,
                    turnID: request.turnID,
                    phase: "projectFolderHint",
                    summary: response.conversationText,
                    metadata: ["candidateCount": String(candidates.count)]
                )
                emitDiagnostic(
                    kind: .agentProjectLookupCompleted,
                    turnID: request.turnID,
                    phase: "projectFolderHint",
                    providerID: currentPending.providerID,
                    directiveType: currentPending.directiveType,
                    outcome: "ambiguous",
                    metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(candidates.count)])
                )
                rememberAssistantObservation(response.bubbleText)
                try await speak(response.bubbleText, request: request, timing: &timing)
                return true
            case .missing:
                let message = "I looked there, but couldn't find a project matching \(correctedQuery). Please give me a more specific folder or project name."
                let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: currentPending.directiveType)
                completeMessage(id, text: message, status: .completed)
                pendingProjectClarification = currentPending
                timing.directiveType = currentPending.directiveType
                timing.directiveFinishedAt = Date()
                await recordTaskEvent(
                    currentPending.taskID,
                    kind: .clarificationRequested,
                    status: .waitingForClarification,
                    turnID: request.turnID,
                    phase: "projectFolderHint",
                    summary: message
                )
                rememberAssistantObservation(message)
                try await speak(message, request: request, timing: &timing)
                return true
            case .needsMoreSpecificQuery:
                break
            }
        }

        if currentPending.candidates.isEmpty {
            let message = "Got it, \(correctedQuery). Where should I look for that project folder?"
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: currentPending.directiveType)
            completeMessage(id, text: message, status: .completed)
            currentPending.questionMessageID = id
            pendingProjectClarification = currentPending
            timing.directiveType = currentPending.directiveType
            timing.directiveFinishedAt = Date()
            await recordTaskEvent(
                currentPending.taskID,
                kind: .clarificationRequested,
                status: .waitingForClarification,
                turnID: request.turnID,
                phase: "projectClarification",
                summary: message
            )
            rememberAssistantObservation(message)
            try await speak(message, request: request, timing: &timing)
            return true
        }

        switch Self.projectClarificationResolution(input: input, candidates: currentPending.candidates) {
        case .resolved(let project):
            await workspaceResolver.remember(project)
            pendingProjectClarification = nil
            var directive = currentPending.directive
            directive.projectName = project.displayName
            timing.directiveType = currentPending.directiveType
            timing.directiveFinishedAt = Date()
            await recordTaskEvent(
                currentPending.taskID,
                kind: .clarificationResolved,
                status: .resolvingProject,
                turnID: request.turnID,
                phase: "projectClarification",
                summary: "User chose \(project.displayName).",
                metadata: [
                    "clarificationTurnID": currentPending.createdTurnID.rawValue,
                    "questionMessageID": currentPending.questionMessageID.rawValue,
                    "projectQuery": currentPending.query,
                    "projectID": project.id.rawValue
                ]
            ) { task in
                task.resolvedProject = project
            }
            emitDiagnostic(
                kind: .directiveResolved,
                turnID: request.turnID,
                phase: "projectClarification",
                providerID: currentPending.providerID,
                directiveType: currentPending.directiveType,
                outcome: "resumed",
                metadata: diagnosticMetadata(
                    for: request,
                    extra: [
                        "clarificationTurnID": currentPending.createdTurnID.rawValue,
                        "questionMessageID": currentPending.questionMessageID.rawValue,
                        "projectQuery": currentPending.query,
                        "projectID": project.id.rawValue,
                        "projectName": project.displayName
                    ]
                )
            )
            try await resumePendingProjectClarification(
                currentPending,
                directive: directive,
                input: currentPending.originalUserInput,
                request: request,
                context: context,
                brainProvider: brainProvider,
                timing: &timing,
                resolvedProject: project
            )
            return true
        case .ambiguous(_, let candidates):
            pendingProjectClarification?.candidates = candidates
            timing.directiveType = currentPending.directiveType
            timing.directiveFinishedAt = Date()
            let response = Self.projectClarificationResponse(for: candidates, query: currentPending.query)
            await recordTaskEvent(
                currentPending.taskID,
                kind: .clarificationRequested,
                status: .waitingForClarification,
                turnID: request.turnID,
                phase: "projectClarification",
                summary: response.conversationText,
                metadata: ["candidateCount": String(candidates.count)]
            )
            let id = appendAssistantMessage(response.bubbleText, status: .completed, request: request, directiveType: currentPending.directiveType)
            completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .completed)
            rememberAssistantObservation(response.bubbleText)
            try await speak(response.bubbleText, request: request, timing: &timing)
            return true
        case .missing:
            guard Self.looksLikeProjectClarificationAnswer(input, candidates: currentPending.candidates) else {
                await recordTaskEvent(
                    currentPending.taskID,
                    kind: .cancelled,
                    status: .cancelled,
                    turnID: request.turnID,
                    phase: "projectClarification",
                    summary: "User moved on before clarifying \(currentPending.query)."
                )
                pendingProjectClarification = nil
                return false
            }
            timing.directiveType = currentPending.directiveType
            timing.directiveFinishedAt = Date()
            let response = Self.projectClarificationResponse(
                for: currentPending.candidates,
                query: currentPending.query,
                retryingAfterMiss: true
            )
            await recordTaskEvent(
                currentPending.taskID,
                kind: .clarificationRequested,
                status: .waitingForClarification,
                turnID: request.turnID,
                phase: "projectClarification",
                summary: response.conversationText
            )
            let id = appendAssistantMessage(response.bubbleText, status: .completed, request: request, directiveType: currentPending.directiveType)
            completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .completed)
            rememberAssistantObservation(response.bubbleText)
            try await speak(response.bubbleText, request: request, timing: &timing)
            return true
        }
    }

    private func resumePendingProjectClarification(
        _ pending: PendingProjectClarification,
        directive: AgentDirectiveRequest,
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        brainProvider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder,
        resolvedProject: ProjectIdentity
    ) async throws {
        if let skillID = pending.localSkillID {
            let skillDirective = SkillDirectiveRequest(
                skillID: skillID,
                projectName: resolvedProject.displayName,
                prompt: directive.prompt,
                mode: directive.mode
            )
            try await handleSkillDirective(
                skillDirective,
                input: input,
                request: request,
                context: context,
                brainProvider: brainProvider,
                timing: &timing,
                resolvedProjectOverride: resolvedProject,
                existingTaskID: pending.taskID
            )
        } else {
            try await handleAgentDirective(
                directive,
                input: input,
                request: request,
                context: context,
                brainProvider: brainProvider,
                timing: &timing,
                resolvedProjectOverride: resolvedProject,
                existingTaskID: pending.taskID
            )
        }
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
            let contextualized = contextualizedAgentDirective(agentRequest, userInput: input)
            if contextualized.resolvedProviderID == nil,
               let skillRequest = Self.skillDirective(fromProviderlessAgentDirective: contextualized, userInput: input) {
                try await handleSkillDirective(
                    contextualizedSkillDirective(skillRequest, userInput: input),
                    input: input,
                    request: request,
                    context: context,
                    brainProvider: provider,
                    timing: &timing
                )
            } else {
                try await handleAgentDirective(
                    contextualized,
                    input: input,
                    request: request,
                    context: context,
                    brainProvider: provider,
                    timing: &timing
                )
            }
        case .runSkill(let skillRequest):
            try await handleSkillDirective(
                contextualizedSkillDirective(skillRequest, userInput: input),
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

    private func handleSkillDirective(
        _ directive: SkillDirectiveRequest,
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        brainProvider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder,
        resolvedProjectOverride: ProjectIdentity? = nil,
        existingTaskID: AssistantTaskID? = nil
    ) async throws {
        try checkTurnStillActive(request.turnID)
        guard brainProvider.capabilities.locality == .local else {
            let message = "I can do that locally, but your current assistant brain is not local. Choose a local model first, or explicitly ask Codex or Claude."
            let id = appendAssistantMessage(message, status: .failed, request: request, directiveType: .runSkill)
            completeMessage(id, text: message, status: .failed)
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
            return
        }

        guard let skillID = directive.resolvedSkillID,
              let worker = localSkillWorkers[skillID]
        else {
            let message = "I don't have that local skill yet."
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runSkill)
            completeMessage(id, text: message, status: .completed)
            try await speak(message, request: request, timing: &timing)
            return
        }

        guard directive.mode != .act else {
            let message = "\(worker.displayName) is read-only for now. Ask Codex or Claude if you want code changes."
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runSkill)
            completeMessage(id, text: message, status: .completed)
            try await speak(message, request: request, timing: &timing)
            return
        }

        guard directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            let message = "Which project should I inspect locally?"
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runSkill)
            completeMessage(id, text: message, status: .completed)
            try await speak(message, request: request, timing: &timing)
            return
        }

        let taskID: AssistantTaskID
        if let existingTaskID {
            taskID = existingTaskID
        } else {
            taskID = await createSkillTask(directive: directive, input: input, request: request, skillID: skillID)
        }
        activeAssistantTaskID = taskID
        defer {
            if activeAssistantTaskID == taskID {
                activeAssistantTaskID = nil
            }
        }

        let resolvedProject: (project: ProjectIdentity?, shouldContinue: Bool)
        if let resolvedProjectOverride {
            resolvedProject = (resolvedProjectOverride, true)
        } else {
            resolvedProject = try await resolveProjectForSkill(
                directive: directive,
                skillID: skillID,
                skillName: worker.displayName,
                userInput: input,
                request: request,
                taskID: taskID,
                timing: &timing
            )
        }
        guard resolvedProject.shouldContinue, let project = resolvedProject.project else {
            return
        }

        let intro = Self.skillIntroText(
            skillName: worker.displayName,
            project: project,
            mode: directive.mode,
            userInput: input,
            prompt: directive.prompt
        )
        let introID = appendAssistantMessage(intro, status: .completed, request: request, directiveType: .runSkill)
        completeMessage(introID, text: intro, status: .completed)
        try await speak(intro, request: request, timing: &timing, finishWhenDone: false)

        setState(.acting("Scanning \(project.displayName)"))
        let actionID = appendActionMessage("Scanning \(project.displayName) locally...", status: .streaming, request: request, directiveType: .runSkill)
        timing.actionStartedAt = Date()
        let runID = SkillRunID.make()
        let workflowKind = Self.developerWorkflowKind(for: input, directive: directive)
        var metadata = [
            "skillRunID": runID.rawValue,
            "skillID": skillID.rawValue,
            "skillMode": directive.mode.rawValue,
            "projectID": project.id.rawValue,
            "projectName": project.displayName
        ]
        if let workflowKind {
            metadata["workflowKind"] = workflowKind.rawValue
        }
        await recordTaskEvent(
            taskID,
            kind: .skillRunStarted,
            status: .running,
            turnID: request.turnID,
            phase: "skillRun",
            summary: "\(worker.displayName) started.",
            metadata: metadata
        )
        emitDiagnostic(
            kind: .skillRunStarted,
            turnID: request.turnID,
            phase: "skillRun",
            directiveType: .runSkill,
            metadata: diagnosticMetadata(
                for: request,
                extra: [
                    "skillID": skillID.rawValue,
                    "skillMode": directive.mode.rawValue,
                    "workspaceResolved": "true"
                ].merging(workflowKind.map { ["workflowKind": $0.rawValue] } ?? [:]) { current, _ in current }
            )
        )

        var resultMessageID: ChatMessageID?
        do {
            let result = try await worker.run(
                LocalSkillRunRequest(
                    runID: runID,
                    skillID: skillID,
                    prompt: directive.prompt,
                    mode: directive.mode,
                    project: project,
                    userInput: input,
                    metadata: workflowKind.map { ["workflowKind": $0.rawValue] } ?? [:]
                )
            )
            try Task.checkCancellation()
            try checkTurnStillActive(request.turnID)
            timing.actionFinishedAt = Date()
            completeMessage(actionID, text: "Local scan complete.", status: .completed)
            setState(.acting("Summarizing findings"))
            await recordTaskEvent(
                taskID,
                kind: .skillRunFinished,
                status: .running,
                turnID: request.turnID,
                phase: "skillRun",
                summary: "\(worker.displayName) returned local evidence.",
                metadata: result.metadata
            )

            let assistantMessageID = appendAssistantMessage(
                "",
                status: .streaming,
                request: request,
                directiveType: .runSkill,
                brainRole: .generalChat
            )
            resultMessageID = assistantMessageID
            await recordTaskEvent(
                taskID,
                kind: .resultFormattingStarted,
                status: .formattingResult,
                turnID: request.turnID,
                phase: "skillResultFormatting",
                summary: "Formatting \(worker.displayName)'s result."
            )
            timing.responseBrainStartedAt = Date()
            let response = try await completeAssistantResponse(
                input: Self.skillResultFormattingPrompt(
                    userInput: input,
                    skillName: worker.displayName,
                    project: project,
                    localEvidence: result.evidenceMarkdown
                ),
                request: request,
                context: context,
                provider: brainProvider,
                messageID: assistantMessageID
            )
            timing.responseBrainFinishedAt = Date()
            completeMessage(
                assistantMessageID,
                text: response.bubbleText,
                detailsMarkdown: response.detailsMarkdown,
                status: .completed
            )
            await recordTaskEvent(
                taskID,
                kind: .resultFormatted,
                status: .formattingResult,
                turnID: request.turnID,
                phase: "skillResultFormatting",
                summary: response.bubbleText
            )
            let contextPacket = AssistantContextPacket(
                currentTask: AssistantAgentTaskContext(
                    providerID: ProviderID(rawValue: "local-skill"),
                    providerName: worker.displayName,
                    mode: directive.mode,
                    prompt: directive.prompt,
                    project: project
                ),
                priorAgentResult: AssistantAgentResultContext(
                    providerID: ProviderID(rawValue: "local-skill"),
                    providerName: worker.displayName,
                    mode: directive.mode,
                    project: project,
                    summary: response.bubbleText,
                    detailsMarkdown: response.detailsMarkdown
                ),
                approval: AssistantApprovalContext(riskLevel: .low, approvalBehavior: .notRequired)
            )
            lastContextPacket = contextPacket
            rememberAgentResult(userText: input, contextPacket: contextPacket)
            try await speak(response.bubbleText, request: request, timing: &timing)
            await recordTaskEvent(
                taskID,
                kind: .completed,
                status: .completed,
                turnID: request.turnID,
                phase: "finish",
                summary: response.bubbleText
            ) { task in
                task.resultSummary = response.bubbleText
                task.resultDetailsMarkdown = response.detailsMarkdown
            }
            emitDiagnostic(
                kind: .skillRunCompleted,
                turnID: request.turnID,
                phase: "skillRun",
                directiveType: .runSkill,
                outcome: AssistantTurnOutcome.completed.rawValue,
                metadata: diagnosticMetadata(
                    for: request,
                    extra: [
                        "skillID": skillID.rawValue,
                        "toolCount": result.metadata["toolCount"] ?? "0"
                    ]
                )
            )
        } catch {
            timing.actionFinishedAt = Date()
            if timing.responseBrainStartedAt != nil, timing.responseBrainFinishedAt == nil {
                timing.responseBrainFinishedAt = Date()
            }
            if Self.isCancellation(error) || isTurnCancelled(request.turnID) {
                completeMessage(actionID, text: "\(worker.displayName) cancelled.", status: .cancelled)
                await recordTaskEvent(
                    taskID,
                    kind: .cancelled,
                    status: .cancelled,
                    turnID: request.turnID,
                    phase: "skillRun",
                    summary: "\(worker.displayName) was cancelled."
                )
                throw RocaError.cancelled
            }
            pendingDirectiveRetry = PendingDirectiveRetry(
                directive: .runSkill(directive),
                originalUserInput: input,
                resolvedProject: project
            )
            let didStartFormatting = resultMessageID != nil
            let message = didStartFormatting
                ? Self.skillResultFormattingFailureMessage(project: project, error: error)
                : "I couldn't inspect that locally: \(error.localizedDescription)"
            if let resultMessageID {
                completeMessage(resultMessageID, text: message, status: .failed)
            } else {
                completeMessage(actionID, text: message, status: .failed)
            }
            await recordTaskFailure(
                taskID,
                turnID: request.turnID,
                phase: didStartFormatting ? "skillResultFormatting" : "skillRun",
                message: message,
                error: error
            )
            rememberAssistantObservation(message)
            emitDiagnostic(
                kind: .skillRunFailed,
                turnID: request.turnID,
                phase: didStartFormatting ? "skillResultFormatting" : "skillRun",
                directiveType: .runSkill,
                outcome: AssistantTurnOutcome.failed.rawValue,
                metadata: diagnosticMetadata(for: request, error: error, extra: ["skillID": skillID.rawValue])
            )
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
        }
    }

    private func handleAgentDirective(
        _ directive: AgentDirectiveRequest,
        input: String,
        request: AssistantSessionTurnRequest,
        context: AssistantLocalContext,
        brainProvider: any BrainProvider,
        timing: inout AssistantTurnTimingBuilder,
        resolvedProjectOverride: ProjectIdentity? = nil,
        existingTaskID: AssistantTaskID? = nil
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

        let taskID: AssistantTaskID
        if let existingTaskID {
            taskID = existingTaskID
        } else {
            taskID = await createAgentTask(
                directive: directive,
                input: input,
                request: request,
                providerID: providerID,
                providerName: providerName
            )
        }
        activeAssistantTaskID = taskID
        defer {
            if activeAssistantTaskID == taskID {
                activeAssistantTaskID = nil
            }
        }

        let provider: any AgentProvider
        do {
            provider = try await resolver.agentProvider(id: providerID)
            try checkTurnStillActive(request.turnID)
            await recordTaskEvent(
                taskID,
                kind: .providerResolved,
                turnID: request.turnID,
                phase: "providerResolution",
                summary: "Using \(providerName)."
            )
        } catch RocaError.agentProviderSetupRequired(let status) {
            if isTurnCancelled(request.turnID) {
                throw RocaError.cancelled
            }
            let response = Self.agentProviderSetupResponse(status)
            await recordTaskFailure(
                taskID,
                turnID: request.turnID,
                phase: "providerResolution",
                message: response.conversationText,
                error: RocaError.agentProviderSetupRequired(status)
            )
            let id = appendAssistantMessage(response.bubbleText, status: .failed, request: request, directiveType: .runAgent)
            completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .failed)
            rememberAssistantObservation(response.conversationText)
            try await speak(response.bubbleText, request: request, timing: &timing, force: request.inputMode == .voice)
            return
        } catch {
            if Self.isCancellation(error) || isTurnCancelled(request.turnID) {
                await recordTaskEvent(
                    taskID,
                    kind: .cancelled,
                    status: .cancelled,
                    turnID: request.turnID,
                    phase: "providerResolution",
                    summary: "Cancelled before \(providerName) started."
                )
                throw RocaError.cancelled
            }
            let message = "I couldn't start \(providerName): \(error.localizedDescription)"
            await recordTaskFailure(
                taskID,
                turnID: request.turnID,
                phase: "providerResolution",
                message: message,
                error: error
            )
            let id = appendAssistantMessage(message, status: .failed, request: request, directiveType: .runAgent)
            completeMessage(id, text: message, status: .failed)
            try await speak(message, request: request, timing: &timing, force: request.inputMode == .voice)
            return
        }

        let resolvedProject: (project: ProjectIdentity?, shouldContinue: Bool)
        if let resolvedProjectOverride {
            resolvedProject = (resolvedProjectOverride, true)
            await recordTaskEvent(
                taskID,
                kind: .projectResolved,
                turnID: request.turnID,
                phase: "projectClarification",
                summary: "Resolved project \(resolvedProjectOverride.displayName).",
                metadata: [
                    "projectID": resolvedProjectOverride.id.rawValue,
                    "projectPath": resolvedProjectOverride.localPath
                ]
            ) { task in
                task.resolvedProject = resolvedProjectOverride
            }
        } else {
            resolvedProject = try await resolveProject(
                for: directive,
                userInput: input,
                providerName: providerName,
                provider: provider,
                request: request,
                taskID: taskID,
                timing: &timing
            )
        }
        try Task.checkCancellation()
        try checkTurnStillActive(request.turnID)
        guard resolvedProject.shouldContinue else {
            return
        }

        let intro = Self.agentIntroText(providerName: providerName, project: resolvedProject.project, mode: directive.mode)
        let introID = appendAssistantMessage(intro, status: .completed, request: request, directiveType: .runAgent)
        completeMessage(introID, text: intro, status: .completed)
        try await speak(intro, request: request, timing: &timing, finishWhenDone: false)

        setState(.acting("Interacting with \(providerName)"))
        let actionID = appendActionMessage("Interacting with \(providerName)...", status: .streaming, request: request, directiveType: .runAgent)
        timing.actionStartedAt = Date()
        do {
            let runID = AgentRunID.make()
            let workflowKind = Self.developerWorkflowKind(for: input, directive: directive)
            var providerRunMetadata = [
                "agentRunID": runID.rawValue,
                "agentMode": directive.mode.rawValue
            ]
            if let workflowKind {
                providerRunMetadata["workflowKind"] = workflowKind.rawValue
            }
            var agentRequestMetadata = resolvedProject.project.map {
                ["projectID": $0.id.rawValue, "projectName": $0.displayName]
            } ?? [:]
            if let workflowKind {
                agentRequestMetadata["workflowKind"] = workflowKind.rawValue
            }
            activeAgentProvider = provider
            activeAgentRunID = runID
            await recordTaskEvent(
                taskID,
                kind: .providerRunStarted,
                status: .running,
                turnID: request.turnID,
                phase: "agentRun",
                summary: "\(providerName) started.",
                metadata: providerRunMetadata
            ) { task in
                task.providerRunID = runID
                task.resolvedProject = resolvedProject.project
            }
            let agentRunRequest = AgentRunRequest(
                runID: runID,
                prompt: directive.prompt,
                mode: directive.mode,
                role: .coding,
                workspacePath: resolvedProject.project?.localPath,
                dataScopes: [.prompt],
                actionScopes: [],
                metadata: agentRequestMetadata
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
                    ].merging(workflowKind.map { ["workflowKind": $0.rawValue] } ?? [:]) { current, _ in current }
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
                    await recordTaskEvent(
                        taskID,
                        kind: .approvalRequested,
                        status: .waitingForApproval,
                        turnID: request.turnID,
                        phase: "approval",
                        summary: "\(providerName) requested approval."
                    )
                    completeMessage(actionID, text: "Waiting for approval.", status: .streaming)
                case .questionRequired:
                    await recordTaskEvent(
                        taskID,
                        kind: .clarificationRequested,
                        status: .waitingForClarification,
                        turnID: request.turnID,
                        phase: "agentQuestion",
                        summary: "\(providerName) asked a question."
                    )
                    completeMessage(actionID, text: "Waiting for input.", status: .streaming)
                case .final(let response):
                    finalText = response.text
                    didFinish = true
                    await recordTaskEvent(
                        taskID,
                        kind: .providerRunFinished,
                        status: .running,
                        turnID: request.turnID,
                        phase: "agentRun",
                        summary: "\(providerName) returned a result.",
                        metadata: response.metadata
                    ) { task in
                        task.providerSessionID = response.metadata["threadID"] ?? response.metadata["threadId"]
                    }
                case .cancelled:
                    completeMessage(actionID, text: "\(providerName) cancelled.", status: .cancelled)
                    rememberAssistantObservation("\(providerName) was cancelled.")
                    await recordTaskEvent(
                        taskID,
                        kind: .cancelled,
                        status: .cancelled,
                        turnID: request.turnID,
                        phase: "agentRun",
                        summary: "\(providerName) cancelled."
                    )
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
            await recordTaskEvent(
                taskID,
                kind: .resultFormattingStarted,
                status: .formattingResult,
                turnID: request.turnID,
                phase: "agentResultFormatting",
                summary: "Formatting \(providerName)'s result."
            )
            var response: AssistantResponseContent
            if rawAgentText.isEmpty {
                response = AssistantResponseContent(
                    bubbleText: "\(providerName) finished, but I didn't get any details back.",
                    detailsMarkdown: nil
                )
                completeMessage(assistantMessageID, text: response.bubbleText, status: .completed)
                await recordTaskEvent(
                    taskID,
                    kind: .resultFormatted,
                    status: .formattingResult,
                    turnID: request.turnID,
                    phase: "agentResultFormatting",
                    summary: response.bubbleText
                )
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
                response = Self.normalizedAgentResponse(
                    response,
                    providerName: providerName,
                    mode: directive.mode,
                    rawAgentText: rawAgentText
                )
                try checkTurnStillActive(request.turnID)
                completeMessage(
                    assistantMessageID,
                    text: response.bubbleText,
                    detailsMarkdown: response.detailsMarkdown,
                    status: .completed
                )
                await recordTaskEvent(
                    taskID,
                    kind: .resultFormatted,
                    status: .formattingResult,
                    turnID: request.turnID,
                    phase: "agentResultFormatting",
                    summary: response.bubbleText
                )
            }
            let contextPacket = AssistantContextPacket(
                currentTask: AssistantAgentTaskContext(
                    providerID: providerID,
                    providerName: providerName,
                    mode: directive.mode,
                    prompt: directive.prompt,
                    project: resolvedProject.project
                ),
                priorAgentResult: AssistantAgentResultContext(
                    providerID: providerID,
                    providerName: providerName,
                    mode: directive.mode,
                    project: resolvedProject.project,
                    summary: response.bubbleText,
                    detailsMarkdown: response.detailsMarkdown
                ),
                approval: AssistantApprovalContext(
                    riskLevel: directive.mode == .act ? .high : .medium,
                    approvalBehavior: provider.capabilities.supportsToolApprovals ? .policyDriven : .notRequired
                )
            )
            lastContextPacket = contextPacket
            rememberAgentResult(
                userText: input,
                contextPacket: contextPacket
            )
            try await speak(response.bubbleText, request: request, timing: &timing)
            let resultSummary = response.bubbleText
            let resultDetailsMarkdown = response.detailsMarkdown
            await recordTaskEvent(
                taskID,
                kind: .completed,
                status: .completed,
                turnID: request.turnID,
                phase: "finish",
                summary: resultSummary
            ) { task in
                task.resultSummary = resultSummary
                task.resultDetailsMarkdown = resultDetailsMarkdown
            }
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
            await recordTaskFailure(
                taskID,
                turnID: request.turnID,
                phase: "approval",
                message: message,
                error: RocaError.approvalRequired(detail)
            )
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
        } catch RocaError.agentProviderSetupRequired(let status) {
            timing.actionFinishedAt = Date()
            let response = Self.agentProviderSetupResponse(status)
            await recordTaskFailure(
                taskID,
                turnID: request.turnID,
                phase: "agentSetup",
                message: response.conversationText,
                error: RocaError.agentProviderSetupRequired(status)
            )
            completeMessage(actionID, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .failed)
            rememberAssistantObservation(response.conversationText)
            emitDiagnostic(
                kind: .agentRunFailed,
                turnID: request.turnID,
                phase: "agentSetup",
                providerID: providerID,
                directiveType: .runAgent,
                outcome: AssistantTurnOutcome.failed.rawValue,
                metadata: diagnosticMetadata(for: request, error: RocaError.agentProviderSetupRequired(status))
            )
            try await speak(response.bubbleText, request: request, timing: &timing, force: request.inputMode == .voice)
        } catch {
            timing.actionFinishedAt = Date()
            if Self.isCancellation(error) {
                await recordTaskEvent(
                    taskID,
                    kind: .cancelled,
                    status: .cancelled,
                    turnID: request.turnID,
                    phase: "agentRun",
                    summary: "\(providerName) was cancelled."
                )
                throw error
            }
            let message = "I couldn't finish that with \(providerName): \(error.localizedDescription)"
            pendingDirectiveRetry = PendingDirectiveRetry(
                directive: .runAgent(directive),
                originalUserInput: input,
                resolvedProject: resolvedProject.project
            )
            await recordTaskFailure(
                taskID,
                turnID: request.turnID,
                phase: "agentRun",
                message: message,
                error: error
            )
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
        userInput: String,
        providerName: String,
        provider: any AgentProvider,
        request: AssistantSessionTurnRequest,
        taskID: AssistantTaskID,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> (project: ProjectIdentity?, shouldContinue: Bool) {
        guard let projectName = directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectName.isEmpty
        else {
            return (nil, true)
        }
        await recordTaskEvent(
            taskID,
            kind: .projectResolutionStarted,
            status: .resolvingProject,
            turnID: request.turnID,
            phase: "projectLookup",
            summary: "Resolving \(projectName)."
        ) { task in
            task.projectQuery = projectName
        }

        let excludedProjectNames = Self.excludedProjectNames(from: userInput)
        try checkTurnStillActive(request.turnID)
        let discoverer = provider as? any AgentProjectDiscovering
        let localResolution = try await workspaceResolver.resolveLocal(
            query: projectName,
            shouldVerifyBroadMatchWithProvider: discoverer != nil,
            excluding: excludedProjectNames
        )
        try checkTurnStillActive(request.turnID)
        switch localResolution {
        case .resolved(let project):
            await recordTaskEvent(
                taskID,
                kind: .projectResolved,
                turnID: request.turnID,
                phase: "projectLookup",
                summary: "Resolved project \(project.displayName).",
                metadata: [
                    "projectID": project.id.rawValue,
                    "projectPath": project.localPath
                ]
            ) { task in
                task.resolvedProject = project
            }
            return (project, true)
        case .ambiguous(_, let candidates):
            let response = Self.projectClarificationResponse(for: candidates, query: projectName)
            await recordTaskEvent(
                taskID,
                kind: .clarificationRequested,
                status: .waitingForClarification,
                turnID: request.turnID,
                phase: "projectLookup",
                summary: response.conversationText,
                metadata: ["candidateCount": String(candidates.count)]
            )
            let id = appendAssistantMessage(response.bubbleText, status: .completed, request: request, directiveType: .runAgent)
            completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .completed)
            storePendingProjectClarification(
                taskID: taskID,
                directive: directive,
                originalUserInput: userInput,
                query: projectName,
                candidates: candidates,
                questionMessageID: id,
                request: request
            )
            rememberAssistantObservation(response.bubbleText)
            try await speak(response.bubbleText, request: request, timing: &timing)
            return (nil, false)
        case .needsProviderDiscovery(let broadLocalMatch):
            guard let discoverer else {
                if let broadLocalMatch {
                    return try await askForMoreSpecificProject(
                        broadLocalMatch,
                        projectName: projectName,
                        providerName: providerName,
                        request: request,
                        taskID: taskID,
                        timing: &timing
                    )
                }
                return try await askForMissingProjectFolder(
                    directive: directive,
                    originalUserInput: userInput,
                    projectName: projectName,
                    providerName: providerName,
                    request: request,
                    taskID: taskID,
                    timing: &timing
                )
            }

            return try await resolveProjectFromProviderDiscovery(
                directive: directive,
                userInput: userInput,
                projectName: projectName,
                prompt: directive.prompt,
                excludedProjectNames: excludedProjectNames,
                providerName: providerName,
                providerID: directive.resolvedProviderID,
                discoverer: discoverer,
                broadLocalMatch: broadLocalMatch,
                request: request,
                taskID: taskID,
                timing: &timing
            )
        }
    }

    private func resolveProjectForSkill(
        directive: SkillDirectiveRequest,
        skillID: SkillID,
        skillName: String,
        userInput: String,
        request: AssistantSessionTurnRequest,
        taskID: AssistantTaskID,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> (project: ProjectIdentity?, shouldContinue: Bool) {
        guard let projectName = directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectName.isEmpty
        else {
            return (nil, false)
        }
        await recordTaskEvent(
            taskID,
            kind: .projectResolutionStarted,
            status: .resolvingProject,
            turnID: request.turnID,
            phase: "projectLookup",
            summary: "Resolving \(projectName)."
        ) { task in
            task.projectQuery = projectName
        }

        let excludedProjectNames = Self.excludedProjectNames(from: userInput)
        let localResolution = try await workspaceResolver.resolveLocal(
            query: projectName,
            shouldVerifyBroadMatchWithProvider: false,
            excluding: excludedProjectNames
        )
        try checkTurnStillActive(request.turnID)
        switch localResolution {
        case .resolved(let project):
            await recordTaskEvent(
                taskID,
                kind: .projectResolved,
                turnID: request.turnID,
                phase: "projectLookup",
                summary: "Resolved project \(project.displayName).",
                metadata: [
                    "projectID": project.id.rawValue,
                    "projectPath": project.localPath
                ]
            ) { task in
                task.resolvedProject = project
            }
            return (project, true)
        case .ambiguous(_, let candidates):
            let response = Self.projectClarificationResponse(for: candidates, query: projectName)
            await recordTaskEvent(
                taskID,
                kind: .clarificationRequested,
                status: .waitingForClarification,
                turnID: request.turnID,
                phase: "projectLookup",
                summary: response.conversationText,
                metadata: ["candidateCount": String(candidates.count)]
            )
            let id = appendAssistantMessage(response.bubbleText, status: .completed, request: request, directiveType: .runSkill)
            completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .completed)
            storePendingProjectClarification(
                taskID: taskID,
                directive: AgentDirectiveRequest(
                    providerID: nil,
                    providerName: skillName,
                    projectName: directive.projectName,
                    prompt: directive.prompt,
                    mode: directive.mode
                ),
                localSkillID: skillID,
                originalUserInput: userInput,
                query: projectName,
                candidates: candidates,
                questionMessageID: id,
                request: request
            )
            rememberAssistantObservation(response.bubbleText)
            try await speak(response.bubbleText, request: request, timing: &timing)
            return (nil, false)
        case .needsProviderDiscovery(let broadLocalMatch):
            let message: String
            if let broadLocalMatch {
                message = "I only know \(broadLocalMatch.displayName) for \(projectName). Please name the project more exactly before I inspect it locally."
            } else {
                message = "I don't know the \(projectName) project folder yet. Please give me the local folder before I inspect it."
            }
            await recordTaskEvent(
                taskID,
                kind: .clarificationRequested,
                status: .waitingForClarification,
                turnID: request.turnID,
                phase: "projectLookup",
                summary: message
            )
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runSkill)
            completeMessage(id, text: message, status: .completed)
            storePendingProjectClarification(
                taskID: taskID,
                directive: AgentDirectiveRequest(
                    providerID: nil,
                    providerName: skillName,
                    projectName: directive.projectName,
                    prompt: directive.prompt,
                    mode: directive.mode
                ),
                localSkillID: skillID,
                originalUserInput: userInput,
                query: projectName,
                candidates: broadLocalMatch.map { [$0] } ?? [],
                questionMessageID: id,
                request: request
            )
            rememberAssistantObservation(message)
            try await speak(message, request: request, timing: &timing)
            return (nil, false)
        }
    }

    private func resolveProjectFromProviderDiscovery(
        directive: AgentDirectiveRequest,
        userInput: String,
        projectName: String,
        prompt: String,
        excludedProjectNames: [String],
        providerName: String,
        providerID: ProviderID?,
        discoverer: any AgentProjectDiscovering,
        broadLocalMatch: ProjectIdentity?,
        request: AssistantSessionTurnRequest,
        taskID: AssistantTaskID,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> (project: ProjectIdentity?, shouldContinue: Bool) {
        let lookupID = appendActionMessage("Looking for \(projectName) in \(providerName)...", status: .pending, request: request, directiveType: .runAgent)
        emitDiagnostic(
            kind: .agentProjectLookupStarted,
            turnID: request.turnID,
            phase: "projectLookup",
            providerID: providerID,
            directiveType: .runAgent,
            metadata: diagnosticMetadata(for: request, extra: ["projectQueryPresent": "true"])
        )
        do {
            let outcome = try await workspaceResolver.resolveFromProvider(
                query: projectName,
                prompt: prompt,
                discoverer: discoverer,
                excluding: excludedProjectNames
            )
            try checkTurnStillActive(request.turnID)
            switch outcome {
            case .resolved(let resolved):
                let project = resolved.project
                let candidateCount = resolved.candidateCount ?? 0
                await recordTaskEvent(
                    taskID,
                    kind: .projectResolved,
                    turnID: request.turnID,
                    phase: "projectLookup",
                    summary: "Resolved project \(project.displayName).",
                    metadata: [
                        "projectID": project.id.rawValue,
                        "projectPath": project.localPath,
                        "candidateCount": String(candidateCount)
                    ]
                ) { task in
                    task.resolvedProject = project
                }
                completeMessage(lookupID, text: "Found \(project.displayName).", status: .completed)
                rememberAssistantObservation("Found \(project.displayName) in \(providerName).")
                emitDiagnostic(
                    kind: .agentProjectLookupCompleted,
                    turnID: request.turnID,
                    phase: "projectLookup",
                    providerID: providerID,
                    directiveType: .runAgent,
                    outcome: "resolved",
                    metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(candidateCount)])
                )
                return (project, true)
            case .ambiguous(_, let candidates, _):
                completeMessage(lookupID, text: "Found multiple project matches.", status: .completed)
                let response = Self.projectClarificationResponse(for: candidates, query: projectName)
                await recordTaskEvent(
                    taskID,
                    kind: .clarificationRequested,
                    status: .waitingForClarification,
                    turnID: request.turnID,
                    phase: "projectLookup",
                    summary: response.conversationText,
                    metadata: ["candidateCount": String(candidates.count)]
                )
                let id = appendAssistantMessage(response.bubbleText, status: .completed, request: request, directiveType: .runAgent)
                completeMessage(id, text: response.bubbleText, detailsMarkdown: response.detailsMarkdown, status: .completed)
                storePendingProjectClarification(
                    taskID: taskID,
                    directive: directive,
                    originalUserInput: userInput,
                    query: projectName,
                    candidates: candidates,
                    questionMessageID: id,
                    request: request
                )
                rememberAssistantObservation(response.bubbleText)
                emitDiagnostic(
                    kind: .agentProjectLookupCompleted,
                    turnID: request.turnID,
                    phase: "projectLookup",
                    providerID: providerID,
                    directiveType: .runAgent,
                    outcome: "ambiguous",
                    metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(candidates.count)])
                )
                try await speak(response.bubbleText, request: request, timing: &timing)
                return (nil, false)
            case .missing(_, _, let candidateCount):
                await recordTaskFailure(
                    taskID,
                    turnID: request.turnID,
                    phase: "projectLookup",
                    message: "No \(providerName) project match found."
                )
                completeMessage(lookupID, text: "No \(providerName) project match found.", status: .completed)
                emitDiagnostic(
                    kind: .agentProjectLookupCompleted,
                    turnID: request.turnID,
                    phase: "projectLookup",
                    providerID: providerID,
                    directiveType: .runAgent,
                    outcome: "missing",
                    metadata: diagnosticMetadata(for: request, extra: ["candidateCount": String(candidateCount ?? 0)])
                )
                if let broadLocalMatch {
                    return try await askForMoreSpecificProject(
                        broadLocalMatch,
                        projectName: projectName,
                        providerName: providerName,
                        request: request,
                        taskID: taskID,
                        timing: &timing
                    )
                }
                return try await askForMissingProjectFolder(
                    directive: directive,
                    originalUserInput: userInput,
                    projectName: projectName,
                    providerName: providerName,
                    request: request,
                    taskID: taskID,
                    timing: &timing
                )
            case .needsMoreSpecificQuery(_, let broadMatch):
                return try await askForMoreSpecificProject(
                    broadMatch,
                    projectName: projectName,
                    providerName: providerName,
                    request: request,
                    taskID: taskID,
                    timing: &timing
                )
            }
        } catch {
            completeMessage(lookupID, text: "\(providerName) project lookup failed.", status: .failed)
            await recordTaskFailure(
                taskID,
                turnID: request.turnID,
                phase: "projectLookup",
                message: "\(providerName) project lookup failed.",
                error: error
            )
            emitDiagnostic(
                kind: .agentProjectLookupFailed,
                turnID: request.turnID,
                phase: "projectLookup",
                providerID: providerID,
                directiveType: .runAgent,
                outcome: AssistantTurnOutcome.failed.rawValue,
                metadata: diagnosticMetadata(for: request, error: error, extra: ["projectQueryPresent": "true"])
            )
            let message = "I couldn't read \(providerName)'s project list in time, so I don't know the \(projectName) project folder yet. Please give me the local folder or try again."
            let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
            completeMessage(id, text: message, status: .completed)
            rememberAssistantObservation(message)
            try await speak(message, request: request, timing: &timing)
            return (nil, false)
        }
    }

    private func askForMoreSpecificProject(
        _ broadLocalMatch: ProjectIdentity,
        projectName: String,
        providerName: String,
        request: AssistantSessionTurnRequest,
        taskID: AssistantTaskID,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> (project: ProjectIdentity?, shouldContinue: Bool) {
        let message = "I only know \(broadLocalMatch.displayName) for \(projectName). Please name the project more exactly before I hand this to \(providerName)."
        await recordTaskEvent(
            taskID,
            kind: .clarificationRequested,
            status: .waitingForClarification,
            turnID: request.turnID,
            phase: "projectLookup",
            summary: message,
            metadata: ["projectID": broadLocalMatch.id.rawValue]
        )
        let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
        completeMessage(id, text: message, status: .completed)
        rememberAssistantObservation(message)
        try await speak(message, request: request, timing: &timing)
        return (nil, false)
    }

    private func askForMissingProjectFolder(
        directive: AgentDirectiveRequest,
        originalUserInput: String,
        projectName: String,
        providerName: String,
        request: AssistantSessionTurnRequest,
        taskID: AssistantTaskID,
        timing: inout AssistantTurnTimingBuilder
    ) async throws -> (project: ProjectIdentity?, shouldContinue: Bool) {
        let message = "I don't know the \(projectName) project folder yet. Please give me the local folder before I hand this to \(providerName)."
        await recordTaskFailure(
            taskID,
            turnID: request.turnID,
            phase: "projectLookup",
            message: message
        )
        let id = appendAssistantMessage(message, status: .completed, request: request, directiveType: .runAgent)
        completeMessage(id, text: message, status: .completed)
        storePendingProjectClarification(
            taskID: taskID,
            directive: directive,
            originalUserInput: originalUserInput,
            query: projectName,
            candidates: [],
            questionMessageID: id,
            request: request
        )
        rememberAssistantObservation(message)
        try await speak(message, request: request, timing: &timing)
        return (nil, false)
    }

    private func storePendingProjectClarification(
        taskID: AssistantTaskID,
        directive: AgentDirectiveRequest,
        localSkillID: SkillID? = nil,
        originalUserInput: String,
        query: String,
        candidates: [ProjectIdentity],
        questionMessageID: ChatMessageID,
        request: AssistantSessionTurnRequest
    ) {
        pendingProjectClarification = PendingProjectClarification(
            taskID: taskID,
            directive: directive,
            originalUserInput: originalUserInput,
            query: query,
            candidates: candidates,
            localSkillID: localSkillID,
            providerID: directive.resolvedProviderID,
            providerName: localSkillID.flatMap(SkillDirectiveRequest.skillDisplayName(for:)) ?? directive.providerDisplayName,
            createdTurnID: request.turnID,
            questionMessageID: questionMessageID
        )
    }

    private func contextualizedAgentDirective(
        _ directive: AgentDirectiveRequest,
        userInput: String
    ) -> AgentDirectiveRequest {
        if let explicitProjectName = Self.explicitProjectName(from: userInput) {
            var contextualized = directive
            contextualized.projectName = explicitProjectName
            return Self.developerWorkflowDirective(contextualized, userInput: userInput)
        }

        guard let agentContext = lastContextPacket?.priorAgentResult,
              Self.shouldReusePriorAgentContext(for: userInput, directive: directive)
        else {
            return Self.developerWorkflowDirective(directive, userInput: userInput)
        }

        var contextualized = directive
        if contextualized.providerID == nil, contextualized.providerName == nil {
            contextualized.providerID = agentContext.providerID
            contextualized.providerName = agentContext.providerName
        }

        let providerMatches = contextualized.resolvedProviderID == nil
            || contextualized.resolvedProviderID == agentContext.providerID
        if providerMatches,
           contextualized.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let project = agentContext.project {
            contextualized.projectName = project.displayName
        }

        return Self.developerWorkflowDirective(contextualized, userInput: userInput)
    }

    private func contextualizedSkillDirective(
        _ directive: SkillDirectiveRequest,
        userInput: String
    ) -> SkillDirectiveRequest {
        var contextualized = directive
        if let explicitProjectName = Self.explicitProjectName(from: userInput) {
            contextualized.projectName = explicitProjectName
            return Self.developerWorkflowSkillDirective(contextualized, userInput: userInput)
        }

        if contextualized.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let priorResult = lastContextPacket?.priorAgentResult,
           priorResult.providerID.rawValue == "local-skill",
           priorResult.providerName == directive.skillDisplayName,
           let project = priorResult.project,
           Self.shouldReusePriorSkillContext(for: userInput, directive: directive) {
            contextualized.projectName = project.displayName
        }
        return Self.developerWorkflowSkillDirective(contextualized, userInput: userInput)
    }

    private func recoveredLocalSkillFollowUpDirective(
        from directive: AssistantDirective,
        input: String
    ) -> AssistantDirective {
        guard let currentTask = lastContextPacket?.currentTask,
              currentTask.providerID.rawValue == "local-skill",
              SkillDirectiveRequest.skillID(for: currentTask.providerName)?.rawValue == "codebase"
        else {
            return directive
        }

        if Self.canRecoverLocalSkillFollowUp(from: directive),
           let explicitProjectName = Self.explicitProjectName(from: input) {
            return .runSkill(
                SkillDirectiveRequest(
                    skillID: SkillID(rawValue: "codebase"),
                    projectName: explicitProjectName,
                    prompt: currentTask.prompt,
                    mode: currentTask.mode == .act ? .ask : currentTask.mode
                )
            )
        }

        guard Self.isLocalCodebaseFollowUp(input),
              let project = currentTask.project,
              Self.canRecoverLocalSkillFollowUp(from: directive)
        else {
            return directive
        }

        return .runSkill(
            SkillDirectiveRequest(
                skillID: SkillID(rawValue: "codebase"),
                projectName: project.displayName,
                prompt: Self.localSkillFollowUpPrompt(priorPrompt: currentTask.prompt, input: input),
                mode: currentTask.mode == .act ? .ask : currentTask.mode
            )
        )
    }

    private nonisolated static func canRecoverLocalSkillFollowUp(from directive: AssistantDirective) -> Bool {
        switch directive {
        case .respond, .unsupported:
            true
        case .openApplication, .quitApplication, .insertText, .readSelection, .runAgent, .runSkill:
            false
        }
    }

    private nonisolated static func localSkillFollowUpPrompt(priorPrompt: String, input: String) -> String {
        """
        \(priorPrompt.trimmingCharacters(in: .whitespacesAndNewlines))

        Follow-up question:
        \(input.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private nonisolated static func skillDirective(
        fromProviderlessAgentDirective directive: AgentDirectiveRequest,
        userInput: String
    ) -> SkillDirectiveRequest? {
        guard directive.resolvedProviderID == nil,
              developerWorkflowKind(for: userInput, directive: directive) != nil
        else {
            return nil
        }
        return SkillDirectiveRequest(
            skillID: SkillID(rawValue: "codebase"),
            projectName: directive.projectName,
            prompt: directive.prompt,
            mode: directive.mode
        )
    }

    private static func projectClarificationQuestion(for candidates: [ProjectIdentity]) -> String {
        let names = candidates.map(\.displayName).joined(separator: ", ")
        return "Which project do you mean: \(names)?"
    }

    private static func projectClarificationResponse(
        for candidates: [ProjectIdentity],
        query: String,
        retryingAfterMiss: Bool = false
    ) -> AssistantResponseContent {
        guard candidates.count > 3 else {
            let question = projectClarificationQuestion(for: candidates)
            return AssistantResponseContent(
                bubbleText: retryingAfterMiss
                    ? "I couldn't match that to one of the project options. \(question)"
                    : question,
                detailsMarkdown: nil
            )
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmedQuery.isEmpty ? "project" : trimmedQuery
        let bubble = retryingAfterMiss
            ? "I couldn't match that. I see \(candidates.count) \(label) projects. Which one are you talking about?"
            : "I see \(candidates.count) \(label) projects. Which one are you talking about?"

        return AssistantResponseContent(
            bubbleText: bubble,
            detailsMarkdown: projectClarificationDetails(for: candidates)
        )
    }

    private static func projectClarificationDetails(for candidates: [ProjectIdentity]) -> String {
        let displayedCandidates = candidates.prefix(12)
        var lines = ["## Matching Projects"]
        if candidates.count > displayedCandidates.count {
            lines.append("")
            lines.append("Showing \(displayedCandidates.count) of \(candidates.count). Say a more specific project name to narrow it down.")
        }
        lines.append("")
        lines.append(contentsOf: displayedCandidates.map { "- \($0.displayName)" })
        return lines.joined(separator: "\n")
    }

    private static func projectClarificationResolution(
        input: String,
        candidates: [ProjectIdentity]
    ) -> ProjectResolution {
        ProjectIdentityResolver(projects: candidates).resolve(projectClarificationQuery(from: input))
    }

    private static func correctedProjectQuery(from input: String, fallback: String) -> String {
        explicitProjectName(from: input) ?? fallback
    }

    private static func looksLikeProjectFolderHint(_ input: String) -> Bool {
        let normalized = ProjectIdentityResolver.normalizedKey(input)
        let tokens = Set(normalized.split(separator: " ").map(String.init))
        if input.contains("/") || input.contains("~") {
            return true
        }
        return !tokens.isDisjoint(with: [
            "desktop",
            "directory",
            "documents",
            "downloads",
            "folder",
            "path",
            "somewhere",
            "workspace"
        ])
    }

    private static func projectClarificationQuery(from input: String) -> String {
        let fillerWords = Set([
            "a",
            "an",
            "choose",
            "go",
            "i",
            "it",
            "mean",
            "no",
            "one",
            "please",
            "project",
            "repo",
            "repository",
            "select",
            "that",
            "the",
            "use",
            "with",
            "yeah",
            "yep",
            "yes"
        ])
        let tokens = ProjectIdentityResolver.normalizedKey(input)
            .split(separator: " ")
            .map(String.init)
            .filter { !fillerWords.contains($0) }
        return tokens.joined(separator: " ")
    }

    private static func isProjectClarificationCancellation(_ input: String) -> Bool {
        let normalized = ProjectIdentityResolver.normalizedKey(input)
        return [
            "cancel",
            "cancel that",
            "forget it",
            "never mind",
            "nevermind",
            "stop",
            "skip it"
        ].contains(normalized)
    }

    private static func looksLikeProjectClarificationAnswer(_ input: String, candidates: [ProjectIdentity]) -> Bool {
        let normalized = ProjectIdentityResolver.normalizedKey(input)
        guard !normalized.isEmpty else {
            return false
        }
        if normalized.hasPrefix("what ")
            || normalized.hasPrefix("why ")
            || normalized.hasPrefix("how ")
            || normalized.hasPrefix("can ")
            || normalized.hasPrefix("could ")
            || normalized.hasPrefix("tell ")
            || normalized.hasPrefix("ask ") {
            return false
        }
        guard normalized.split(separator: " ").count <= 5 else {
            return false
        }
        let queryTokens = Set(projectClarificationQuery(from: input).split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty else {
            return false
        }
        let candidateTokens = Set(candidates.flatMap { project in
            project.searchNames.flatMap { ProjectIdentityResolver.normalizedKey($0).split(separator: " ").map(String.init) }
        })
        return !queryTokens.isDisjoint(with: candidateTokens)
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
        force: Bool = false,
        finishWhenDone: Bool = true
    ) async throws {
        let trimmed = Self.speechText(from: text)
        guard !trimmed.isEmpty else {
            if finishWhenDone {
                await finishTurn(request)
            }
            return
        }
        guard request.outputMode != .textOnly else {
            if finishWhenDone {
                await finishTurn(request)
            }
            return
        }
        guard force || shouldSpeak(trimmed, outputMode: request.outputMode) else {
            if finishWhenDone {
                await finishTurn(request)
            }
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
        if finishWhenDone {
            await finishTurn(request)
        }
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
        if let activeAssistantTaskID {
            await recordTaskEvent(
                activeAssistantTaskID,
                kind: .cancelled,
                status: .cancelled,
                turnID: activeTurnID,
                phase: "cancel",
                summary: "Assistant cancelled."
            )
        }
        if let activeAgentRunID {
            await activeAgentProvider?.cancel(activeAgentRunID)
        }
        activeBrainProvider = nil
        activeBrainRequestID = nil
        activeAgentProvider = nil
        activeAgentRunID = nil
        activeAssistantTaskID = nil
        await speechOrchestrator.stopSpeaking()
    }

    private func cancelPendingQuestions() {
        let pending = questionContinuations
        questionContinuations.removeAll()
        for (messageID, continuation) in pending {
            if let index = messages.firstIndex(where: { $0.id == messageID }),
               var question = messages[index].questionRequest,
               question.response == nil {
                question.response = .cancelled
                question.answeredAt = Date()
                messages[index].questionRequest = question
                messages[index].text = "Cancelled."
                messages[index].status = .cancelled
            }
            continuation.resume(returning: .cancelled)
        }
        if !pending.isEmpty {
            publishMessages()
        }
    }

    private func remember(userText: String, assistantText: String) {
        conversationMessages.append(BrainMessage(role: .user, content: userText))
        conversationMessages.append(BrainMessage(role: .assistant, content: assistantText))
        trimConversationMessages()
    }

    private func rememberAgentResult(userText: String, contextPacket: AssistantContextPacket) {
        conversationMessages.append(BrainMessage(role: .user, content: userText))
        conversationMessages.append(BrainMessage(role: .assistant, content: contextPacket.brainContextText))
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

    private func createAgentTask(
        directive: AgentDirectiveRequest,
        input: String,
        request: AssistantSessionTurnRequest,
        providerID: ProviderID,
        providerName: String
    ) async -> AssistantTaskID {
        let record = AssistantTaskRecord(
            turnID: request.turnID,
            userRequest: input,
            capabilityID: CapabilityID(rawValue: providerID.rawValue),
            providerID: providerID,
            providerName: providerName,
            mode: directive.mode,
            projectQuery: directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
            diagnosticCorrelationID: request.turnID.rawValue
        )
        let task = await taskLedger.createTask(record)
        return task.id
    }

    private func createSkillTask(
        directive: SkillDirectiveRequest,
        input: String,
        request: AssistantSessionTurnRequest,
        skillID: SkillID
    ) async -> AssistantTaskID {
        let record = AssistantTaskRecord(
            turnID: request.turnID,
            userRequest: input,
            capabilityID: CapabilityID(rawValue: "skill:\(skillID.rawValue)"),
            providerName: directive.skillDisplayName,
            mode: directive.mode,
            projectQuery: directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
            diagnosticCorrelationID: request.turnID.rawValue
        )
        let task = await taskLedger.createTask(record)
        return task.id
    }

    private func recordTaskEvent(
        _ taskID: AssistantTaskID?,
        kind: AssistantTaskEventKind,
        status: AssistantTaskStatus? = nil,
        turnID: BrainRequestID? = nil,
        phase: String? = nil,
        summary: String? = nil,
        metadata: [String: String] = [:],
        mutate: @Sendable (inout AssistantTaskRecord) -> Void = { _ in }
    ) async {
        guard let taskID else {
            return
        }
        await taskLedger.updateTask(
            taskID,
            status: status,
            event: AssistantTaskEvent(
                kind: kind,
                turnID: turnID,
                status: status,
                phase: phase,
                summary: summary,
                metadata: metadata
            ),
            mutate: mutate
        )
    }

    private func recordTaskFailure(
        _ taskID: AssistantTaskID?,
        turnID: BrainRequestID,
        phase: String,
        message: String,
        error: Error? = nil
    ) async {
        var metadata: [String: String] = [:]
        if let error {
            metadata["errorType"] = Self.diagnosticErrorType(error)
        }
        await recordTaskEvent(
            taskID,
            kind: .failed,
            status: .failed,
            turnID: turnID,
            phase: phase,
            summary: message,
            metadata: metadata
        ) { task in
            task.failurePhase = phase
            task.failureMessage = message
        }
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
    private func appendAgentApprovalMessage(
        _ prompt: AgentApprovalPrompt,
        allowsRememberedApproval: Bool = true
    ) -> ChatMessageID {
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
                    requirement: prompt.requirement,
                    allowsRememberedApproval: allowsRememberedApproval ? nil : false
                ),
                status: .pending
            )
        )
    }

    @discardableResult
    private func appendAgentQuestionMessage(_ prompt: AgentQuestionPrompt) -> ChatMessageID {
        let messageID = ChatMessageID.make()
        return appendMessage(
            ChatMessage(
                id: messageID,
                turnID: activeTurnID,
                role: .action,
                source: .localAction,
                text: prompt.title,
                questionRequest: ChatQuestionRequest(
                    id: messageID,
                    title: prompt.title,
                    prompt: prompt
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

    @discardableResult
    private func completeUnfinishedAssistantMessages(
        turnID: BrainRequestID,
        text: String,
        detailsMarkdown: String? = nil,
        status: ChatMessageStatus
    ) -> Bool {
        var changed = false
        for index in messages.indices
        where messages[index].turnID == turnID
            && messages[index].role == .assistant
            && messages[index].status != .completed
            && messages[index].status != .cancelled {
            messages[index].text = text
            messages[index].detailsMarkdown = detailsMarkdown
            messages[index].status = status
            changed = true
        }
        if changed {
            publishMessages()
        }
        return changed
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
        if let activeAssistantTaskID {
            metadata["taskID"] = activeAssistantTaskID.rawValue
        }
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
        if case RocaError.agentProviderSetupRequired = error {
            return "agentProviderSetupRequired"
        }
        return String(describing: type(of: error))
    }

    private nonisolated static func agentProviderSetupResponse(_ status: AgentProviderSetupStatus) -> AssistantResponseContent {
        let summary = status.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.providerID.rawValue == "claude-code",
           status.state == .runtimeMissing,
           let installCommand = status.installCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !installCommand.isEmpty {
            return AssistantResponseContent(
                bubbleText: "\(summary) I can install it for you, or you can install it yourself using the command below.",
                detailsMarkdown: """
                ```sh
                \(installCommand)
                ```
                """
            )
        }

        let message = [summary, status.guidance]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return AssistantResponseContent(bubbleText: message, detailsMarkdown: nil)
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

    private nonisolated static func skillResultFormattingFailureMessage(project: ProjectIdentity, error: Error) -> String {
        if let recoveryMessage = brainRecoveryMessage(for: error, phase: .response) {
            return "I inspected \(project.displayName), but \(recoveryMessage)"
        }
        return "I inspected \(project.displayName), but I couldn't summarize the result: \(error.localizedDescription)"
    }

    private nonisolated static func isRetryRequest(_ input: String) -> Bool {
        let normalized = ProjectIdentityResolver.normalizedKey(input)
        guard !normalized.isEmpty else {
            return false
        }
        return [
            "try again",
            "please try again",
            "can you try again",
            "could you try again",
            "mind trying again",
            "retry",
            "retry that",
            "run it again",
            "do it again",
            "try that again",
            "rerun it",
            "rerun that"
        ].contains(normalized)
            || normalized.hasSuffix("try again")
            || normalized.contains("try that again")
            || normalized.contains("run that again")
            || normalized.contains("rerun that")
    }

    private nonisolated static func isLocalCodebaseFollowUp(_ input: String) -> Bool {
        let normalized = ProjectIdentityResolver.normalizedKey(input)
        guard !normalized.isEmpty,
              !normalized.contains("codex"),
              !normalized.contains("claude"),
              !normalized.contains("cursor")
        else {
            return false
        }

        let codebaseTerms = [
            "any javascript",
            "javascript",
            "typescript",
            "node",
            "nodejs",
            "cdk",
            "infra",
            "infrastructure",
            "deployment",
            "docker",
            "go",
            "python",
            "swift",
            "rust",
            "language",
            "languages",
            "framework",
            "frameworks",
            "package json",
            "go mod",
            "where is",
            "where does",
            "what files",
            "which files",
            "entry point",
            "entry points"
        ]
        return codebaseTerms.contains { normalized.contains($0) }
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

    private nonisolated static func shouldAnswerFromConversation(_ input: String) -> Bool {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        if normalized.contains("selected text")
            || normalized.contains("highlighted text")
            || normalized.contains("current selection") {
            return false
        }
        if normalized.contains("codex")
            || normalized.contains("claude")
            || normalized.contains("cursor") {
            return false
        }

        let asksForSpeech = normalized.contains("out loud")
            || normalized.contains("say it")
            || normalized.contains("say that")
            || normalized.contains("read it")
            || normalized.contains("read that")
            || normalized.contains("tell it")
            || normalized.contains("tell that")
        let asksForVerbalOnly = normalized.contains("don't print")
            || normalized.contains("dont print")
            || normalized.contains("not just print")
            || normalized.contains("not print")
        return asksForSpeech || asksForVerbalOnly
    }

    private nonisolated static func shouldReusePriorAgentContext(
        for input: String,
        directive: AgentDirectiveRequest
    ) -> Bool {
        guard directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              explicitProjectName(from: input) == nil
        else {
            return false
        }
        if directive.mode != .ask {
            return true
        }
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "there",
            "same project",
            "same repo",
            "same codebase",
            "that project",
            "that repo",
            "that file",
            "those files",
            "what about",
            "its ",
            "in it",
            "for it",
            "follow up",
            "continue"
        ].contains { normalized.contains($0) }
    }

    private nonisolated static func shouldReusePriorSkillContext(
        for input: String,
        directive: SkillDirectiveRequest
    ) -> Bool {
        guard directive.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              explicitProjectName(from: input) == nil
        else {
            return false
        }
        if directive.mode != .ask {
            return true
        }
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "there",
            "same project",
            "same repo",
            "same codebase",
            "that project",
            "that repo",
            "that file",
            "those files",
            "what about",
            "its ",
            "in it",
            "for it",
            "follow up",
            "continue"
        ].contains { normalized.contains($0) }
    }

    private enum DeveloperWorkflowKind: String, Sendable {
        case architectureSummary
        case behaviorLocation
        case implementationPlan
        case diffReview

        var promptTitle: String {
            switch self {
            case .architectureSummary:
                "architecture summary"
            case .behaviorLocation:
                "behavior location"
            case .implementationPlan:
                "implementation plan"
            case .diffReview:
                "diff review"
            }
        }

        var prefersPlanMode: Bool {
            switch self {
            case .implementationPlan:
                true
            case .architectureSummary, .behaviorLocation, .diffReview:
                false
            }
        }

        var instruction: String {
            switch self {
            case .architectureSummary:
                "Summarize the architecture and important entry points."
            case .behaviorLocation:
                "Answer where the behavior lives with relevant paths, symbols, and a short flow explanation."
            case .implementationPlan:
                "Draft a concise implementation plan with meaningful tradeoffs, risks, and test notes."
            case .diffReview:
                "Review the current diff or described changes; prioritize bugs, regressions, unclear behavior, and missing tests."
            }
        }
    }

    private nonisolated static func developerWorkflowDirective(
        _ directive: AgentDirectiveRequest,
        userInput: String
    ) -> AgentDirectiveRequest {
        guard let workflowKind = developerWorkflowKind(for: userInput, directive: directive) else {
            return directive
        }

        var updated = directive
        if updated.mode == .ask, workflowKind.prefersPlanMode {
            updated.mode = .plan
        }
        updated.prompt = developerWorkflowPrompt(
            kind: workflowKind,
            userInput: userInput,
            agentPrompt: updated.prompt
        )
        return updated
    }

    private nonisolated static func developerWorkflowSkillDirective(
        _ directive: SkillDirectiveRequest,
        userInput: String
    ) -> SkillDirectiveRequest {
        guard let workflowKind = developerWorkflowKind(for: userInput, directive: directive) else {
            return directive
        }

        var updated = directive
        if updated.mode == .ask, workflowKind.prefersPlanMode {
            updated.mode = .plan
        }
        updated.prompt = developerWorkflowPrompt(
            kind: workflowKind,
            userInput: userInput,
            agentPrompt: updated.prompt
        )
        return updated
    }

    private nonisolated static func developerWorkflowKind(
        for userInput: String,
        directive: AgentDirectiveRequest
    ) -> DeveloperWorkflowKind? {
        developerWorkflowKind(
            for: userInput,
            projectName: directive.projectName,
            prompt: directive.prompt,
            mode: directive.mode
        )
    }

    private nonisolated static func developerWorkflowKind(
        for userInput: String,
        directive: SkillDirectiveRequest
    ) -> DeveloperWorkflowKind? {
        developerWorkflowKind(
            for: userInput,
            projectName: directive.projectName,
            prompt: directive.prompt,
            mode: directive.mode
        )
    }

    private nonisolated static func developerWorkflowKind(
        for userInput: String,
        projectName: String?,
        prompt: String,
        mode: AgentMode
    ) -> DeveloperWorkflowKind? {
        guard mode != .act,
              projectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }

        let text = ProjectIdentityResolver.normalizedKey([userInput, prompt].joined(separator: " "))
        if text.contains("implementation plan")
            || text.contains("implementation options")
            || text.contains("draft a plan")
            || text.contains("make a plan")
            || text.contains("plan for")
            || text.contains("tradeoff")
            || text.contains("trade off") {
            return .implementationPlan
        }
        if text.contains("review the diff")
            || text.contains("review diff")
            || text.contains("diff review")
            || text.contains("review my changes")
            || text.contains("review the changes") {
            return .diffReview
        }
        if text.contains("where does") && (text.contains("live") || text.contains("implemented") || text.contains("happen")) {
            return .behaviorLocation
        }
        if text.contains("where is") && (text.contains("implemented") || text.contains("handled") || text.contains("defined")) {
            return .behaviorLocation
        }
        if text.contains("architecture")
            || text.contains("entry point")
            || text.contains("entry points")
            || text.contains("codebase overview")
            || text.contains("repo overview")
            || text.contains("project overview") {
            return .architectureSummary
        }
        return nil
    }

    private nonisolated static func developerWorkflowPrompt(
        kind: DeveloperWorkflowKind,
        userInput: String,
        agentPrompt: String
    ) -> String {
        let trimmedPrompt = agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.hasPrefix("Roca developer workflow:") else {
            return trimmedPrompt
        }
        let trimmedUserInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Roca developer workflow: \(kind.promptTitle)

        User request:
        \(trimmedUserInput)

        Agent task:
        \(trimmedPrompt)

        Requirements:
        - Inspect only the resolved workspace/project for this request.
        - \(kind.instruction)
        - Prefer file paths, symbols, and short rationale over pasted file contents.
        - Do not paste raw file contents, long command output, or tool progress unless the user explicitly asks.
        - Do not make code changes.
        """
    }

    private nonisolated static func explicitProjectName(from input: String) -> String? {
        let patterns = [
            #"\b(?:and\s+)?(?:what\s+about|how\s+about)(?:\s+for)?\s+(?:the\s+)?([A-Za-z0-9][A-Za-z0-9._-]*[-_][A-Za-z0-9._-]*)\b"#,
            #"\b(?:what\s+about|how\s+about)\s+(?:the\s+)?([A-Za-z0-9][A-Za-z0-9._-]*(?:\s+[A-Za-z0-9][A-Za-z0-9._-]*){0,2})\s+(?:project|repo|repository|codebase)\b"#,
            #"\b(?:other|another)\s+([A-Za-z0-9][A-Za-z0-9._-]*(?:\s+[A-Za-z0-9][A-Za-z0-9._-]*){0,2})\s+(?:project|repo|repository|codebase)\b"#,
            #"\b(?:in|for|from|inside|within)\s+(?:the\s+)?([A-Za-z0-9][A-Za-z0-9._-]*(?:\s+[A-Za-z0-9][A-Za-z0-9._-]*){0,2})\s+(?:project|repo|repository|codebase)\b"#,
            #"\b(?:the\s+)?([A-Za-z0-9][A-Za-z0-9._-]*(?:\s+[A-Za-z0-9][A-Za-z0-9._-]*){0,2})\s+(?:project|repo|repository|codebase)\b"#
        ]
        for pattern in patterns {
            for match in regexCaptures(in: input, pattern: pattern) {
                guard !isNegatedProjectPhrase(match.value, in: input, captureRange: match.range),
                      let cleaned = cleanProjectPhrase(match.value)
                else {
                    continue
                }
                return cleaned
            }
        }
        return nil
    }

    private nonisolated static func firstRegexCapture(in input: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: input)
        else {
            return nil
        }
        return String(input[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func regexCaptures(
        in input: String,
        pattern: String
    ) -> [(value: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.matches(in: input, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: input)
            else {
                return nil
            }
            return (String(input[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines), captureRange)
        }
    }

    private nonisolated static func cleanProjectPhrase(_ phrase: String) -> String? {
        var words = phrase.split(separator: " ").map(String.init)
        let contextualWords = Set(["current", "same", "that", "this", "the", "a", "an", "different", "other", "another", "about"])
        while let first = words.first,
              contextualWords.contains(ProjectIdentityResolver.normalizedKey(first)) {
            words.removeFirst()
        }
        let cleaned = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return isUsableProjectPhrase(cleaned) ? cleaned : nil
    }

    private nonisolated static func isNegatedProjectPhrase(
        _ phrase: String,
        in input: String,
        captureRange: Range<String.Index>
    ) -> Bool {
        let prefix = input[..<captureRange.lowerBound].suffix(12)
        let normalizedPrefix = ProjectIdentityResolver.normalizedKey(String(prefix))
        return normalizedPrefix == "not" || normalizedPrefix.hasSuffix(" not")
    }

    private nonisolated static func isUsableProjectPhrase(_ phrase: String) -> Bool {
        let normalized = ProjectIdentityResolver.normalizedKey(phrase)
        guard !normalized.isEmpty else {
            return false
        }
        let contextualWords = Set(["current", "same", "that", "this", "the", "a", "an", "different", "other"])
        let tokens = normalized.split(separator: " ").map(String.init)
        return !tokens.contains { contextualWords.contains($0) }
    }

    private nonisolated static func excludedProjectNames(from input: String) -> [String] {
        let pattern = #"\bnot\s+(?:the\s+)?([A-Za-z0-9][A-Za-z0-9._-]*(?:\s+[A-Za-z0-9][A-Za-z0-9._-]*){0,2})\s+(?:project|repo|repository|codebase)\b"#
        return regexCaptures(in: input, pattern: pattern).compactMap { cleanProjectPhrase($0.value) }
    }

    private nonisolated static func repairedDirective(from rawText: String) -> AssistantDirective? {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "respond":
            return .respond
        case "readselection", "read_selection":
            return .readSelection
        default:
            return nil
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

    private nonisolated static func agentIntroText(providerName: String, project: ProjectIdentity?, mode: AgentMode) -> String {
        switch mode {
        case .ask:
            if let project {
                return "I'll ask \(providerName) to inspect \(project.displayName) and summarize what it finds."
            }
            return "I'll ask \(providerName) and summarize what it finds."
        case .plan:
            if let project {
                return "I'll ask \(providerName) to plan this in \(project.displayName) and summarize the tradeoffs."
            }
            return "I'll ask \(providerName) to plan this and summarize the tradeoffs."
        case .act:
            if let project {
                return "I'll ask \(providerName) to make that change in \(project.displayName) and summarize what changed."
            }
            return "I'll ask \(providerName) to make that change and summarize what changed."
        }
    }

    private nonisolated static func skillIntroText(
        skillName: String,
        project: ProjectIdentity,
        mode: AgentMode,
        userInput: String,
        prompt: String
    ) -> String {
        let text = ProjectIdentityResolver.normalizedKey([userInput, prompt].joined(separator: " "))
        switch mode {
        case .ask:
            if text.contains("no i mean")
                || text.contains("actually")
                || text.contains("infra")
                || text.contains("infrastructure")
                || text.contains("deployment")
                || text.contains("cdk") {
                return "Got it, I'll look specifically at \(project.displayName)'s infrastructure code."
            }
            if text.contains("what about") {
                return "I'll narrow that down in \(project.displayName)."
            }
            if text.contains("what language")
                || text.contains("which language")
                || text.contains("written in")
                || text.contains("languages") {
                return "I'll check \(project.displayName)'s languages and project structure."
            }
            return "I'll inspect \(project.displayName) locally."
        case .plan:
            return "I'll inspect \(project.displayName) locally and draft a concise plan."
        case .act:
            return "\(skillName) is read-only for now."
        }
    }

    private nonisolated static func speechText(from text: String) -> String {
        let filtered = text.unicodeScalars.filter { !isSpeechEmojiScalar($0) }
        return String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isSpeechEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0xFE0E || scalar.value == 0xFE0F || scalar.value == 0x200D {
            return true
        }
        if scalar.properties.isEmojiPresentation {
            return true
        }
        guard scalar.properties.isEmoji else {
            return false
        }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .modifierSymbol:
            return true
        default:
            return false
        }
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
        For codebase workflow answers, prefer paths, symbols, and compact rationale over raw file contents.
        Do not include raw tool progress, shell commands, or narration about how \(providerName) searched unless it is essential to the answer.
        """
    }

    private nonisolated static func skillResultFormattingPrompt(
        userInput: String,
        skillName: String,
        project: ProjectIdentity,
        localEvidence: String
    ) -> String {
        """
        The user asked Roca to inspect a local project using \(skillName).

        User request:
        \(userInput)

        Project:
        \(project.displayName) at \(project.localPath)

        Local evidence gathered by Roca:
        \(localEvidence)

        Return Roca's final response as JSON using the required bubbleText/detailsMarkdown shape.
        Keep bubbleText short, conversational, and suitable for speech.
        Put paths, entry points, diff-review findings, implementation details, and evidence in detailsMarkdown.
        For language inventory requests, include the primary language and notable secondary languages from the repository map and manifests.
        Do not say JavaScript, TypeScript, Node, or CDK are absent if the evidence shows matching files or manifests.
        Prefer concise path and symbol references over raw file contents.
        Treat the local evidence as an evidence packet, not a complete omniscient view of the repo.
        Answer only from the repository map, search results, diff, and targeted file snippets provided.
        Cite concrete paths when making claims about languages, frameworks, files, entry points, or deployment infrastructure.
        Do not claim something is absent unless the evidence contract says the relevant paths or file types were scanned.
        If the user's correction narrows the scope, acknowledge the corrected scope and answer that scope directly.
        Do not mention hidden tool names unless useful to the answer.
        Do not claim code was changed.
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

    private nonisolated static func normalizedAgentResponse(
        _ response: AssistantResponseContent,
        providerName: String,
        mode: AgentMode,
        rawAgentText: String
    ) -> AssistantResponseContent {
        guard mode == .act else {
            return response
        }
        let paths = relativeFilePaths(in: rawAgentText)
        guard !paths.isEmpty else {
            return response
        }

        var bubble = response.bubbleText
        var details = response.detailsMarkdown
        let visibleText = [bubble, details].compactMap { $0 }.joined(separator: "\n")
        let missingPaths = paths.filter { !visibleText.localizedCaseInsensitiveContains($0) }

        if !missingPaths.isEmpty {
            let section = (["Changed files:"] + paths.map { "- `\($0)`" }).joined(separator: "\n")
            details = [details, section]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
                }
                .joined(separator: "\n\n")
        }

        if paths.count == 1, !bubble.localizedCaseInsensitiveContains(paths[0]) {
            let suffix = "Changed file: \(paths[0])."
            if bubble.count + suffix.count + 1 <= 260 {
                bubble = "\(bubble) \(suffix)"
            } else {
                bubble = "\(providerName) updated \(paths[0])."
            }
        } else if paths.count > 1,
                  !paths.contains(where: { bubble.localizedCaseInsensitiveContains($0) }) {
            bubble = "\(providerName) updated \(paths.count) files, including \(paths[0])."
        }

        return AssistantResponseContent(bubbleText: bubble, detailsMarkdown: details)
    }

    private nonisolated static func relativeFilePaths(in text: String) -> [String] {
        let trimCharacters = CharacterSet(charactersIn: "`'\"()[]{}<>,;:")
        var paths: [String] = []
        var seen = Set<String>()
        for rawToken in text.components(separatedBy: .whitespacesAndNewlines) {
            let token = rawToken
                .trimmingCharacters(in: trimCharacters)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            guard token.contains("/"),
                  !token.hasPrefix("/"),
                  !token.contains("://"),
                  token.range(
                    of: #"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"#,
                    options: .regularExpression
                  ) != nil,
                  token.split(separator: "/").last?.contains(".") == true,
                  seen.insert(token).inserted
            else {
                continue
            }
            paths.append(token)
        }
        return paths
    }
}

private struct AssistantRoutingRecoveryError: LocalizedError {
    var errorDescription: String? {
        "I had trouble understanding that. Please try again."
    }
}

private struct ActiveAssistantSessionListeningSession: Sendable {
    var request: AssistantSessionTurnRequest
    var provider: any STTProvider
    var transcriptTask: Task<String, Error>
    var timing: AssistantTurnTimingBuilder
    var listeningMessageID: ChatMessageID
}

private struct PendingProjectClarification: Sendable {
    var taskID: AssistantTaskID
    var directive: AgentDirectiveRequest
    var originalUserInput: String
    var query: String
    var candidates: [ProjectIdentity]
    var localSkillID: SkillID?
    var providerID: ProviderID?
    var providerName: String
    var createdTurnID: BrainRequestID
    var questionMessageID: ChatMessageID

    var directiveType: AssistantDirectiveType {
        localSkillID == nil ? .runAgent : .runSkill
    }
}

private struct PendingDirectiveRetry: Sendable {
    var directive: AssistantDirective
    var originalUserInput: String
    var resolvedProject: ProjectIdentity?
    var createdAt = Date()

    var isFresh: Bool {
        Date().timeIntervalSince(createdAt) <= 10 * 60
    }
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
        case .runSkill:
            .runSkill
        case .unsupported:
            .unsupported
        }
    }
}
