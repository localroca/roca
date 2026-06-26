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
        directiveJSON: #"{"type":"runAgent","providerID":"claude-code","providerName":"Claude","projectName":"uni-auth","prompt":"what passkey endpoints exist?","mode":"ask"}"#,
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
        "Ask Claude in Uni Auth what passkey endpoints exist.",
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
    #expect(user.metadata?.directivePromptVersion == "assistant-router-2026-06-26-v1")
    #expect(user.metadata?.responsePromptVersion == "companion-response-2026-06-14-v1")
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
    let agent = RecordingSessionAgentProvider(responseText: "Codex says uni-auth supports passkey registration.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"what passkey endpoints exist?","mode":"ask"}"#,
                responseText: ###"{"bubbleText":"Codex says uni-auth supports passkey registration.","detailsMarkdown":null}"###
            ),
            agent: agent
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(
                id: "uni-auth",
                displayName: "Uni Auth",
                aliases: ["uni-auth"],
                localPath: "/workspace/uni-auth"
            )
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about uni-auth", request: sessionRequest(outputMode: .textOnly))

    let agentRequest = try #require(await agent.recordedRequests.first)
    #expect(agentRequest.workspacePath == "/workspace/uni-auth")
    #expect(agentRequest.prompt == "what passkey endpoints exist?")
    #expect(agentRequest.mode == .ask)
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text.contains("ask Codex") })
    #expect(messages.contains { $0.role == .action && $0.text == "Codex finished." })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Codex says uni-auth supports passkey registration." })
}

@Test
func assistantSessionAsksFollowUpForAmbiguousAgentProject() async throws {
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"ter","prompt":"what auth endpoints exist?","mode":"ask"}"#,
                responseText: ""
            ),
            agent: RecordingSessionAgentProvider(responseText: "")
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "ter-backend", displayName: "TER Backend", aliases: ["ter-backend"], localPath: "/workspace/ter-backend"),
            ProjectIdentity(id: "ter-admin", displayName: "TER Admin", aliases: ["ter-admin"], localPath: "/workspace/ter-admin"),
            ProjectIdentity(id: "ter-frontend", displayName: "TER Frontend", aliases: ["ter-frontend"], localPath: "/workspace/ter-frontend")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex in ter", request: sessionRequest(outputMode: .textOnly))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: TER Admin, TER Backend, TER Frontend?"
    })
}

@Test
func assistantSessionDiscoversMissingProjectThroughSelectedAgentProvider() async throws {
    let discoveredProject = ProjectIdentity(
        id: "uni-auth",
        displayName: "Uni Auth",
        aliases: ["uni-auth"],
        localPath: "/workspace/uni-auth",
        gitRemoteURL: "https://github.com/bankplace/uni-auth.git"
    )
    let agent = RecordingSessionAgentProvider(
        responseText: "Codex says uni-auth supports passkeys.",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(project: discoveredProject, confidence: .high, score: 110)
        ]
    )
    let writer = RecordingProjectWriter()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: ScriptedSessionBrainProvider(
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"what passkey endpoints exist?","mode":"ask"}"#,
                responseText: ###"{"bubbleText":"Codex found the passkey endpoints.","detailsMarkdown":"## Endpoints\n- POST /v1/auth/passkey/login/begin"}"###
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

    await orchestrator.submitText("ask codex about uni-auth", request: sessionRequest(outputMode: .textOnly))

    let agentRequest = try #require(await agent.recordedRequests.first)
    #expect(agentRequest.workspacePath == "/workspace/uni-auth")
    #expect(await agent.discoveryQueries == [
        ProjectDiscoveryQuery(projectName: "uni-auth", prompt: "what passkey endpoints exist?")
    ])
    #expect(await writer.upsertedProjects == [discoveredProject])
    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .action && $0.text == "Found Uni Auth." && $0.status == .completed })
    #expect(messages.contains { $0.role == .action && $0.text == "Codex finished." && $0.status == .completed })
    #expect(messages.contains { $0.role == .assistant && $0.detailsMarkdown?.contains("POST /v1/auth/passkey/login/begin") == true })
}

