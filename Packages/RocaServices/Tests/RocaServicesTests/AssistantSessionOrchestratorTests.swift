import Foundation
import RocaCore
import RocaServices
import RocaTestingSupport
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
func assistantSessionAnswersClaudeAuthSetupLocally() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"claude-code","providerName":"Claude","prompt":"configure auth","mode":"ask"}"#,
        responseText: ""
    )
    let agent = RecordingSessionAgentProvider(
        id: "claude-code",
        displayName: "Claude",
        responseText: "unused"
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "I installed Claude Code, how do I sign in?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let assistant = try #require(await orchestrator.messageSnapshot.last(where: { $0.role == .assistant }))
    #expect(assistant.status == .completed)
    #expect(assistant.metadata?.directiveType == .respond)
    #expect(assistant.text.contains("Settings"))
    #expect(assistant.text.count < 120)
    #expect(assistant.detailsMarkdown?.contains("Claude Code") == true)
    #expect(assistant.detailsMarkdown?.contains("curl -fsSL https://claude.ai/install.sh | bash") == true)
    #expect(assistant.detailsMarkdown?.contains("API key") == false)
    #expect(assistant.detailsMarkdown?.contains("Keychain") == false)
    #expect(assistant.detailsMarkdown?.contains("CLAUDE_CODE_USE_BEDROCK") == false)
    #expect(await brain.recordedRequests.isEmpty)
    #expect(await agent.recordedRequests.isEmpty)
}

@Test
func assistantSessionInstallsClaudeCodeAfterApproval() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"claude-code","providerName":"Claude","projectName":"sample-auth","prompt":"what login endpoints exist?","mode":"ask"}"#,
        responseText: ""
    )
    let agent = SetupRequiredSessionAgentProvider(
        displayName: "Claude Code",
        summary: "Claude Code CLI is not installed."
    )
    let installer = RecordingProviderSetupInstaller(
        result: ProviderSetupInstallResult(
            exitCode: 0,
            output: "installed ok",
            postInstallNotes: ["Added ~/.local/bin to PATH in ~/.zshrc. Open a new Terminal and run `claude --version`."]
        )
    )
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        providerSetupInstaller: installer,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Ask Claude in Sample Auth what login endpoints exist.",
        request: sessionRequest(outputMode: .textOnly)
    )
    let setupFailure = try #require(await orchestrator.messageSnapshot.last(where: { $0.role == .assistant }))
    #expect(setupFailure.text.contains("Claude Code CLI is not installed"))
    #expect(setupFailure.detailsMarkdown?.contains("curl -fsSL https://claude.ai/install.sh | bash") == true)

    let installTurn = Task {
        await orchestrator.submitText(
            "Can you install it for me?",
            request: sessionRequest(inputMode: .voice, outputMode: .speakAll)
        )
    }
    try await waitUntil {
        await orchestrator.messageSnapshot.contains { $0.approvalRequest?.title == "Install Claude Code" }
    }

    let approvalMessage = try #require(await orchestrator.messageSnapshot.first { $0.approvalRequest?.title == "Install Claude Code" })
    #expect(approvalMessage.approvalRequest?.allowsRememberedApproval == false)
    #expect(approvalMessage.approvalRequest?.detail.contains("curl -fsSL https://claude.ai/install.sh | bash") == true)
    #expect(approvalMessage.approvalRequest?.detail.contains("~/.local/bin") == true)

    await orchestrator.submitAgentApprovalDecision(approvalMessage.id, decision: .approve)
    await installTurn.value

    #expect(await installer.requests == [
        ProviderSetupInstallRequest(
            providerID: ProviderID(rawValue: "claude-code"),
            displayName: "Claude Code",
            installCommand: "curl -fsSL https://claude.ai/install.sh | bash"
        )
    ])
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "Got it. I'll let you know once Claude Code is done installing." })
    #expect(messages.contains { $0.role == .action && $0.text == "Claude Code installer finished." })
    let assistant = try #require(messages.last(where: { $0.role == .assistant }))
    #expect(assistant.text.contains("Claude Code installer finished"))
    #expect(assistant.detailsMarkdown?.contains("installed ok") == true)
    #expect(assistant.detailsMarkdown?.contains("Setup Notes") == true)
    #expect(assistant.detailsMarkdown?.contains("~/.zshrc") == true)
    #expect(await speech.spokenTexts.contains("Got it. I'll let you know once Claude Code is done installing."))
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
    #expect(user.metadata?.directivePromptVersion == AssistantPromptCatalog.directivePromptVersion)
    #expect(user.metadata?.responsePromptVersion == AssistantPromptCatalog.responsePromptVersion)
    #expect(assistant.metadata?.directiveType == .respond)
    #expect(assistant.metadata?.brainModelID == "test-model")
}

@Test
func assistantSessionUsesRoleSpecificBrainModels() async throws {
    let brain = ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Hey.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "hello",
        request: sessionRequest(
            outputMode: .textOnly,
            roleSelections: [
                .companionRouter: BrainProviderSelection(
                    providerID: ProviderID(rawValue: "test-brain"),
                    modelID: "router-model",
                    displayName: "Router Model"
                ),
                .generalChat: BrainProviderSelection(
                    providerID: ProviderID(rawValue: "test-brain"),
                    modelID: "chat-model",
                    displayName: "Chat Model"
                )
            ]
        )
    )

    let requests = await brain.recordedRequests
    let routerRequest = try #require(requests.first { $0.role == .companionRouter })
    let chatRequest = try #require(requests.first { $0.role == .generalChat })
    #expect(routerRequest.modelID == "router-model")
    #expect(chatRequest.modelID == "chat-model")

    let messages = await orchestrator.messageSnapshot
    let user = try #require(messages.first { $0.role == .user })
    let assistant = try #require(messages.first { $0.role == .assistant })
    #expect(user.metadata?.brainModelID == "router-model")
    #expect(assistant.metadata?.brainModelID == "chat-model")
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
func assistantSessionRetriesSmallerSpeechChunksWhenProviderRejectsLength() async throws {
    let longResponse = [
        "The top five orders are ranked by service fee size with exact values and supporting details.",
        "Rank one is a refund order with the largest service fee.",
        "Rank two is a purchase order, and rank three is an adjustment order."
    ].joined(separator: " ")
    let speech = RecordingSessionSpeech(chunkCharacterLimit: 420, maximumAcceptedCharacters: 120)
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

    await orchestrator.submitText("read the service fee summary out loud", request: sessionRequest(outputMode: .speakAll))

    let spokenTexts = await speech.spokenTexts
    #expect(spokenTexts.count > 1)
    #expect(spokenTexts.allSatisfy { $0.count <= 120 })
    #expect(spokenTexts.joined(separator: " ") == longResponse)
    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.role == .status && $0.status == .failed })
}

@Test
func assistantSessionExpandsDollarAmountsForSpeechOnly() async throws {
    let bubble = "Total order value is $2.50M, average per order is $42.25, and the largest entry is $5,000.00."
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"respond"}"#,
                responseText: #"{"bubbleText":"\#(bubble)","detailsMarkdown":null}"#
            )
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("summarize this out loud", request: sessionRequest(outputMode: .speakAll))

    let assistant = try #require(await orchestrator.messageSnapshot.last { $0.role == .assistant })
    #expect(assistant.text == bubble)
    #expect(await speech.spokenTexts == [
        "Total order value is 2.50 million dollars, average per order is 42 dollars and 25 cents, and the largest entry is 5,000 dollars."
    ])
}

@Test
func assistantSessionUsesGenerousTimeoutForAssistantResponses() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"respond"}"#,
        responseText: #"{"bubbleText":"Sure thing.","detailsMarkdown":null}"#
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("hello", request: sessionRequest(outputMode: .textOnly))

    let requests = await brain.recordedRequests
    let routingRequest = try #require(requests.first { $0.role == .companionRouter })
    let responseRequest = try #require(requests.first { $0.role == .generalChat })
    #expect(routingRequest.metadata[BrainRequestMetadataKeys.requestTimeoutSeconds] == nil)
    #expect(responseRequest.metadata[BrainRequestMetadataKeys.requestTimeoutSeconds] == "300")
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
func assistantSessionRunsResolvedAgentProjectWithMockProvider() async throws {
    let agent = RecordingSessionAgentProvider(responseText: "Codex says sample-auth supports login registration.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"what login endpoints exist?","mode":"ask"}"#,
                responseText: ###"{"bubbleText":"Codex says sample-auth supports login registration.","detailsMarkdown":null}"###
            ),
            agent: agent
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(
                id: "sample-auth",
                displayName: "Sample Auth",
                aliases: ["sample-auth"],
                localPath: "/workspace/sample-auth"
            )
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about sample-auth", request: sessionRequest(outputMode: .textOnly))

    let agentRequest = try #require(await agent.recordedRequests.first)
    #expect(agentRequest.workspacePath == "/workspace/sample-auth")
    #expect(agentRequest.prompt == "what login endpoints exist?")
    #expect(agentRequest.mode == .ask)
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text.contains("ask Codex") })
    #expect(messages.contains { $0.role == .action && $0.text == "Codex finished." })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Codex says sample-auth supports login registration." })
}

