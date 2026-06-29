import Foundation
import RocaCore
import RocaProviders
import RocaServices
import RocaTestingSupport

public struct InteractionEvalRunner: Sendable {
    private let modelClient: (any EvalBrainClient)?

    public init(modelClient: (any EvalBrainClient)? = nil) {
        self.modelClient = modelClient
    }

    public func run(_ configuration: InteractionEvalRunConfiguration) async throws -> InteractionEvalRunOutput {
        let startedAt = Date()
        var records: [InteractionEvalRecord] = []
        for scenario in configuration.suite.scenarios {
            let scenarioRecords = try await runScenario(
                scenario,
                suite: configuration.suite,
                configuration: configuration
            )
            records.append(contentsOf: scenarioRecords)
        }

        let run = InteractionEvalRunRecord(
            runID: configuration.runID,
            suiteID: configuration.suite.id,
            suiteTitle: configuration.suite.title,
            startedAt: startedAt,
            completedAt: Date(),
            mode: configuration.mode,
            modelID: configuration.modelID,
            scenarioCount: configuration.suite.scenarios.count,
            turnCount: records.count,
            passedTurnCount: records.filter(\.passed).count,
            failedTurnCount: records.filter { !$0.passed }.count,
            expectedFailureCount: records.filter { !$0.passed && $0.expectedFailureReason != nil }.count
        )
        return InteractionEvalRunOutput(run: run, turns: records, outputDirectory: configuration.outputDirectory)
    }