@Test
func assistantSessionUsesFolderHintToFindAmbiguousLocalProjects() async throws {
    let work = try temporaryWorkspaceWorkFolderForSession()
    try createProjectFolderForSession(named: "ter-admin", under: work)
    try createProjectFolderForSession(named: "ter-backend", under: work)
    try createProjectFolderForSession(named: "ter-web", under: work)
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
        "Can we ask Claude to see how many lines are in the README for the tear project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("Not tear, the ter project", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText(
        "It should be somewhere in \(work.path)",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("backend", request: sessionRequest(outputMode: .textOnly))

    let requests = await agent.recordedRequests
    #expect(requests.count == 1)
    #expect(requests.first?.workspacePath == work.appendingPathComponent("ter-backend").path)
    #expect(requests.first?.prompt == "count README lines")

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { $0.role == .assistant && $0.text == "I don't know the tear project folder yet. Please give me the local folder before I hand this to Claude." })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Got it, ter. Where should I look for that project folder?" })
    #expect(messages.contains { $0.role == .assistant && $0.text == "Which project do you mean: TER Admin, TER Backend, TER Web?" })
    #expect(messages.contains { $0.role == .assistant && $0.text == "I'll ask Claude to inspect TER Backend and summarize what it finds." })
    #expect(await writer.upsertedProjects.map(\.displayName).contains("TER Backend"))
}

@Test
func assistantSessionKeepsLargeProjectClarificationListsOutOfSpeech() async throws {
    let work = try temporaryWorkspaceWorkFolderForSession()
    let projectFolders = [
        "dk-bhutan-admin-portal-v1-repo",
        "dk-bhutan-architecture-repo",
        "dk-bhutan-cdk-frontend-portals-repo",
        "dk-bhutan-cdk-modules-repo",
        "dk-bhutan-customer-risk-rating-repo",
        "dk-bhutan-deposit-report-repo",
        "dk-bhutan-digital-customer-form-repo",
        "dk-bhutan-eod-portal-repo",
        "dk-bhutan-external-api-gateway-repo",
        "dk-bhutan-internal-birt-repo",
        "dk-bhutan-keycloak-repo",
        "dk-bhutan-loan-report-repo",
        "dk-bhutan-payment-switch-repo",
        "dk-bhutan-reports-repo"
    ]
    for folder in projectFolders {
        try createProjectFolderForSession(named: folder, under: work)
    }
    let speech = RecordingSessionSpeech()
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"claude-code","providerName":"Claude Code","projectName":"dk-bhutan","prompt":"count README lines","mode":"ask"}"#
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
        "Can you ask Claude how many lines are in the README for the dk-bhutan project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText(
        "It should be somewhere in \(work.path)",
        request: sessionRequest(inputMode: .voice, outputMode: .speakAll)
    )
    await orchestrator.submitText("payment switch", request: sessionRequest(outputMode: .textOnly))

    let messages = await orchestrator.messageSnapshot
    let clarification = try #require(messages.first { $0.text == "I see 14 dk-bhutan projects. Which one are you talking about?" })
    #expect(clarification.detailsMarkdown?.contains("## Matching Projects") == true)
    #expect(clarification.detailsMarkdown?.contains("Showing 12 of 14") == true)
    #expect(clarification.detailsMarkdown?.contains("- DK Bhutan Admin Portal V1 Repo") == true)
    #expect(clarification.detailsMarkdown?.contains("Payment Switch") == false)
    #expect(await speech.spokenTexts.contains("I see 14 dk-bhutan projects. Which one are you talking about?"))
    #expect(await speech.spokenTexts.allSatisfy { !$0.contains("DK Bhutan Admin Portal V1 Repo") })

    let request = try #require(await agent.recordedRequests.first)
    #expect(request.workspacePath == work.appendingPathComponent("dk-bhutan-payment-switch-repo").path)
}