@Test
func assistantSessionShapesDeveloperWorkflowArchitectureRequest() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Top-Level Files
        - Package.swift
        - RocaMac
        - Packages/RocaServices
        """
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runSkill","skillID":"codebase","projectName":"roca","prompt":"summarize architecture and important entry points","mode":"ask"}"#,
                responseText: ###"{"bubbleText":"I inspected Roca locally and found the main entry points.","detailsMarkdown":"## Entry points\n- RocaMac/App"}"###
            )
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "roca", displayName: "Roca", aliases: ["roca"], localPath: "/workspace/roca")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "In the Roca repo, summarize architecture and important entry points.",
        request: sessionRequest(outputMode: .textOnly)
    )

    let request = try #require(await skill.recordedRequests.first)
    #expect(request.project.localPath == "/workspace/roca")
    #expect(request.mode == .ask)
    #expect(request.metadata["workflowKind"] == "architectureSummary")
    #expect(request.prompt.contains("Roca developer workflow: architecture summary"))
    #expect(request.prompt.contains("Inspect only the resolved workspace/project"))
    #expect(request.prompt.contains("Prefer file paths, symbols, and short rationale"))
    #expect(request.prompt.contains("Do not make code changes."))

    let task = try #require(await orchestrator.taskSnapshot().first)
    #expect(task.events.contains { event in
        event.kind == .skillRunStarted
            && event.metadata["workflowKind"] == "architectureSummary"
    })
}

@Test
func assistantSessionFallsBackToSkillEvidenceWhenFormattingTimesOut() async throws {
    let skill = RecordingLocalSkillWorker(
        skillID: SkillID(rawValue: "spreadsheet"),
        displayName: "Spreadsheet Skill",
        evidenceMarkdown: """
        # Spreadsheet Skill Evidence

        ## Workbook
        - File: `/workspace/sales.csv`
        - Format: CSV

        ## Workbook summary
        sales has 15 data rows and 14 columns.

        ## Column Profiles
        | Column | Non-empty |
        | --- | --- |
        | Revenue | 15 |
        """,
        metadata: ["toolCount": "1", "filesScanned": "1", "evidenceCharacters": "250"]
    )
    let brain = TimeoutSummaryBrainProvider(
        directiveJSON: #"{"type":"runSkill","skillID":"spreadsheet","projectName":"sales report","prompt":"summarize the spreadsheet","mode":"ask"}"#
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sales-report", displayName: "Sales Report", aliases: ["sales report"], localPath: "/workspace/sales.csv")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you summarize the sales report spreadsheet?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.status == .failed || $0.status == .streaming })
    #expect(messages.contains { $0.role == .action && $0.text == "Spreadsheet Skill finished." && $0.status == .completed })
    let assistant = try #require(messages.last { $0.role == .assistant })
    #expect(assistant.status == .completed)
    #expect(assistant.text.contains("sales has 15 data rows and 14 columns"))
    #expect(assistant.detailsMarkdown?.contains("Formatting Timeout") == true)
    #expect(assistant.detailsMarkdown?.contains("Spreadsheet Skill Evidence") == true)

    let task = try #require(await orchestrator.taskSnapshot().first)
    #expect(task.status == .completed)
    #expect(task.events.contains { event in
        event.kind == .resultFormatted
            && event.metadata["formattingFallback"] == "providerTimedOut"
    })
}

@Test
func assistantSessionResolvesSpreadsheetFileFromDownloadsContext() async throws {
    let home = try temporaryWorkspaceWorkFolderForSession()
    let downloads = home.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let fileURL = downloads.appendingPathComponent("sample-orders.csv")
    try "Name,Amount\nA,10\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let skill = RecordingLocalSkillWorker(
        skillID: SkillID(rawValue: "spreadsheet"),
        displayName: "Spreadsheet Skill",
        evidenceMarkdown: """
        # Spreadsheet Skill Evidence

        ## Workbook
        - File: `\(fileURL.path)`
        - Format: CSV

        ## Workbook summary
        sample orders has 1 data row and 2 columns.
        """,
        metadata: ["toolCount": "1", "filesScanned": "1", "evidenceCharacters": "220"]
    )
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runSkill","skillID":"spreadsheet","projectName":"sample-orders.csv","prompt":"summarize the spreadsheet","mode":"ask"}"#,
        responseText: #"{"bubbleText":"I summarized the CSV.","detailsMarkdown":"sample orders has 1 data row and 2 columns."}"#
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        localSkillWorkers: [skill],
        userHomeDirectory: home,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you summarize the sample-orders.csv file in the Downloads folder?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let request = try #require(await skill.recordedRequests.first)
    #expect(request.project.displayName == "sample-orders.csv")
    #expect(request.project.localPath == fileURL.path)
    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.text.contains("project folder") })
    #expect(messages.contains { $0.role == .action && $0.text == "Spreadsheet Skill finished." && $0.status == .completed })
    #expect(messages.contains { $0.role == .assistant && $0.text == "I summarized the CSV." && $0.status == .completed })
}

@Test
func assistantSessionReusesResolvedSpreadsheetFileForFollowUp() async throws {
    let home = try temporaryWorkspaceWorkFolderForSession()
    let downloads = home.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let fileURL = downloads.appendingPathComponent("sample-orders.csv")
    try "Order ID,Service Fee (Local),Total\none,25,100\ntwo,50,200\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let skill = RecordingLocalSkillWorker(
        skillID: SkillID(rawValue: "spreadsheet"),
        displayName: "Spreadsheet Skill",
        evidenceMarkdown: """
        # Spreadsheet Skill Evidence

        ## Workbook
        - File: `\(fileURL.path)`
        - Format: CSV

        ## Workbook summary
        sample orders has 2 data rows and 3 columns.
        """,
        metadata: ["toolCount": "1", "filesScanned": "1", "evidenceCharacters": "240"]
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"spreadsheet","projectName":"sample-orders.csv","prompt":"summarize the spreadsheet","mode":"ask"}"#,
            #"{"type":"runSkill","skillID":"spreadsheet","projectName":"sample-orders.csv","prompt":"top five orders by service fee","mode":"ask"}"#
        ],
        responseTexts: [
            #"{"bubbleText":"I summarized the CSV.","detailsMarkdown":"sample orders has 2 rows."}"#,
            #"{"bubbleText":"The top service-fee order is two.","detailsMarkdown":"| Order ID | Service Fee |\n|---|---:|\n| two | 50 |"}"#
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        localSkillWorkers: [skill],
        userHomeDirectory: home,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you summarize the sample-orders.csv file in the Downloads folder?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "What are the top five orders by service fee?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let requests = await skill.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.project.localPath == fileURL.path })
    #expect(requests[1].prompt.contains("top five orders by service fee"))
    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.text.contains("couldn't find or access") })
    #expect(messages.contains { $0.role == .assistant && $0.text == "The top service-fee order is two." })
}

@Test
func assistantSessionRecoversSpreadsheetFollowUpFromRespondDirective() async throws {
    let home = try temporaryWorkspaceWorkFolderForSession()
    let downloads = home.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let fileURL = downloads.appendingPathComponent("sample-orders.csv")
    try "Order ID,Service Fee (Local),Total\none,25,100\ntwo,50,200\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let skill = RecordingLocalSkillWorker(
        skillID: SkillID(rawValue: "spreadsheet"),
        displayName: "Spreadsheet Skill",
        evidenceMarkdown: """
        # Spreadsheet Skill Evidence

        ## Workbook
        - File: `\(fileURL.path)`
        - Format: CSV

        ## Workbook summary
        sample orders has 2 data rows and 3 columns.
        """,
        metadata: ["toolCount": "1", "filesScanned": "1", "evidenceCharacters": "240"]
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"spreadsheet","projectName":"sample-orders.csv","prompt":"summarize the spreadsheet","mode":"ask"}"#,
            #"{"type":"respond"}"#
        ],
        responseTexts: [
            #"{"bubbleText":"I summarized the CSV.","detailsMarkdown":"sample orders has 2 rows."}"#,
            #"{"bubbleText":"The top service-fee order is two.","detailsMarkdown":"| Order ID | Service Fee |\n|---|---:|\n| two | 50 |"}"#
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        localSkillWorkers: [skill],
        userHomeDirectory: home,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you summarize the sample-orders.csv file in the Downloads folder?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "What are the top five orders by service fee?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let requests = await skill.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.project.localPath == fileURL.path })
    #expect(requests[1].prompt.contains("Follow-up question"))
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "The top service-fee order is two." })
}

@Test
func assistantSessionKeepsSpreadsheetRankingDetailsVisualByDefault() async throws {
    let home = try temporaryWorkspaceWorkFolderForSession()
    let fileURL = home.appendingPathComponent("orders.csv")
    try "Order ID,Service Fee\norder-a,90\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let details = """
    ### Top 5 Orders by Service Fee

    | Rank | Order ID | Service Fee |
    |------|-------|---------------------|
    | 1 | order-a | 90 |
    | 2 | order-b | 70 |
    """
    let longBubble = "The top five orders by Service Fee are: 1) $90.00 (Order ID: order-a), 2) $70.00 (Order ID: order-b), 3) $50.00 (Order ID: order-c), 4) $30.00 (Order ID: order-d), and 5) $10.00 (Order ID: order-e)."
    let skill = RecordingLocalSkillWorker(
        skillID: SkillID(rawValue: "spreadsheet"),
        displayName: "Spreadsheet Skill",
        evidenceMarkdown: "# Spreadsheet Skill Evidence\n\n## Calculation\nTop service fees are available.",
        metadata: ["toolCount": "1", "filesScanned": "1", "evidenceCharacters": "180"]
    )
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runSkill","skillID":"spreadsheet","projectName":"orders","prompt":"top five orders by service fee","mode":"ask"}"#,
        responseText: #"{"bubbleText":"\#(longBubble)","detailsMarkdown":"\#(details.replacingOccurrences(of: "\n", with: "\\n"))"}"#
    )
    let speech = RecordingSessionSpeech(chunkCharacterLimit: 420)
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "orders", displayName: "Orders", aliases: ["orders"], localPath: fileURL.path)
        ]),
        localSkillWorkers: [skill],
        userHomeDirectory: home,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What are the top five orders by service fee?",
        request: sessionRequest(outputMode: .speakAll)
    )

    let assistant = try #require(await orchestrator.messageSnapshot.last { $0.role == .assistant })
    #expect(assistant.text == "I found the top rows and put the table below.")
    #expect(assistant.detailsMarkdown?.contains("order-a") == true)
    let spokenTexts = await speech.spokenTexts
    #expect(spokenTexts.contains("I found the top rows and put the table below."))
    #expect(spokenTexts.allSatisfy { !$0.contains("order-a") })
}

@Test
func assistantSessionReadsSpreadsheetDetailsOutLoudOnExplicitFollowUp() async throws {
    let home = try temporaryWorkspaceWorkFolderForSession()
    let fileURL = home.appendingPathComponent("orders.csv")
    try "Order ID,Service Fee\norder-a,90\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let details = """
    ### Top 5 Orders by Service Fee

    | Rank | Order ID | Service Fee |
    |------|-------|---------------------|
    | 1 | order-a | 90 |
    | 2 | order-b | 70 |
    """
    let longBubble = "The top five orders by Service Fee are: 1) $90.00 (Order ID: order-a), 2) $70.00 (Order ID: order-b), 3) $50.00 (Order ID: order-c), 4) $30.00 (Order ID: order-d), and 5) $10.00 (Order ID: order-e)."
    let spokenFollowUp = "Sure. The top service fee is 90, followed by 70. Those are both from the Service Fee column."
    let skill = RecordingLocalSkillWorker(
        skillID: SkillID(rawValue: "spreadsheet"),
        displayName: "Spreadsheet Skill",
        evidenceMarkdown: "# Spreadsheet Skill Evidence\n\n## Calculation\nTop service fees are available.",
        metadata: ["toolCount": "1", "filesScanned": "1", "evidenceCharacters": "180"]
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"spreadsheet","projectName":"orders","prompt":"top five orders by service fee","mode":"ask"}"#,
            #"{"type":"readSelection"}"#
        ],
        responseTexts: [
            #"{"bubbleText":"\#(longBubble)","detailsMarkdown":"\#(details.replacingOccurrences(of: "\n", with: "\\n"))"}"#,
            #"{"bubbleText":"\#(spokenFollowUp)","detailsMarkdown":null}"#
        ]
    )
    let speech = RecordingSessionSpeech(chunkCharacterLimit: 420)
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "orders", displayName: "Orders", aliases: ["orders"], localPath: fileURL.path)
        ]),
        localSkillWorkers: [skill],
        userHomeDirectory: home,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What are the top five orders by service fee?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "Can you tell it to me out loud?",
        request: sessionRequest(outputMode: .speakAll)
    )

    let assistant = try #require(await orchestrator.messageSnapshot.last { $0.role == .assistant })
    #expect(assistant.text == spokenFollowUp)
    #expect(assistant.detailsMarkdown == nil)
    #expect(await speech.spokenTexts == [spokenFollowUp])
}

@Test
func assistantSessionUsesSpreadsheetMissingFileCopy() async throws {
    let home = try temporaryWorkspaceWorkFolderForSession()
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runSkill","skillID":"spreadsheet","projectName":"missing.csv","prompt":"summarize the spreadsheet","mode":"ask"}"#,
        responseText: ""
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        localSkillWorkers: [
            RecordingLocalSkillWorker(
                skillID: SkillID(rawValue: "spreadsheet"),
                displayName: "Spreadsheet Skill",
                evidenceMarkdown: "unused"
            )
        ],
        userHomeDirectory: home,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you summarize the missing.csv file in the Downloads folder?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let messages = await orchestrator.messageSnapshot
    let assistant = try #require(messages.last(where: { $0.role == ChatMessageRole.assistant }))
    #expect(assistant.text.contains("spreadsheet file"))
    #expect(assistant.text.contains("project folder") == false)
}

@Test
func assistantSessionRoutesProviderlessDeveloperWorkflowAgentDirectiveToCodebaseSkill() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Top-Level Files
        - README.md
        - Packages
        """
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","projectName":"roca","prompt":"summarize architecture and important entry points","mode":"ask"}"#,
                responseText: ###"{"bubbleText":"I inspected Roca locally and found the main entry points.","detailsMarkdown":"## Entry points\n- Packages"}"###
            )
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "roca", displayName: "Roca", aliases: ["roca"], localPath: "/workspace/roca")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "In the Roca repo, summarize architecture and important entry points.",
        request: sessionRequest(outputMode: .textOnly)
    )

    let request = try #require(await skill.recordedRequests.first)
    #expect(request.skillID.rawValue == "codebase")
    #expect(request.project.localPath == "/workspace/roca")
    #expect(request.prompt.contains("Roca developer workflow: architecture summary"))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "I'll inspect Roca locally." })
    #expect(messages.contains { $0.role == .action && $0.text == "Local scan complete." })
}