    private func runScenario(
        _ scenario: InteractionEvalScenario,
        suite: InteractionEvalSuite,
        configuration: InteractionEvalRunConfiguration
    ) async throws -> [InteractionEvalRecord] {
        let brain = try brainProvider(for: scenario, configuration: configuration)
        let agentBundle = makeAgent(from: scenario.agent)
        let skillBundle = makeLocalSkill(from: scenario.localSkill)
        let speech = RecordingSessionSpeech()
        let diagnostics = InteractionDiagnosticsRecorder()
        let writer = RecordingProjectWriter()
        let orchestrator = DefaultAssistantSessionOrchestrator(
            resolver: SessionResolver(brain: brain.provider, agent: agentBundle.provider),
            audioInput: NoopSessionAudioInput(),
            inserter: NoopSessionInserter(),
            permissions: AllowingSessionPermissions(),
            speechOrchestrator: speech,
            applicationCommands: RecordingSessionAppCommands(),
            contextProvider: StaticSessionContextProvider(),
            projectCatalog: StaticProjectIdentityCatalog(scenario.projects.map(\.project)),
            projectWriter: writer,
            localSkillWorkers: skillBundle.workers,
            stopSpeech: {}
        )
        let diagnosticsTask = Task {
            for await event in orchestrator.diagnosticUpdates {
                await diagnostics.append(event)
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        defer {
            diagnosticsTask.cancel()
        }

        var records: [InteractionEvalRecord] = []
        for (turnIndex, turn) in scenario.turns.enumerated() {
            let speechStart = await speech.spokenTexts.count
            let diagnosticStart = await diagnostics.events.count
            let agentRequestStart = await agentRequestRecords(from: agentBundle.provider).count
            let skillRequestStart = await skillBundle.requests().count
            let projectWriteStart = await writer.upsertedProjects.count
            let brainRequestStart = await brain.requests().count

            if let approvalPrompt = turn.approvalPrompt {
                try await runApprovalTurn(approvalPrompt, orchestrator: orchestrator)
            } else if let questionPrompt = turn.questionPrompt {
                try await runQuestionTurn(questionPrompt, orchestrator: orchestrator)
            } else if turn.cancelAfterAgentStarts {
                try await runCancellableTurn(turn, orchestrator: orchestrator, agentBundle: agentBundle, configuration: configuration)
            } else {
                await orchestrator.submitText(turn.user, request: sessionRequest(for: turn, configuration: configuration))
            }
            try await Task.sleep(for: .milliseconds(10))

            let messages = await orchestrator.messageSnapshot
            let allSpeech = await speech.spokenTexts
            let allDiagnostics = await diagnostics.events
            let allAgentRequests = await agentRequestRecords(from: agentBundle.provider)
            let allSkillRequests = await skillBundle.requests()
            let allProjectWrites = await writer.upsertedProjects
            let allBrainRequests = await brain.requests()
            let assistantTasks = await orchestrator.taskSnapshot()
            let newSpeech = Array(allSpeech.dropFirst(speechStart))
            let newDiagnostics = Array(allDiagnostics.dropFirst(diagnosticStart))
            let newAgentRequests = Array(allAgentRequests.dropFirst(agentRequestStart))
            let newSkillRequests = Array(allSkillRequests.dropFirst(skillRequestStart))
            let newProjectWrites = Array(allProjectWrites.dropFirst(projectWriteStart))
            let newBrainRequests = Array(allBrainRequests.dropFirst(brainRequestStart))
            let failures = failuresForTurn(
                turn,
                messages: messages,
                spokenTexts: newSpeech,
                agentRequests: newAgentRequests,
                skillRequests: newSkillRequests,
                projectWrites: newProjectWrites,
                diagnostics: newDiagnostics,
                brainRequests: newBrainRequests
            )

            records.append(
                InteractionEvalRecord(
                    runID: configuration.runID,
                    suiteID: suite.id,
                    scenarioID: scenario.id,
                    scenarioTitle: scenario.title,
                    scenarioTags: scenario.tags,
                    turnID: turn.id,
                    turnIndex: turnIndex,
                    userText: turn.user,
                    inputMode: turn.inputMode,
                    outputMode: turn.outputMode,
                    passed: failures.isEmpty,
                    expectedFailureReason: turn.expectedFailureReason,
                    failures: failures,
                    messages: messages,
                    spokenTexts: newSpeech,
                    agentRequests: newAgentRequests,
                    skillRequests: newSkillRequests,
                    projectWrites: newProjectWrites,
                    diagnostics: newDiagnostics,
                    assistantTasks: assistantTasks,
                    brainRequests: newBrainRequests
                )
            )
        }
        return records
    }

    private func brainProvider(
        for scenario: InteractionEvalScenario,
        configuration: InteractionEvalRunConfiguration
    ) throws -> InteractionBrainProviderBundle {
        switch configuration.mode {
        case .scripted:
            let directives = scenario.turns
                .filter { $0.approvalPrompt == nil }
                .map { $0.brain?.directiveJSON ?? #"{"type":"respond"}"# }
            let responses = scenario.turns.compactMap(\.brain?.responseText)
            let provider = SequencedSessionBrainProvider(directiveTexts: directives, responseTexts: responses)
            return InteractionBrainProviderBundle(provider: provider) {
                await provider.recordedRequests.map(InteractionBrainRequestRecord.init)
            }
        case .modelInLoop:
            guard let modelClient else {
                throw EvalError.invalidArguments("Interaction model-in-loop mode requires an EvalBrainClient.")
            }
            guard let modelID = configuration.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty else {
                throw EvalError.invalidArguments("Interaction model-in-loop mode requires --model.")
            }
            let provider = EvalClientBrainProvider(client: modelClient, modelID: modelID)
            return InteractionBrainProviderBundle(provider: provider) {
                await provider.recordedRequests.map(InteractionBrainRequestRecord.init)
            }
        }
    }

    private func makeAgent(from fixture: InteractionAgentFixture?) -> InteractionAgentBundle {
        guard let fixture else {
            return InteractionAgentBundle(provider: nil, hanging: nil)
        }
        let providerID = ProviderID(rawValue: fixture.providerID)
        let candidates = fixture.discoveryCandidates.map(\.candidate)
        switch fixture.kind {
        case .normal:
            let provider = RecordingSessionAgentProvider(
                id: providerID,
                displayName: fixture.displayName,
                responseText: fixture.responseText,
                discoveryCandidates: candidates,
                discoveryError: fixture.discoveryError.map { InteractionFixtureError(message: $0) }
            )
            return InteractionAgentBundle(provider: provider, hanging: nil)
        case .noisy:
            let provider = NoisySessionAgentProvider(
                id: providerID,
                displayName: fixture.displayName,
                responseText: fixture.responseText,
                discoveryCandidates: candidates
            )
            return InteractionAgentBundle(provider: provider, hanging: nil)
        case .hanging:
            let provider = HangingSessionAgentProvider(id: providerID, displayName: fixture.displayName)
            return InteractionAgentBundle(provider: provider, hanging: provider)
        case .setupUnavailable:
            let provider = SetupRequiredSessionAgentProvider(id: providerID, displayName: fixture.displayName)
            return InteractionAgentBundle(provider: provider, hanging: nil)
        }
    }

    private func makeLocalSkill(from fixture: InteractionLocalSkillFixture?) -> InteractionLocalSkillBundle {
        guard let fixture else {
            return InteractionLocalSkillBundle(workers: [], requests: { [] })
        }
        let worker = RecordingLocalSkillWorker(
            skillID: SkillID(rawValue: fixture.skillID),
            displayName: fixture.displayName,
            evidenceMarkdown: fixture.evidenceMarkdown,
            metadata: fixture.metadata
        )
        return InteractionLocalSkillBundle(workers: [worker]) {
            await worker.recordedRequests.map(InteractionSkillRequestRecord.init)
        }
    }

    private func runApprovalTurn(
        _ fixture: InteractionApprovalPromptFixture,
        orchestrator: DefaultAssistantSessionOrchestrator
    ) async throws {
        let requirement = AgentApprovalRequirement(
            providerID: ProviderID(rawValue: fixture.providerID),
            role: .coding,
            mode: fixture.mode,
            workspacePath: fixture.workspacePath,
            dataScopes: fixture.dataScopes,
            actionScopes: fixture.actionScopes
        )
        let prompt = AgentApprovalPrompt(
            requirement: requirement,
            title: fixture.title,
            detail: fixture.detail ?? requirement.detailText
        )
        let decisionTask = Task {
            await orchestrator.requestAgentApprovalDecision(for: prompt)
        }
        try await waitUntil {
            await orchestrator.messageSnapshot.contains { $0.approvalRequest?.requirement == requirement }
        }

        let decision = fixture.decision ?? .cancel
        if let message = await orchestrator.messageSnapshot.first(where: { $0.approvalRequest?.requirement == requirement }) {
            await orchestrator.submitAgentApprovalDecision(message.id, decision: decision)
        }
        _ = try await value(from: decisionTask)
    }

    private func runQuestionTurn(
        _ fixture: InteractionQuestionPromptFixture,
        orchestrator: DefaultAssistantSessionOrchestrator
    ) async throws {
        let prompt = fixture.prompt
        let responseTask = Task {
            await orchestrator.requestAgentQuestionAnswer(for: prompt)
        }
        try await waitUntil {
            await orchestrator.messageSnapshot.contains { $0.questionRequest?.prompt == prompt }
        }

        if let message = await orchestrator.messageSnapshot.first(where: { $0.questionRequest?.prompt == prompt }) {
            await orchestrator.submitAgentQuestionResponse(message.id, response: fixture.response ?? .cancelled)
        }
        _ = try await value(from: responseTask)
    }

    private func runCancellableTurn(
        _ turn: InteractionEvalTurn,
        orchestrator: DefaultAssistantSessionOrchestrator,
        agentBundle: InteractionAgentBundle,
        configuration: InteractionEvalRunConfiguration
    ) async throws {
        let turnTask = Task {
            await orchestrator.submitText(turn.user, request: sessionRequest(for: turn, configuration: configuration))
        }
        if let hanging = agentBundle.hanging {
            try await waitUntil {
                await hanging.recordedRequests.count > 0
            }
        } else {
            try await Task.sleep(for: .milliseconds(50))
        }
        await orchestrator.cancel()
        _ = try await value(from: turnTask)
    }

    private func sessionRequest(
        for turn: InteractionEvalTurn,
        configuration: InteractionEvalRunConfiguration
    ) -> AssistantSessionTurnRequest {
        let providerID: ProviderID = configuration.mode == .modelInLoop
            ? BuiltInProviderIDs.ollamaBrain
            : ProviderID(rawValue: "test-brain")
        let modelID = configuration.modelID ?? "test-model"
        return AssistantSessionTurnRequest(
            turnID: BrainRequestID(rawValue: "\(configuration.runID)-\(turn.id)-\(UUID().uuidString)"),
            transcriptionID: TranscriptionID(rawValue: UUID().uuidString),
            inputMode: turn.inputMode,
            outputMode: turn.outputMode,
            sttProviderID: nil,
            brainSelection: BrainProviderSelection(
                providerID: providerID,
                modelID: modelID,
                displayName: modelID
            ),
            roleSelections: [
                .companionRouter: BrainProviderSelection(providerID: providerID, modelID: modelID, displayName: modelID),
                .generalChat: BrainProviderSelection(providerID: providerID, modelID: modelID, displayName: modelID)
            ],
            locale: "en-US",
            mode: .toggleToTalk,
            speechConfiguration: SpeechConfiguration(providerID: nil, providerVoiceSelections: [:], speed: 1.0, allowFallback: true)
        )
    }

    private func failuresForTurn(
        _ turn: InteractionEvalTurn,
        messages: [ChatMessage],
        spokenTexts: [String],
        agentRequests: [InteractionAgentRequestRecord],
        skillRequests: [InteractionSkillRequestRecord],
        projectWrites: [ProjectIdentity],
        diagnostics: [AssistantDiagnosticEvent],
        brainRequests: [InteractionBrainRequestRecord]
    ) -> [String] {
        guard let expectations = turn.expectations else {
            return []
        }
        var failures: [String] = []

        for expectation in expectations.messages where !messages.contains(where: { matches(message: $0, expectation: expectation) }) {
            failures.append("Missing message expectation: \(describe(expectation))")
        }

        let searchableMessageText = messages
            .map {
                [
                    $0.text,
                    $0.detailsMarkdown,
                    $0.approvalRequest?.title,
                    $0.approvalRequest?.detail,
                    $0.questionRequest?.title,
                    $0.questionRequest?.prompt.questions.map(\.question).joined(separator: "\n")
                ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n")
        for forbidden in expectations.forbiddenMessageTextContains where contains(searchableMessageText, forbidden) {
            failures.append("Forbidden message text appeared: \(forbidden)")
        }
        let searchableDetailsText = messages
            .compactMap(\.detailsMarkdown)
            .joined(separator: "\n")
        for forbidden in expectations.forbiddenDetailsTextContains where contains(searchableDetailsText, forbidden) {
            failures.append("Forbidden details text appeared: \(forbidden)")
        }

        if let expectedSpeech = expectations.spokenTexts, spokenTexts != expectedSpeech {
            failures.append("Spoken texts did not match. Expected \(expectedSpeech), got \(spokenTexts).")
        }
        let searchableSpeech = spokenTexts.joined(separator: "\n")
        for expected in expectations.spokenTextContains where !contains(searchableSpeech, expected) {
            failures.append("Missing spoken text: \(expected)")
        }
        for forbidden in expectations.forbiddenSpeechTextContains where contains(searchableSpeech, forbidden) {
            failures.append("Forbidden spoken text appeared: \(forbidden)")
        }

        if let agentRequestCount = expectations.agentRequestCount, agentRequests.count != agentRequestCount {
            failures.append("Expected \(agentRequestCount) agent requests, got \(agentRequests.count).")
        }
        for expectation in expectations.agentRequests where !agentRequests.contains(where: { matches(agentRequest: $0, expectation: expectation) }) {
            failures.append("Missing agent request expectation: \(describe(expectation))")
        }

        if let skillRequestCount = expectations.skillRequestCount, skillRequests.count != skillRequestCount {
            failures.append("Expected \(skillRequestCount) skill requests, got \(skillRequests.count).")
        }
        for expectation in expectations.skillRequests where !skillRequests.contains(where: { matches(skillRequest: $0, expectation: expectation) }) {
            failures.append("Missing skill request expectation: \(describe(expectation))")
        }

        for expectation in expectations.diagnostics where !diagnostics.contains(where: { matches(diagnostic: $0, expectation: expectation) }) {
            failures.append("Missing diagnostic expectation: \(expectation.kind.rawValue)")
        }

        let brainText = brainRequests
            .flatMap(\.messages)
            .map(\.content)
            .joined(separator: "\n")
        for expected in expectations.memoryContains where !contains(brainText, expected) {
            failures.append("Missing expected context in brain request memory: \(expected)")
        }

        let writtenIDs = Set(projectWrites.map(\.id.rawValue))
        for expectedID in expectations.projectWriteIDs where !writtenIDs.contains(expectedID) {
            failures.append("Missing project write: \(expectedID)")
        }

        return failures
    }

    private func matches(message: ChatMessage, expectation: InteractionMessageExpectation) -> Bool {
        if let role = expectation.role, message.role != role {
            return false
        }
        if let status = expectation.status, message.status != status {
            return false
        }
        if let text = expectation.text, message.text != text {
            return false
        }
        if let textContains = expectation.textContains, !contains(message.text, textContains) {
            return false
        }
        if let detailsContains = expectation.detailsContains, !contains(message.detailsMarkdown ?? "", detailsContains) {
            return false
        }
        if let approvalTitleContains = expectation.approvalTitleContains,
           !contains(message.approvalRequest?.title ?? "", approvalTitleContains) {
            return false
        }
        if let approvalDecision = expectation.approvalDecision,
           message.approvalRequest?.decision != approvalDecision {
            return false
        }
        if let questionTitleContains = expectation.questionTitleContains,
           !contains(message.questionRequest?.title ?? "", questionTitleContains) {
            return false
        }
        return true
    }

    private func matches(
        agentRequest: InteractionAgentRequestRecord,
        expectation: InteractionAgentRequestExpectation
    ) -> Bool {
        if let providerID = expectation.providerID, agentRequest.providerID != providerID {
            return false
        }
        if let workspacePath = expectation.workspacePath, agentRequest.workspacePath != workspacePath {
            return false
        }
        if let promptContains = expectation.promptContains, !contains(agentRequest.prompt, promptContains) {
            return false
        }
        if let mode = expectation.mode, agentRequest.mode != mode {
            return false
        }
        return true
    }

    private func matches(
        skillRequest: InteractionSkillRequestRecord,
        expectation: InteractionSkillRequestExpectation
    ) -> Bool {
        if let skillID = expectation.skillID, skillRequest.skillID != skillID {
            return false
        }
        if let workspacePath = expectation.workspacePath, skillRequest.workspacePath != workspacePath {
            return false
        }
        if let promptContains = expectation.promptContains, !contains(skillRequest.prompt, promptContains) {
            return false
        }
        if let mode = expectation.mode, skillRequest.mode != mode {
            return false
        }
        return true
    }

    private func matches(
        diagnostic: AssistantDiagnosticEvent,
        expectation: InteractionDiagnosticExpectation
    ) -> Bool {
        diagnostic.kind == expectation.kind
            && (expectation.phase == nil || diagnostic.phase == expectation.phase)
            && (expectation.outcome == nil || diagnostic.outcome == expectation.outcome)
    }

    private func describe(_ expectation: InteractionMessageExpectation) -> String {
        [
            expectation.role.map { "role=\($0.rawValue)" },
            expectation.status.map { "status=\($0.rawValue)" },
            expectation.text.map { "text=\($0)" },
            expectation.textContains.map { "contains=\($0)" },
            expectation.detailsContains.map { "details=\($0)" },
            expectation.approvalTitleContains.map { "approval=\($0)" },
            expectation.approvalDecision.map { "decision=\($0.rawValue)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func describe(_ expectation: InteractionAgentRequestExpectation) -> String {
        [
            expectation.providerID.map { "provider=\($0)" },
            expectation.workspacePath.map { "workspace=\($0)" },
            expectation.promptContains.map { "prompt~=\($0)" },
            expectation.mode.map { "mode=\($0.rawValue)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func describe(_ expectation: InteractionSkillRequestExpectation) -> String {
        [
            expectation.skillID.map { "skill=\($0)" },
            expectation.workspacePath.map { "workspace=\($0)" },
            expectation.promptContains.map { "prompt~=\($0)" },
            expectation.mode.map { "mode=\($0.rawValue)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func contains(_ value: String, _ needle: String) -> Bool {
        value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func agentRequestRecords(from provider: (any AgentProvider)?) async -> [InteractionAgentRequestRecord] {
        if let provider = provider as? RecordingSessionAgentProvider {
            let providerID = await provider.id
            let requests = await provider.recordedRequests
            return requests.map { InteractionAgentRequestRecord($0, providerID: providerID) }
        }
        if let provider = provider as? NoisySessionAgentProvider {
            let providerID = await provider.id
            let requests = await provider.recordedRequests
            return requests.map { InteractionAgentRequestRecord($0, providerID: providerID) }
        }
        if let provider = provider as? HangingSessionAgentProvider {
            let providerID = await provider.id
            let requests = await provider.recordedRequests
            return requests.map { InteractionAgentRequestRecord($0, providerID: providerID) }
        }
        return []
    }
}

private struct InteractionAgentBundle: Sendable {
    var provider: (any AgentProvider)?
    var hanging: HangingSessionAgentProvider?
}

private struct InteractionLocalSkillBundle: Sendable {
    var workers: [any LocalSkillWorking]
    var requests: @Sendable () async -> [InteractionSkillRequestRecord]
}

private struct InteractionBrainProviderBundle: Sendable {
    var provider: any BrainProvider
    var requests: @Sendable () async -> [InteractionBrainRequestRecord]
}

private actor InteractionDiagnosticsRecorder {
    private(set) var events: [AssistantDiagnosticEvent] = []

    func append(_ event: AssistantDiagnosticEvent) {
        events.append(event)
    }
}

private actor EvalClientBrainProvider: BrainProvider {
    let id = BuiltInProviderIDs.ollamaBrain
    let displayName = "Ollama Eval Brain"
    let capabilities = BrainCapabilities(
        supportsStreaming: false,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )

    private let client: any EvalBrainClient
    private let modelID: String
    private(set) var recordedRequests: [BrainRequest] = []

    init(client: any EvalBrainClient, modelID: String) {
        self.client = client
        self.modelID = modelID
    }

    func prepare() async throws {}

    func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        var request = request
        request.modelID = request.modelID ?? modelID
        recordedRequests.append(request)
        let text = try await client.complete(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.final(BrainResponse(text: text, usedProvider: id, metadata: [:])))
            continuation.finish()
        }
    }

    func cancel(_ requestID: BrainRequestID) async {}
}

private struct InteractionFixtureError: Error, LocalizedError, Sendable {
    var message: String

    var errorDescription: String? {
        message
    }
}

private enum InteractionTimeoutError: Error {
    case timedOut
}

private func value<T: Sendable>(from task: Task<T, Never>, timeout: Duration = .seconds(2)) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw InteractionTimeoutError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while !(await condition()) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw InteractionTimeoutError.timedOut
        }
        try await group.next()
        group.cancelAll()
    }
}