@Test
func assistantSessionKeepsAgentProgressOutOfChatAndFormatsFinalResult() async throws {
    let details = """
    ## Passkey endpoints
    | Method | Endpoint |
    |---|---|
    | POST | /v1/auth/passkey/login/begin |
    | POST | /v1/auth/passkey/login/finish |
    """
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"what passkey endpoints exist?","mode":"ask"}"#,
        responseText: """
        {"bubbleText":"Codex found 2 passkey endpoints. I put the list below.","detailsMarkdown":"\(details.replacingOccurrences(of: "\n", with: "\\n"))"}
        """
    )
    let speech = RecordingSessionSpeech()
    let agent = NoisySessionAgentProvider(
        responseText: """
        I ran ls and grep.
        | Method | Endpoint |
        |---|---|
        | POST | /v1/auth/passkey/login/begin |
        | POST | /v1/auth/passkey/login/finish |
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
                id: "uni-auth",
                displayName: "Uni Auth",
                aliases: ["uni-auth"],
                localPath: "/workspace/uni-auth"
            )
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about uni-auth", request: sessionRequest(outputMode: .speakAll))

    let messages = await orchestrator.messageSnapshot
    let actionMessages = messages.filter { $0.role == .action }
    #expect(actionMessages.contains { $0.text == "Interacting with Codex..." || $0.text == "Codex finished." })
    #expect(!actionMessages.contains { $0.text.localizedCaseInsensitiveContains("ls") })
    #expect(!actionMessages.contains { $0.text.localizedCaseInsensitiveContains("grep") })
    #expect(!actionMessages.contains { $0.text.contains("/v1/auth/passkey/login/begin") })

    let finalMessage = try #require(messages.last(where: { $0.role == .assistant }))
    #expect(finalMessage.text == "Codex found 2 passkey endpoints. I put the list below.")
    #expect(finalMessage.detailsMarkdown?.contains("/v1/auth/passkey/login/begin") == true)
    #expect(messages.contains { $0.role == .assistant && $0.text == "I'll ask Codex to inspect Uni Auth and summarize what it finds." })
    #expect(await speech.spokenTexts == [
        "I'll ask Codex to inspect Uni Auth and summarize what it finds.",
        "Codex found 2 passkey endpoints. I put the list below."
    ])
}

@Test
func assistantSessionUsesModeAwareAgentIntroForEdits() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"add a short comment to the passkey route","mode":"act"}"#,
        responseText: ###"{"bubbleText":"Codex updated the passkey route comment.","detailsMarkdown":"Changed routes/passkeys.ts."}"###
    )
    let speech = RecordingSessionSpeech()
    let agent = RecordingSessionAgentProvider(responseText: "Updated routes/passkeys.ts.")
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(brain: brain, agent: agent),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "uni-auth", displayName: "Uni Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex to edit uni-auth", request: sessionRequest(outputMode: .speakAll))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "I'll ask Codex to make that change in Uni Auth and summarize what changed."
    })
    #expect(!messages.contains { $0.text == "I'll ask Codex to inspect Uni Auth and summarize what it finds." })
    #expect(await speech.spokenTexts == [
        "I'll ask Codex to make that change in Uni Auth and summarize what changed.",
        "Codex updated the passkey route comment. Changed file: routes/passkeys.ts."
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
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"what passkey endpoints exist?","mode":"ask"}"#,
            #"{"type":"respond"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found 2 passkey endpoints.","detailsMarkdown":"## Endpoints\n- POST /v1/auth/passkey/login/begin\n- POST /v1/auth/passkey/login/finish"}"###,
            "Sure, I can read them."
        ]
    )
    let agent = RecordingSessionAgentProvider(
        responseText: """
        | Method | Endpoint |
        |---|---|
        | POST | /v1/auth/passkey/login/begin |
        | POST | /v1/auth/passkey/login/finish |
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
                id: "uni-auth",
                displayName: "Uni Auth",
                aliases: ["uni-auth"],
                localPath: "/workspace/uni-auth"
            )
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about uni-auth", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText("read me the endpoints", request: sessionRequest(outputMode: .textOnly))

    let followUpRequest = try #require(await brain.recordedRequests.last(where: { $0.role == .generalChat }))
    #expect(followUpRequest.messages.contains { message in
        message.role == .assistant
            && message.content.contains("Context packet:")
            && message.content.contains("Prior agent result:")
            && message.content.contains("POST /v1/auth/passkey/login/begin")
            && message.content.contains("Codex found 2 passkey endpoints.")
            && !message.content.contains("Agent context:")
    })
}

@Test
func assistantSessionRoutesTellItOutLoudToPriorAnswerInsteadOfSelection() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"what passkey endpoints exist?","mode":"ask"}"#,
            #"{"type":"readSelection"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found 2 passkey endpoints.","detailsMarkdown":"## Endpoints\n- POST /v1/auth/passkey/login/begin\n- POST /v1/auth/passkey/login/finish"}"###,
            ###"{"bubbleText":"Codex found two Uni Auth passkey endpoints: one to begin login and one to finish login.","detailsMarkdown":null}"###
        ]
    )
    let speech = RecordingSessionSpeech()
    let orchestrator = DefaultAssistantSessionOrchestrator(
        resolver: SessionResolver(
            brain: brain,
            agent: RecordingSessionAgentProvider(responseText: "POST /v1/auth/passkey/login/begin")
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: speech,
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "uni-auth", displayName: "Uni Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("ask codex about uni-auth", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText("Can you tell it to me out loud?", request: sessionRequest(outputMode: .speakAll))

    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.text == "No selected text found." })
    #expect(messages.contains { $0.role == .assistant && $0.text.contains("begin login") })
    #expect(await speech.spokenTexts == [
        "Codex found two Uni Auth passkey endpoints: one to begin login and one to finish login."
    ])
}