@Test
func assistantSessionPromotesDeveloperWorkflowPlanRequestsToPlanMode() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Search Results
        Packages/RocaCore/Sources/RocaCore/Assistant.swift:1
        """
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runSkill","skillID":"codebase","projectName":"sample-auth","prompt":"draft an implementation plan for login recovery with tradeoffs","mode":"ask"}"#,
                responseText: ###"{"bubbleText":"I drafted the local implementation plan.","detailsMarkdown":"## Plan\n- Trace login recovery entry points."}"###
            )
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "For the Sample Auth repo, draft an implementation plan for login recovery and tradeoffs.",
        request: sessionRequest(outputMode: .textOnly)
    )

    let request = try #require(await skill.recordedRequests.first)
    #expect(request.project.localPath == "/workspace/sample-auth")
    #expect(request.mode == .plan)
    #expect(request.metadata["workflowKind"] == "implementationPlan")
    #expect(request.prompt.contains("Roca developer workflow: implementation plan"))
    #expect(request.prompt.contains("Draft a concise implementation plan with meaningful tradeoffs"))

    let task = try #require(await orchestrator.taskSnapshot().first)
    #expect(task.mode == .plan)
}

@Test
func assistantSessionCompletesFailedSkillSummaryBubbleAndRetries() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Language Summary
        - Go files: 42
        - JavaScript files: 3
        """
    )
    let brain = FailingFirstSummaryBrainProvider(
        directiveJSON: #"{"type":"runSkill","skillID":"codebase","projectName":"sample-auth","prompt":"what language is the project in?","mode":"ask"}"#,
        responseText: ###"{"bubbleText":"Sample Auth is mostly Go, with some JavaScript infrastructure code.","detailsMarkdown":"## Languages\n- Go\n- JavaScript"}"###
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Hey Roca, what language is the sample-auth project in?",
        request: sessionRequest(outputMode: .textOnly)
    )

    var messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.status == .streaming })
    #expect(messages.contains { $0.role == .action && $0.text == "Local scan complete." && $0.status == .completed })
    #expect(messages.contains { message in
        message.role == .assistant
            && message.status == .failed
            && message.text.contains("I inspected Sample Auth, but I can't reach your assistant brain")
    })
    #expect(await skill.recordedRequests.count == 1)

    await orchestrator.submitText("Mind trying again?", request: sessionRequest(outputMode: .textOnly))

    messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.status == .streaming })
    #expect(messages.contains { message in
        message.role == .assistant
            && message.status == .completed
            && message.text == "Sample Auth is mostly Go, with some JavaScript infrastructure code."
            && message.detailsMarkdown == "## Languages\n- Go\n- JavaScript"
    })
    #expect(await skill.recordedRequests.count == 2)
    #expect(await brain.companionRouterRequestCount == 1)
}

