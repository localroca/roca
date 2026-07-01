import RocaCore
import Testing

@Test
func assistantContextPacketBuildsModelVisibleContext() {
    let project = ProjectIdentity(
        id: "sample-auth",
        displayName: "Sample Auth",
        aliases: ["sample-auth"],
        localPath: "/workspace/sample-auth"
    )
    let packet = AssistantContextPacket(
        currentTask: AssistantAgentTaskContext(
            providerID: "codex-agent",
            providerName: "Codex",
            mode: .ask,
            prompt: "list login endpoints",
            project: project
        ),
        priorAgentResult: AssistantAgentResultContext(
            providerID: "codex-agent",
            providerName: "Codex",
            mode: .ask,
            project: project,
            summary: "Codex found 2 login endpoints.",
            detailsMarkdown: "- POST /v1/auth/login/login/begin",
            evidence: AssistantEvidenceSummary(
                sourceKind: .externalAgent,
                sourceID: "codex-agent",
                sourceName: "Codex",
                grade: .verified,
                inspectedPaths: ["routes/login.ts"]
            )
        ),
        approval: AssistantApprovalContext(
            riskLevel: .medium,
            approvalBehavior: .policyDriven,
            decision: nil
        )
    )

    #expect(packet.brainContextText.contains("Context packet:"))
    #expect(packet.brainContextText.contains("Current task: provider=Codex (codex-agent); mode=ask"))
    #expect(packet.brainContextText.contains("project=Sample Auth at /workspace/sample-auth"))
    #expect(packet.brainContextText.contains("summary=Codex found 2 login endpoints."))
    #expect(packet.brainContextText.contains("Evidence: source=Codex (codex-agent); grade=verified"))
    #expect(packet.brainContextText.contains("inspectedPaths=routes/login.ts"))
    #expect(packet.brainContextText.contains("POST /v1/auth/login/login/begin"))
    #expect(packet.brainContextText.contains("Approval policy: risk=medium; behavior=policyDriven; decision=notRequested"))
}

@Test
func assistantContextAssemblerAddsRecentTaskLedgerContext() throws {
    let project = ProjectIdentity(
        id: "sample-auth",
        displayName: "Sample Auth",
        aliases: ["sample-auth"],
        localPath: "/workspace/sample-auth"
    )
    let packet = AssistantContextPacket(
        priorAgentResult: AssistantAgentResultContext(
            providerID: "codex-agent",
            providerName: "Codex",
            mode: .ask,
            project: project,
            summary: "Codex found 2 login endpoints.",
            detailsMarkdown: "## Endpoints\n- POST /v1/auth/login/login/begin"
        )
    )
    var failedTask = AssistantTaskRecord(
        turnID: "turn-1",
        userRequest: "Ask Codex about sample-auth",
        providerID: "codex-agent",
        providerName: "Codex",
        mode: .ask,
        projectQuery: "sample-auth",
        status: .failed
    )
    failedTask.failurePhase = "projectLookup"
    failedTask.failureMessage = "I couldn't read Codex's project list in time."

    let messages = AssistantContextAssembler().contextMessages(
        lastPacket: packet,
        recentTasks: [failedTask]
    )

    let context = try #require(messages.first?.content)
    #expect(context.contains("Assistant context bridge:"))
    #expect(context.contains("Prior agent result: provider=Codex (codex-agent); mode=ask"))
    #expect(context.contains("Recent assistant task ledger:"))
    #expect(context.contains("failed task; provider=Codex; mode=ask; projectQuery=sample-auth"))
    #expect(context.contains("failure=projectLookup: I couldn't read Codex's project list in time."))
}

@Test
func assistantContextAssemblerMemoryMessagesMatchPacketContext() {
    let packet = AssistantContextPacket(
        currentTask: AssistantAgentTaskContext(
            providerID: "local-skill",
            providerName: "Codebase Skill",
            mode: .ask,
            prompt: "find JavaScript",
            project: nil
        )
    )

    let messages = AssistantContextAssembler().memoryMessages(
        userText: "What is this repo written in?",
        packet: packet
    )

    #expect(messages.count == 2)
    #expect(messages[0].role == .user)
    #expect(messages[0].content == "What is this repo written in?")
    #expect(messages[1].role == .assistant)
    #expect(messages[1].content.contains("Roca started a task"))
    #expect(messages[1].content.contains("provider=Codebase Skill"))
    #expect(messages[1].content.contains("prompt=find JavaScript"))
}