@Test
func assistantSessionKeepsSpeechFirstFollowUpOutOfDetails() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"readSelection"}"#,
        responseText: ###"{"bubbleText":"Sure. The flow starts the passkey login, completes the platform challenge, then finishes login with the signed result.","detailsMarkdown":null}"###
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
    #expect(assistantMessage.text.contains("starts the passkey login"))
    #expect(assistantMessage.detailsMarkdown == nil)
    #expect(await speech.spokenTexts == [
        "Sure. The flow starts the passkey login, completes the platform challenge, then finishes login with the signed result."
    ])
}

@Test
func assistantSessionReusesPriorAgentProjectForFollowUpEdit() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"identify passkey files","mode":"ask"}"#,
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","prompt":"add a short comment in the passkey files","mode":"act"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found the passkey files.","detailsMarkdown":"## Files\n- routes/passkeys.ts"}"###,
            ###"{"bubbleText":"Codex updated the passkey file with a short comment.","detailsMarkdown":"Changed routes/passkeys.ts."}"###
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
            ProjectIdentity(id: "uni-auth", displayName: "Uni Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("Ask Codex in Uni Auth what passkey files matter.", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText("Great, tell Codex to add a short comment there.", request: sessionRequest(outputMode: .textOnly))

    let requests = await agent.recordedRequests
    #expect(requests.count == 2)
    #expect(requests.last?.workspacePath == "/workspace/uni-auth")
    #expect(requests.last?.mode == .act)
    #expect(requests.last?.prompt == "add a short comment in the passkey files")
    let messages = await orchestrator.messageSnapshot
    #expect(!messages.contains { $0.text == "Which project should Codex use?" })
}

@Test
func assistantSessionDoesNotReusePriorProjectWhenUserNamesAmbiguousProject() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"what passkey files matter?","mode":"ask"}"#,
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#
        ],
        responseTexts: [
            ###"{"bubbleText":"Codex found the passkey files.","detailsMarkdown":"## Files\n- routes/passkeys.ts"}"###
        ]
    )
    let agent = RecordingSessionAgentProvider(
        responseText: "Done.",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
                confidence: .high,
                score: 100
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend"),
                confidence: .high,
                score: 136
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-mailer", displayName: "TER Mailer", localPath: "/workspace/ter-mailer"),
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
            ProjectIdentity(id: "uni-auth", displayName: "UNI Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth"),
            ProjectIdentity(id: "cached-ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("Ask Codex in Uni Auth what passkey files matter.", request: sessionRequest(outputMode: .textOnly))
    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the ter project?",
        request: sessionRequest(outputMode: .textOnly)
    )

    let requests = await agent.recordedRequests
    #expect(requests.count == 1)
    #expect(requests.first?.workspacePath == "/workspace/uni-auth")
    #expect(await agent.discoveryQueries.last == ProjectDiscoveryQuery(
        projectName: "ter",
        prompt: "tell me how many lines the README.md file is"
    ))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: TER Admin, TER Backend, TER Mailer?"
    })
}

@Test
func assistantSessionResumesPendingProjectClarificationWithOriginalAgentRequest() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"ter","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#
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
            ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
            ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend"),
            ProjectIdentity(id: "ter-mailer", displayName: "TER Mailer", localPath: "/workspace/ter-mailer")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the ter project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("ter backend", request: sessionRequest(outputMode: .textOnly))

    let requests = await agent.recordedRequests
    #expect(requests.count == 1)
    #expect(requests.first?.workspacePath == "/workspace/ter-backend")
    #expect(requests.first?.prompt == "tell me how many lines the README.md file is")
    #expect(requests.first?.mode == .ask)

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: TER Admin, TER Backend, TER Mailer?"
    })
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "I'll ask Codex to inspect TER Backend and summarize what it finds."
    })
    #expect(messages.contains { message in
        message.role == .assistant
            && message.detailsMarkdown?.contains("README.md has 42 lines.") == true
    })

    let tasks = await orchestrator.taskSnapshot()
    #expect(tasks.count == 1)
    let task = try #require(tasks.first)
    #expect(task.status == .completed)
    #expect(task.userRequest == "Can you ask codex to tell me how many lines the README.md file is in the ter project?")
    #expect(task.providerID == "codex-agent")
    #expect(task.mode == .ask)
    #expect(task.projectQuery == "ter")
    #expect(task.resolvedProject?.id == "ter-backend")
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
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"ter","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#
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
            ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
            ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend"),
            ProjectIdentity(id: "ter-mailer", displayName: "TER Mailer", localPath: "/workspace/ter-mailer")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the ter project?",
        request: sessionRequest(outputMode: .textOnly)
    )
    await orchestrator.submitText("ter", request: sessionRequest(outputMode: .textOnly))

    #expect(await agent.recordedRequests.isEmpty)
    let clarificationMessages = await orchestrator.messageSnapshot.filter {
        $0.role == .assistant
            && $0.text == "Which project do you mean: TER Admin, TER Backend, TER Mailer?"
    }
    #expect(clarificationMessages.count == 2)
}