@Test
func assistantSessionRecoversUnsupportedExplicitRepoFollowUpToLocalSkill() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Language Summary
        - Go files: 42
        - JavaScript files: 3
        """
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"codebase","projectName":"sample-auth","prompt":"what language is the project in?","mode":"ask"}"#,
            #"{"type":"unsupported","message":"No local context available for 'nova-backend' repo."}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Sample Auth is primarily Go.","detailsMarkdown":"## Languages\n- Go\n- JavaScript infrastructure"}"###,
            ###"{"bubbleText":"Nova Backend is primarily Go too.","detailsMarkdown":"## Languages\n- Go\n- JavaScript infrastructure"}"###
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth"),
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What language is the sample-auth project in?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "Great, and what about the nova-backend repo?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let requests = await skill.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.first?.project.localPath == "/workspace/sample-auth")
    #expect(requests.last?.project.localPath == "/workspace/nova-backend")
    #expect(requests.last?.prompt == "what language is the project in?")

    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.text.contains("No local context available") })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Nova Backend is primarily Go too." })
}

@Test
func assistantSessionUsesBareProjectSlugInsteadOfPriorLocalSkillProject() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Language Summary
        - Go files: 42
        """
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"codebase","projectName":"sample-auth","prompt":"what language is the project in?","mode":"ask"}"#,
            #"{"type":"runSkill","skillID":"codebase","prompt":"what language is the project in?","mode":"ask"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Sample Auth is primarily Go.","detailsMarkdown":null}"###,
            ###"{"bubbleText":"Nova Backend is primarily Go.","detailsMarkdown":null}"###
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth"),
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What language is the sample-auth repo in?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "And what about for nova-backend?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let requests = await skill.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.first?.project.localPath == "/workspace/sample-auth")
    #expect(requests.last?.project.localPath == "/workspace/nova-backend")

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "I'll narrow that down in Nova Backend." })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Nova Backend is primarily Go." })
}

@Test
func assistantSessionDoesNotTreatHyphenatedSearchTermAsProjectSlug() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Search Results
        routes/login-routes.ts:1
        """
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"codebase","projectName":"sample-auth","prompt":"what endpoints are supported for logins?","mode":"ask"}"#,
            #"{"type":"runSkill","skillID":"codebase","prompt":"look for login-routes","mode":"ask"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Sample Auth has login endpoints.","detailsMarkdown":null}"###,
            ###"{"bubbleText":"I found login-routes in Sample Auth.","detailsMarkdown":"## Evidence\n- `routes/login-routes.ts`"}"###
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth"),
            ProjectIdentity(id: "login-routes", displayName: "Login Routes", aliases: ["login-routes"], localPath: "/workspace/login-routes")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What endpoints are supported for logins in the sample-auth repo?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "Look for login-routes in that repo.",
        request: sessionRequest(outputMode: .textOnly)
    )

    let requests = await skill.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.last?.project.localPath == "/workspace/sample-auth")
    #expect(requests.last?.project.localPath != "/workspace/login-routes")
    #expect(requests.last?.prompt == "look for login-routes")

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "I found login-routes in Sample Auth." })
}

@Test
func assistantSessionRerunsLocalSkillForShortLanguageFollowUp() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Language And Manifest Inventory
        ### Languages
        - Go: 42 files
        - JavaScript: 5 files

        ### Manifests
        - `go.mod`: Go module
        - `infra/package.json`: Node package
        - `infra/cdk.json`: AWS CDK app
        """
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"codebase","projectName":"nova-backend","prompt":"what language is the project in?","mode":"ask"}"#,
            #"{"type":"respond"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Nova Backend is primarily Go.","detailsMarkdown":null}"###,
            ###"{"bubbleText":"Yes, Nova Backend has JavaScript infrastructure under infra.","detailsMarkdown":"## Evidence\n- `infra/package.json`: Node package\n- `infra/cdk.json`: AWS CDK app"}"###
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What language is the nova-backend project in?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("Any javascript?", request: sessionRequest(outputMode: .textOnly))

    let requests = await skill.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.last?.project.localPath == "/workspace/nova-backend")
    #expect(requests.last?.prompt.contains("Follow-up question:\nAny javascript?") == true)

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Yes, Nova Backend has JavaScript infrastructure under infra."
            && message.detailsMarkdown?.contains("infra/package.json") == true
    })
}

@Test
func assistantSessionVerifiesAbsenceClaimWhenPriorEvidenceIsPartial() async throws {
    let skill = RecordingLocalSkillWorker(
        evidenceMarkdown: """
        # Codebase Skill Evidence
        ## Repository Map
        ```text
        - Files scanned: 10
        ```
        ## Evidence Contract
        Roca inspected a bounded subset. Treat absence claims as uncertain.
        """
    )
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"codebase","projectName":"nova-backend","prompt":"what language is the project in?","mode":"ask"}"#,
            #"{"type":"respond"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Nova Backend is mostly Go.","detailsMarkdown":null}"###,
            ###"{"bubbleText":"I checked again. Nova Backend has JavaScript infrastructure too.","detailsMarkdown":"## Evidence\n- `infra/package.json`"}"###
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What language is the nova-backend project in?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("So no JavaScript then?", request: sessionRequest(outputMode: .textOnly))

    let requests = await skill.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.last?.prompt.contains("Follow-up question:\nSo no JavaScript then?") == true)

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "I checked again. Nova Backend has JavaScript infrastructure too." })
}

@Test
func assistantSessionRetriesSkillFormattingWithTightEvidenceAfterContextOverflow() async throws {
    let largeEvidence = """
    # Codebase Skill Evidence

    ## Workspace
    - Project: Nova Backend

    ## Targeted File Evidence
    \(String(repeating: "- very large evidence line\n", count: 2_000))

    ## Evidence Contract
    Answer only from gathered evidence.
    \(String(repeating: "- large contract line\n", count: 1_000))
    """
    let skill = RecordingLocalSkillWorker(evidenceMarkdown: largeEvidence)
    let brain = ContextOverflowFirstSummaryBrainProvider(
        directiveJSON: #"{"type":"runSkill","skillID":"codebase","projectName":"nova-backend","prompt":"summarize architecture","mode":"ask"}"#,
        responseText: ###"{"bubbleText":"I summarized Nova Backend with the tighter evidence packet.","detailsMarkdown":"## Summary\n- The scan was budgeted."}"###
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend")
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "In the nova-backend repo, summarize architecture.",
        request: sessionRequest(outputMode: .textOnly)
    )

    let prompts = await brain.generalChatPrompts
    #expect(prompts.count == 2)
    #expect(prompts[1].count < prompts[0].count)
    #expect(prompts[1].contains("## Evidence Contract"))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "I summarized Nova Backend with the tighter evidence packet." })
}

@Test
func assistantSessionAsksFollowUpForAmbiguousAgentProject() async throws {
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"nova","prompt":"what auth endpoints exist?","mode":"ask"}"#,
                responseText: ""
            ),
            agent: RecordingSessionAgentProvider(responseText: "")
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend"),
            ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", aliases: ["nova-admin"], localPath: "/workspace/nova-admin"),
            ProjectIdentity(id: "nova-frontend", displayName: "Nova Frontend", aliases: ["nova-frontend"], localPath: "/workspace/nova-frontend")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex in nova", request: sessionRequest(outputMode: .textOnly))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: Nova Admin, Nova Backend, Nova Frontend?"
    })
}

@Test
func assistantSessionDiscoversMissingProjectThroughSelectedAgentProvider() async throws {
    let discoveredProject = ProjectIdentity(
        id: "sample-auth",
        displayName: "Sample Auth",
        aliases: ["sample-auth"],
        localPath: "/workspace/sample-auth",
        gitRemoteURL: "https://github.com/bankplace/sample-auth.git"
    )
    let agent = RecordingSessionAgentProvider(
        responseText: "Codex says sample-auth supports logins.",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(project: discoveredProject, confidence: .high, score: 110)
        ]
    )
    let writer = RecordingProjectWriter()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"what login endpoints exist?","mode":"ask"}"#,
                responseText: ###"{"bubbleText":"Codex found the login endpoints.","detailsMarkdown":"## Endpoints\n- POST /v1/auth/login/login/begin"}"###
            ),
            agent: agent
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([]),
        projectWriter: writer,
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about sample-auth", request: sessionRequest(outputMode: .textOnly))

    let agentRequest = try #require(await agent.recordedRequests.first)
    #expect(agentRequest.workspacePath == "/workspace/sample-auth")
    #expect(await agent.discoveryQueries == [
        ProjectDiscoveryQuery(projectName: "sample-auth", prompt: "what login endpoints exist?")
    ])
    #expect(await writer.upsertedProjects == [discoveredProject])
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .action && $0.text == "Found Sample Auth." && $0.status == .completed })
    #expect(messages.contains { $0.role == .action && $0.text == "Codex finished." && $0.status == .completed })
    #expect(messages.contains { $0.role == .assistant && $0.detailsMarkdown?.contains("POST /v1/auth/login/login/begin") == true })
}

@Test
func assistantSessionUsesFolderHintToFindAmbiguousLocalProjects() async throws {
    let work = try temporaryWorkspaceWorkFolderForSession()
    try createProjectFolderForSession(named: "nova-admin", under: work)
    try createProjectFolderForSession(named: "nova-backend", under: work)
    try createProjectFolderForSession(named: "nova-web", under: work)
    let writer = RecordingProjectWriter()
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"claude-code","providerName":"Claude","projectName":"tear","prompt":"count README lines","mode":"ask"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Claude counted the README lines.","detailsMarkdown":"README.md has 40 lines."}"###
        ]
    )
    let agent = RecordingSessionAgentProvider(
        id: "claude-code",
        displayName: "Claude",
        responseText: "README.md has 40 lines.",
        discoveryCandidates: []
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([]),
        projectWriter: writer,
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can we ask Claude to see how many lines are in the README for the at last project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("Not at last, the nova project", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText(
        "It should be somewhere in \(work.path)",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("backend", request: sessionRequest(outputMode: .textOnly))

    let requests = await agent.recordedRequests
    #expect(requests.count == 1)
    #expect(requests.first?.workspacePath == work.appendingPathComponent("nova-backend").path)
    #expect(requests.first?.prompt == "count README lines")

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "I don't know the at last project folder yet. Please give me the local folder before I hand this to Claude." })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Got it, nova. Where should I look for that project folder?" })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Which project do you mean: Nova Admin, Nova Backend, Nova Web?" })
    #expect(messages.contains { $0.role == .assistant && $0.text == "I'll ask Claude to inspect Nova Backend and summarize what it finds." })
    #expect(await writer.upsertedProjects.map(\.displayName).contains("Nova Backend"))
}

@Test
func assistantSessionKeepsLargeProjectClarificationListsOutOfSpeech() async throws {
    let work = try temporaryWorkspaceWorkFolderForSession()
    let projectFolders = [
        "acme-admin-portal-v1-repo",
        "acme-architecture-repo",
        "acme-cdk-frontend-portals-repo",
        "acme-cdk-modules-repo",
        "acme-customer-risk-rating-repo",
        "acme-deposit-report-repo",
        "acme-digital-customer-form-repo",
        "acme-eod-portal-repo",
        "acme-external-api-gateway-repo",
        "acme-internal-reporting-repo",
        "acme-keycloak-repo",
        "acme-loan-report-repo",
        "acme-payment-switch-repo",
        "acme-reports-repo"
    ]
    for folder in projectFolders {
        try createProjectFolderForSession(named: folder, under: work)
    }
    let speech = RecordingSessionSpeech()
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"claude-code","providerName":"Claude Code","projectName":"acme","prompt":"count README lines","mode":"ask"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Claude counted the README lines.","detailsMarkdown":"README.md has 22 lines."}"###
        ]
    )
    let agent = RecordingSessionAgentProvider(
        id: "claude-code",
        displayName: "Claude Code",
        responseText: "README.md has 22 lines.",
        discoveryCandidates: []
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you ask Claude how many lines are in the README for the acme project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "It should be somewhere in \(work.path)",
        request: sessionRequest(inputMode: .voice, outputMode: .speakAll)
    )
    await orchestrator.submitText("payment switch", request: sessionRequest(outputMode: .textOnly))

    let messages = await orchestrator.messageSnapshot
    let clarification = try #require(messages.first { $0.text == "I see 14 acme projects. Which one are you talking about?" })
    #expect(clarification.detailsMarkdown?.contains("## Matching Projects") == true)
    #expect(clarification.detailsMarkdown?.contains("Showing 12 of 14") == true)
    #expect(clarification.detailsMarkdown?.contains("- Acme Admin Portal V1 Repo") == true)
    #expect(clarification.detailsMarkdown?.contains("Payment Switch") == false)
    #expect(await speech.spokenTexts.contains("I see 14 acme projects. Which one are you talking about?"))
    #expect(await speech.spokenTexts.allSatisfy { !$0.contains("Acme Admin Portal V1 Repo") })

    let request = try #require(await agent.recordedRequests.first)
    #expect(request.workspacePath == work.appendingPathComponent("acme-payment-switch-repo").path)
}

@Test
func assistantSessionKeepsAgentProgressOutOfChatAndFormatsFinalResult() async throws {
    let details = """
    ## Login endpoints
    | Method | Endpoint |
    |---|---|
    | POST | /v1/auth/login/login/begin |
    | POST | /v1/auth/login/login/finish |
    """
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"what login endpoints exist?","mode":"ask"}"#,
        responseText: """
        {"bubbleText":"Codex found 2 login endpoints. I put the list below.","detailsMarkdown":"\(details.replacingOccurrences(of: "\n", with: "\\n"))"}
        """
    )
    let speech = RecordingSessionSpeech()
    let agent = NoisySessionAgentProvider(
        responseText: """
        I ran ls and grep.
        | Method | Endpoint |
        |---|---|
        | POST | /v1/auth/login/login/begin |
        | POST | /v1/auth/login/login/finish |
        """
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(
                id: "sample-auth",
                displayName: "Sample Auth",
                aliases: ["sample-auth"],
                localPath: "/workspace/sample-auth"
            )
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about sample-auth", request: sessionRequest(outputMode: .speakAll))

    let messages = await orchestrator.messageSnapshot
    let actionMessages = messages.filter { $0.role == .action }
    #expect(actionMessages.contains { $0.text == "Interacting with Codex..." || $0.text == "Codex finished." })
    #expect(!actionMessages.contains { $0.text.localizedCaseInsensitiveContains("ls") })
    #expect(!actionMessages.contains { $0.text.localizedCaseInsensitiveContains("grep") })
    #expect(!actionMessages.contains { $0.text.contains("/v1/auth/login/login/begin") })

    let finalMessage = try #require(messages.last(where: { $0.role == .assistant }))
    #expect(finalMessage.text == "Codex found 2 login endpoints. I put the list below.")
    #expect(finalMessage.detailsMarkdown?.contains("/v1/auth/login/login/begin") == true)
    #expect(messages.contains { $0.role == .assistant && $0.text == "I'll ask Codex to inspect Sample Auth and summarize what it finds." })
    #expect(await speech.spokenTexts == [
        "I'll ask Codex to inspect Sample Auth and summarize what it finds.",
        "Codex found 2 login endpoints. I put the list below."
    ])
}