@Test
func assistantSessionClearsPendingProjectClarificationForUnrelatedShortCommand() async throws {
    let brain = SequencedSessionBrainProvider(
        directiveTexts: [
            #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"ter","prompt":"tell me how many lines the README.md file is","mode":"ask"}"#,
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
            ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
            ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend"),
            ProjectIdentity(id: "ter-mailer", displayName: "TER Mailer", localPath: "/workspace/ter-mailer")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "Can you ask codex to tell me how many lines the README.md file is in the ter project?",
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
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"ter project","prompt":"how many lines are in the README.md","mode":"ask"}"#,
        responseText: "Done."
    )
    let agent = RecordingSessionAgentProvider(
        responseText: "Done.",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
                confidence: .high,
                score: 100
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend"),
                confidence: .high,
                score: 136
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-mailer", displayName: "TER Mailer", localPath: "/workspace/ter-mailer"),
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
            ProjectIdentity(id: "cached-ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText(
        "No I mean not ter-backend project, ask codex how many lines are in the readme for the other ter project",
        request: sessionRequest(outputMode: .textOnly)
    )

    #expect(await agent.recordedRequests.isEmpty)
    #expect(await agent.discoveryQueries.last == ProjectDiscoveryQuery(
        projectName: "ter",
        prompt: "how many lines are in the README.md"
    ))

    let messages = await orchestrator.messageSnapshot
    #expect(messages.contains { message in
        message.role == .assistant
            && message.text == "Which project do you mean: TER Admin, TER Mailer?"
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

    await orchestrator.submitText("Ask Codex about Uni Auth passkeys.", request: sessionRequest(outputMode: .textOnly))

    let status = try #require(await orchestrator.messageSnapshot.first { $0.role == .status && $0.status == .failed })
    #expect(status.text == "I had trouble understanding that. Please try again.")
    #expect(!status.text.localizedCaseInsensitiveContains("json"))
    #expect(!status.text.localizedCaseInsensitiveContains("parse"))
}

@Test
func assistantSessionAddsExactFilePathToAgentEditSummary() async throws {
    let brain = ScriptedSessionBrainProvider(
        directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"update the infrastructure README","mode":"act"}"#,
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
            ProjectIdentity(id: "uni-auth", displayName: "Uni Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth")
        ]),
        stopSpeech: {}
    )

    await orchestrator.submitText("Ask Codex to update the Uni Auth infrastructure README.", request: sessionRequest(outputMode: .textOnly))

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
        workspacePath: "/workspace/uni-auth",
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
                directiveJSON: #"{"type":"runAgent","providerID":"codex-agent","providerName":"Codex","projectName":"uni-auth","prompt":"what passkey endpoints exist?","mode":"ask"}"#,
                responseText: ""
            ),
            agent: agent
        ),
        audioInput: NoopSessionAudioInput(),
        inserter: NoopSessionInserter(),
        speechOrchestrator: RecordingSessionSpeech(),
        contextProvider: StaticSessionContextProvider(),
        projectCatalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "uni-auth", displayName: "Uni Auth", localPath: "/workspace/uni-auth")
        ]),
        stopSpeech: {}
    )

    let firstTask = Task {
        await orchestrator.submitText("ask codex about uni-auth", request: sessionRequest(outputMode: .textOnly))
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
                project: ProjectIdentity(id: "uni-auth", displayName: "Uni Auth", localPath: "/workspace/uni-auth"),
                confidence: .high,
                score: 95
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "uni-auth-infra", displayName: "Uni Auth Infra", localPath: "/workspace/uni-auth-infra"),
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
            && message.text == "Which project do you mean: Uni Auth, Uni Auth Infra?"
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