@Test
func assistantSessionUsesModeAwareAgentIntroForEdits() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"add a short comment to the login route","mode":"act"}"#,
        responseText: ###"{"bubbleText":"Codex updated the login route comment.","detailsMarkdown":"Changed routes/login.ts."}"###
    )
    let speech = RecordingSessionSpeech()
    let agent = RecordingSessionAgentProvider(responseText: "Updated routes/login.ts.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex to edit sample-auth", request: sessionRequest(outputMode: .speakAll))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "I'll ask Codex to make that change in Sample Auth and summarize what changed."
    })
    #expect(!messages.contains { $0.text == "I'll ask Codex to inspect Sample Auth and summarize what it finds." })
    #expect(await speech.spokenTexts == [
        "I'll ask Codex to make that change in Sample Auth and summarize what changed.",
        "Codex updated the login route comment. Changed file: routes/login.ts."
    ])
}

@Test
func assistantSessionStripsEmojiFromSpeechOnly() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"respond"}"#,
        responseText: ###"{"bubbleText":"\u2705 Codex found 2 endpoints.","detailsMarkdown":null}"###
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

    await orchestrator.submitText("short version", request: sessionRequest(outputMode: .speakAll))

    let assistantMessage = try #require(await orchestrator.messageSnapshot.first { $0.role == .assistant })
    #expect(assistantMessage.text == "\u{2705} Codex found 2 endpoints.")
    #expect(await speech.spokenTexts == ["Codex found 2 endpoints."])
}

@Test
func assistantSessionKeepsFormattedAgentResultInFollowUpContext() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"what login endpoints exist?","mode":"ask"}"#,
            #"{"type":"respond"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found 2 login endpoints.","detailsMarkdown":"## Endpoints\n- POST /v1/auth/login/login/begin\n- POST /v1/auth/login/login/finish"}"###,
            "Sure, I can read them."
        ]
    )
    let agent = RecordingSessionAgentProvider(
        responseText: """
        | Method | Endpoint |
        |---|---|
        | POST | /v1/auth/login/login/begin |
        | POST | /v1/auth/login/login/finish |
        """
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(
                id: "sample-auth",
                displayName: "Sample Auth",
                aliases: ["sample-auth"],
                localPath: "/workspace/sample-auth"
            )
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about sample-auth", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText("read me the endpoints", request: sessionRequest(outputMode: .textOnly))

    let followUpRequest = try #require(await brain.recordedRequests.last(where: { $0.role == .generalChat }))
    #expect(followUpRequest.messages.contains { message in
        message.role == .assistant
            && message.content.contains("Context packet:")
            && message.content.contains("Prior agent result:")
            && message.content.contains("POST /v1/auth/login/login/begin")
            && message.content.contains("Codex found 2 login endpoints.")
            && !message.content.contains("Agent context:")
    })
}

@Test
func assistantSessionRoutesTellItOutLoudToPriorAnswerInsteadOfSelection() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"what login endpoints exist?","mode":"ask"}"#,
            #"{"type":"readSelection"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found 2 login endpoints.","detailsMarkdown":"## Endpoints\n- POST /v1/auth/login/login/begin\n- POST /v1/auth/login/login/finish"}"###,
            ###"{"bubbleText":"Codex found two Sample Auth login endpoints: one to begin login and one to finish login.","detailsMarkdown":null}"###
        ]
    )
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: brain,
            agent: RecordingSessionAgentProvider(responseText: "POST /v1/auth/login/login/begin")
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about sample-auth", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText("Can you tell it to me out loud?", request: sessionRequest(outputMode: .speakAll))

    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.text == "No selected text found." })
    #expect(messages.contains { $0.role == .assistant && $0.text.contains("begin login") })
    #expect(await speech.spokenTexts == [
        "Codex found two Sample Auth login endpoints: one to begin login and one to finish login."
    ])
}

@Test
func assistantSessionReadsPriorSpreadsheetTableOutLoudWithoutResponseBrain() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runSkill","skillID":"spreadsheet","projectName":"sample-orders.csv","prompt":"top 5 orders based on Service Fee","mode":"ask"}"#,
            #"{"type":"respond"}"#
        ],
        responseTexts: [
            ####"{"bubbleText":"I found the top rows and put the table below.","detailsMarkdown":"### Top 5 Orders by Service Fee\n\n| Rank | Order Type | Service Fee |\n|------|------------|-------------|\n| 1 | Refund | 90 |\n| 2 | Purchase | 70 |\n| 3 | Adjustment | 50 |\n| 4 | Purchase | 30 |\n| 5 | Trial | 10 |"}"####,
            ###"{"bubbleText":"I can't speak out loud -- I'm a text-based AI.","detailsMarkdown":null}"###
        ]
    )
    let speech = RecordingSessionSpeech()
    let skill = RecordingLocalSkillWorker(
        skillID: SkillID(rawValue: "spreadsheet"),
        displayName: "Spreadsheet Skill",
        evidenceMarkdown: "# Spreadsheet evidence"
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(
                id: "sample-orders-csv",
                displayName: "sample-orders.csv",
                aliases: ["sample-orders.csv"],
                localPath: "/Users/example/Downloads/sample-orders.csv"
            )
        ]),
        localSkillWorkers: [skill],
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "What are the top 5 orders based on Service Fee in the sample-orders.csv file in the Downloads folder?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "Can you tell them to me out loud?",
        request: sessionRequest(outputMode: .speakAll)
    )

    let assistant = try #require(await orchestrator.messageSnapshot.last { $0.role == .assistant })
    #expect(assistant.text.contains("top five by Service Fee"))
    #expect(assistant.text.contains("Refund at 90"))
    #expect(assistant.detailsMarkdown == nil)
    #expect(!assistant.text.contains("text-based AI"))
    #expect(await speech.spokenTexts == [
        "Sure. The top five by Service Fee are: Refund at 90; Purchase at 70; Adjustment at 50; Purchase at 30; and Trial at 10."
    ])

    let brainRequests = await brain.recordedRequests
    #expect(brainRequests.filter { $0.role == .generalChat }.count == 1)
    #expect(await skill.recordedRequests.count == 1)
}

@Test
func assistantSessionKeepsSpeechFirstFollowUpOutOfDetails() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"readSelection"}"#,
        responseText: ###"{"bubbleText":"Sure. The flow starts the secure login, completes the platform challenge, then finishes login with the signed result.","detailsMarkdown":null}"###
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
        "Can you tell me the flow for the endpoints, not just print them out?",
        request: sessionRequest(outputMode: .speakAll)
    )

    let assistantMessage = try #require(await orchestrator.messageSnapshot.first { $0.role == .assistant })
    #expect(assistantMessage.text.contains("starts the secure login"))
    #expect(assistantMessage.detailsMarkdown == nil)
    #expect(await speech.spokenTexts == [
        "Sure. The flow starts the secure login, completes the platform challenge, then finishes login with the signed result."
    ])
}

@Test
func assistantSessionReusesPriorAgentProjectForFollowUpEdit() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"identify login files","mode":"ask"}"#,
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","prompt":"add a short comment in the login files","mode":"act"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found the login files.","detailsMarkdown":"## Files\n- routes/login.ts"}"###,
            ###"{"bubbleText":"Codex updated the login file with a short comment.","detailsMarkdown":"Changed routes/login.ts."}"###
        ]
    )
    let agent = RecordingSessionAgentProvider(responseText: "Done.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("Ask Codex in Sample Auth what login files matter.", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText("Great, tell Codex to add a short comment there.", request: sessionRequest(outputMode: .textOnly))

    let requests = await agent.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.last?.workspacePath == "/workspace/sample-auth")
    #expect(requests.last?.mode == .act)
    #expect(requests.last?.prompt == "add a short comment in the login files")
    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.text == "Which project should Codex use?" })
}

@Test
func assistantSessionDoesNotReusePriorProjectWhenUserNamesAmbiguousProject() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"what login files matter?","mode":"ask"}"#,
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found the login files.","detailsMarkdown":"## Files\n- routes/login.ts"}"###
        ]
    )
    let agent = RecordingSessionAgentProvider(
        responseText: "Done.",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
                confidence: .high,
                score: 100
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend"),
                confidence: .high,
                score: 136
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-mailer", displayName: "Nova Mailer", localPath: "/workspace/nova-mailer"),
                confidence: .high,
                score: 90
            )
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth"),
            ProjectIdentity(id: "cached-nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("Ask Codex in Sample Auth what login files matter.", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the nova project?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let requests = await agent.recordedRequests
    #expect(requests.count == 1)
    #expect(requests.first?.workspacePath == "/workspace/sample-auth")
    #expect(await agent.discoveryQueries.last == ProjectDiscoveryQuery(
        projectName: "nova",
        prompt: "tell me how many lines the README.md file is"
    ))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: Nova Admin, Nova Backend, Nova Mailer?"
    })
}

@Test
func assistantSessionResumesPendingProjectClarificationWithOriginalAgentRequest() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"nova","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found the README line count.","detailsMarkdown":"README.md has 42 lines."}"###
        ]
    )
    let agent = RecordingSessionAgentProvider(responseText: "README.md has 42 lines.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend"),
            ProjectIdentity(id: "nova-mailer", displayName: "Nova Mailer", localPath: "/workspace/nova-mailer")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the nova project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("nova backend", request: sessionRequest(outputMode: .textOnly))

    let requests = await agent.recordedRequests
    #expect(requests.count == 1)
    #expect(requests.first?.workspacePath == "/workspace/nova-backend")
    #expect(requests.first?.prompt == "tell me how many lines the README.md file is")
    #expect(requests.first?.mode == .ask)

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: Nova Admin, Nova Backend, Nova Mailer?"
    })
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "I'll ask Codex to inspect Nova Backend and summarize what it finds."
    })
    #expect(messages.contains { message in
        message.role == .assistant
            && message.detailsMarkdown?.contains("README.md has 42 lines.") == true
    })

    let tasks = await orchestrator.taskSnapshot()
    #expect(tasks.count == 1)
    let task = try #require(tasks.first)
    #expect(task.status == .completed)
    #expect(task.userRequest == "Can you ask codex to tell me how many lines the README.md file is in the nova project?")
    #expect(task.providerID == "codex-agent")
    #expect(task.mode == .ask)
    #expect(task.projectQuery == "nova")
    #expect(task.resolvedProject?.id == "nova-backend")
    #expect(task.resultSummary == "Codex found the README line count.")
    #expect(task.resultDetailsMarkdown == "README.md has 42 lines.")
    #expect(task.events.map(\.kind).contains(.clarificationRequested))
    #expect(task.events.map(\.kind).contains(.clarificationResolved))
    #expect(task.events.map(\.kind).contains(.providerRunStarted))
    #expect(task.events.map(\.kind).contains(.completed))
}

@Test
func assistantSessionKeepsPendingProjectClarificationWhenAnswerIsStillAmbiguous() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"nova","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#
        ],
        responseTexts: []
    )
    let agent = RecordingSessionAgentProvider(responseText: "README.md has 42 lines.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend"),
            ProjectIdentity(id: "nova-mailer", displayName: "Nova Mailer", localPath: "/workspace/nova-mailer")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the nova project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("nova", request: sessionRequest(outputMode: .textOnly))

    #expect(await agent.recordedRequests.isEmpty)
    let clarificationMessages = await orchestrator.messageSnapshot.filter {
        $0.role == .assistant
            && $0.text == "Which project do you mean: Nova Admin, Nova Backend, Nova Mailer?"
    }
    #expect(clarificationMessages.count == 2)
}

@Test
func assistantSessionClearsPendingProjectClarificationForUnrelatedShortCommand() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"nova","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#,
            #"{"type":"openApplication","appName":"Safari"}"#
        ],
        responseTexts: []
    )
    let agent = RecordingSessionAgentProvider(responseText: "README.md has 42 lines.")
    let appCommands = RecordingSessionAppCommands()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        applicationCommands: appCommands,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend"),
            ProjectIdentity(id: "nova-mailer", displayName: "Nova Mailer", localPath: "/workspace/nova-mailer")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the nova project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("open safari", request: sessionRequest(outputMode: .textOnly))

    #expect(await agent.recordedRequests.isEmpty)
    #expect(await appCommands.commands.count == 1)
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .action && $0.text == "Opened App." })
}

@Test
func assistantSessionClarifiesOtherProjectCorrectionsWithoutExcludedProject() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"nova project","prompt":"how many lines are in the README.md","mode":"ask"}"#,
        responseText: "Done."
    )
    let agent = RecordingSessionAgentProvider(
        responseText: "Done.",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
                confidence: .high,
                score: 100
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend"),
                confidence: .high,
                score: 136
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-mailer", displayName: "Nova Mailer", localPath: "/workspace/nova-mailer"),
                confidence: .high,
                score: 90
            )
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "cached-nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "No I mean not nova-backend project, ask codex how many lines are in the readme for the other nova project",
        request: sessionRequest(outputMode: .textOnly)
    )

    #expect(await agent.recordedRequests.isEmpty)
    #expect(await agent.discoveryQueries.last == ProjectDiscoveryQuery(
        projectName: "nova",
        prompt: "how many lines are in the README.md"
    ))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: Nova Admin, Nova Mailer?"
    })
}

@Test
func assistantSessionRecoversFriendlyFromMalformedRouterOutput() async throws {
    let brain = ScriptedSessionBrainProvider(directiveJSON: "not json", responseText: "")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("Ask Codex about Sample Auth logins.", request: sessionRequest(outputMode: .textOnly))

    let status = try #require(await orchestrator.messageSnapshot.first { $0.role == .status && $0.status == .failed })
    #expect(status.text == "I had trouble understanding that. Please try again.")
    #expect(!status.text.localizedCaseInsensitiveContains("json"))
    #expect(!status.text.localizedCaseInsensitiveContains("parse"))
}

@Test
func assistantSessionAddsExactFilePathToAgentEditSummary() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"update the infrastructure README","mode":"act"}"#,
        responseText: ###"{"bubbleText":"Codex updated the README.","detailsMarkdown":null}"###
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: brain,
            agent: RecordingSessionAgentProvider(responseText: "Updated infra/README.md with the deployment note.")
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("Ask Codex to update the Sample Auth infrastructure README.", request: sessionRequest(outputMode: .textOnly))

    let finalMessage = try #require(await orchestrator.messageSnapshot.last { $0.role == .assistant })
    #expect(finalMessage.text.contains("infra/README.md"))
    #expect(finalMessage.detailsMarkdown?.contains("infra/README.md") == true)
}

@Test
func assistantSessionPublishesAndResolvesAgentApprovalPrompt() async throws {
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Done.")
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )
    let requirement = AgentApprovalRequirement(
        providerID: "codex-agent",
        role: .coding,
        mode: .act,
        workspacePath: "/workspace/sample-auth",
        dataScopes: [.prompt, .workspaceFiles],
        actionScopes: [.readWorkspace, .runCommands, .editWorkspace]
    )
    let prompt = AgentApprovalPrompt(
        requirement: requirement,
        title: "Codex needs approval",
        detail: requirement.detailText
    )

    let decisionTask = Task {
        await orchestrator.requestAgentApprovalDecision(for: prompt)
    }
    try await waitUntil {
        await orchestrator.messageSnapshot.contains { $0.approvalRequest?.requirement == requirement }
    }

    let pendingMessage = try #require(await orchestrator.messageSnapshot.first(where: { $0.approvalRequest != nil }))
    #expect(pendingMessage.role == .action)
    #expect(pendingMessage.status == .pending)
    #expect(pendingMessage.text == "Codex needs approval")
    #expect(pendingMessage.approvalRequest?.detail.contains("edit workspace") == true)

    await orchestrator.submitAgentApprovalDecision(pendingMessage.id, decision: .approveForSession)
    let decision = await decisionTask.value
    let resolvedMessage = try #require(await orchestrator.messageSnapshot.first(where: { $0.id == pendingMessage.id }))

    #expect(decision == .approveForSession)
    #expect(resolvedMessage.status == .completed)
    #expect(resolvedMessage.text == "Remembered approval.")
    #expect(resolvedMessage.approvalRequest?.decision == .approveForSession)
}

@Test
func assistantSessionPublishesAndResolvesAgentQuestionPrompt() async throws {
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(directiveJSON: #"{"type":"respond"}"#, responseText: "Done.")
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )
    let prompt = AgentQuestionPrompt(
        id: "question-prompt",
        providerID: "claude-code",
        title: "Claude needs input",
        questions: [
            AgentQuestion(
                id: "approach",
                header: "Approach",
                question: "Which billing approach should Claude use?",
                options: [
                    AgentQuestionOption(id: "direct", label: "Direct Stripe", detail: "Use Stripe metering directly."),
                    AgentQuestionOption(id: "ledger", label: "Internal Ledger", detail: "Track usage internally first.")
                ]
            )
        ]
    )

    let responseTask = Task {
        await orchestrator.requestAgentQuestionAnswer(for: prompt)
    }
    try await waitUntil {
        await orchestrator.messageSnapshot.contains { $0.questionRequest?.prompt == prompt }
    }

    let pendingMessage = try #require(await orchestrator.messageSnapshot.first(where: { $0.questionRequest != nil }))
    #expect(pendingMessage.role == .action)
    #expect(pendingMessage.status == .pending)
    #expect(pendingMessage.text == "Claude needs input")
    #expect(pendingMessage.questionRequest?.prompt.questions.first?.options.count == 2)

    let answer = AgentQuestionResponse(
        answers: [
            AgentQuestionAnswer(questionID: "approach", selectedOptionLabels: ["Internal Ledger"])
        ]
    )
    await orchestrator.submitAgentQuestionResponse(pendingMessage.id, response: answer)
    let response = await responseTask.value
    let resolvedMessage = try #require(await orchestrator.messageSnapshot.first(where: { $0.id == pendingMessage.id }))

    #expect(response == answer)
    #expect(resolvedMessage.status == .completed)
    #expect(resolvedMessage.text == "Answered.")
    #expect(resolvedMessage.questionRequest?.response == answer)
}

@Test
func assistantSessionCancelClearsActiveAgentTurnForRetry() async throws {
    let agent = HangingSessionAgentProvider()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"sample-auth","prompt":"what login endpoints exist?","mode":"ask"}"#,
                responseText: ""
            ),
            agent: agent
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", localPath: "/workspace/sample-auth")
        ]),
        stopSpeech: {}
    )

    let firstTask = Task {
        await orchestrator.submitText("ask codex about sample-auth", request: sessionRequest(outputMode: .textOnly))
    }
    try await waitUntil { await agent.recordedRequests.count == 1 }

    await orchestrator.cancel()
    try await value(from: firstTask)

    let secondTask = Task {
        await orchestrator.submitText("ask codex again", request: sessionRequest(outputMode: .textOnly))
    }
    try await waitUntil { await agent.recordedRequests.count == 2 }

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .status && $0.status == .cancelled && $0.text == "Assistant cancelled." })
    #expect(!messages.contains { $0.text == "Finish the current turn first." })
    let cancelledTask = try #require(await orchestrator.taskSnapshot().first)
    #expect(cancelledTask.status == .cancelled)
    #expect(cancelledTask.events.map(\.kind).contains(.cancelled))

    await orchestrator.cancel()
    try await value(from: secondTask)
}

@Test
func assistantSessionAsksFollowUpForAmbiguousDiscoveredAgentProjects() async throws {
    let agent = RecordingSessionAgentProvider(
        responseText: "",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", localPath: "/workspace/sample-auth"),
                confidence: .high,
                score: 95
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "sample-auth-infra", displayName: "Sample Auth Infra", localPath: "/workspace/sample-auth-infra"),
                confidence: .high,
                score: 90
            )
        ]
    )
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni","prompt":"inspect auth setup","mode":"ask"}"#,
                responseText: ""
            ),
            agent: agent
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex in uni", request: sessionRequest(outputMode: .textOnly))

    #expect(await agent.recordedRequests.isEmpty)
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: Sample Auth, Sample Auth Infra?"
    })
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
func assistantSessionNamesModelWhenRoutingTimesOut() async throws {
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: FailingSessionBrainProvider(
                error: RocaError.providerTimedOut(
                    providerID: ProviderID(rawValue: "ollama"),
                    modelID: "gemma4:12b"
                )
            )
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        stopSpeech: {}
    )

    await orchestrator.submitText("hello", request: sessionRequest(outputMode: .textOnly))

    let messages = await orchestrator.messageSnapshot
    let status = try #require(messages.first { $0.role == .status && $0.status == .failed })
    #expect(status.text == "gemma4:12b timed out during routing. Try a faster model for Roca assistant routing.")
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

private actor RecordingProviderSetupInstaller: ProviderSetupInstalling {
    private(set) var requests: [ProviderSetupInstallRequest] = []
    private let result: ProviderSetupInstallResult

    init(result: ProviderSetupInstallResult) {
        self.result = result
    }

    func install(_ request: ProviderSetupInstallRequest) async throws -> ProviderSetupInstallResult {
        requests.append(request)
        return result
    }
}

private actor FailingFirstSummaryBrainProvider: BrainProvider {
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
    private var summaryRequestCount = 0
    private(set) var companionRouterRequestCount = 0

    init(directiveJSON: String, responseText: String) {
        self.directiveJSON = directiveJSON
        self.responseText = responseText
    }

    func prepare() async throws {}

    func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        if request.role == .companionRouter {
            companionRouterRequestCount += 1
            return Self.stream(directiveJSON, providerID: id)
        }

        summaryRequestCount += 1
        if summaryRequestCount == 1 {
            throw RocaError.providerUnavailable(ProviderID(rawValue: "ollama"))
        }
        return Self.stream(responseText, providerID: id)
    }

    func cancel(_ requestID: BrainRequestID) async {}

    private nonisolated static func stream(_ text: String, providerID: ProviderID) -> AsyncThrowingStream<BrainEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.final(BrainResponse(text: text, usedProvider: providerID, metadata: [:])))
            continuation.finish()
        }
    }
}

private actor TimeoutSummaryBrainProvider: BrainProvider {
    let id = ProviderID(rawValue: "test-brain")
    let displayName = "Test Brain"
    let capabilities = BrainCapabilities(
        supportsStreaming: false,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )

    private let directiveJSON: String

    init(directiveJSON: String) {
        self.directiveJSON = directiveJSON
    }

    func prepare() async throws {}

    func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        if request.role == .companionRouter {
            return Self.stream(directiveJSON, providerID: id)
        }
        throw RocaError.providerTimedOut(providerID: ProviderID(rawValue: "ollama"), modelID: "qwen3:4b-instruct")
    }

    func cancel(_ requestID: BrainRequestID) async {}

    private nonisolated static func stream(_ text: String, providerID: ProviderID) -> AsyncThrowingStream<BrainEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.final(BrainResponse(text: text, usedProvider: providerID, metadata: [:])))
            continuation.finish()
        }
    }
}

private actor ContextOverflowFirstSummaryBrainProvider: BrainProvider {
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
    private var summaryRequestCount = 0
    private(set) var generalChatPrompts: [String] = []

    init(directiveJSON: String, responseText: String) {
        self.directiveJSON = directiveJSON
        self.responseText = responseText
    }

    func prepare() async throws {}

    func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        if request.role == .companionRouter {
            return Self.stream(directiveJSON, providerID: id)
        }

        summaryRequestCount += 1
        generalChatPrompts.append(request.messages.last?.content ?? "")
        if summaryRequestCount == 1 {
            throw RocaError.providerUnavailable(ProviderID(rawValue: "ollama:context-22000-over-8192"))
        }
        return Self.stream(responseText, providerID: id)
    }

    func cancel(_ requestID: BrainRequestID) async {}

    private nonisolated static func stream(_ text: String, providerID: ProviderID) -> AsyncThrowingStream<BrainEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.final(BrainResponse(text: text, usedProvider: providerID, metadata: [:])))
            continuation.finish()
        }
    }
}

private func temporaryWorkspaceWorkFolderForSession() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-session-workspace-\(UUID().uuidString)", isDirectory: true)
    let work = root.appendingPathComponent("Workspace/work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    return work
}

private func createProjectFolderForSession(named name: String, under parent: URL) throws {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "# \(name)\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
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

private func waitUntil(timeout: Duration = .seconds(1), _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while !(await condition()) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestTimeoutError.timedOut
        }

        try await group.next()
        group.cancelAll()
    }
}

private func sessionRequest(
    inputMode: AssistantInputMode = .typed,
    outputMode: AssistantOutputMode,
    roleSelections: [BrainRole: BrainProviderSelection] = [:]
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
        roleSelections: roleSelections,
        locale: "en-US",
        mode: .toggleToTalk,
        speechConfiguration: SpeechConfiguration(providerID: nil, providerVoiceSelections: [:], speed: 1.0, allowFallback: true)
    )
}
