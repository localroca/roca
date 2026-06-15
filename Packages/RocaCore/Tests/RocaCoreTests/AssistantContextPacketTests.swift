import RocaCore
import Testing

@Test
func assistantContextPacketBuildsModelVisibleContext() {
    let project = ProjectIdentity(
        id: "uni-auth",
        displayName: "Uni Auth",
        aliases: ["uni-auth"],
        localPath: "/workspace/uni-auth"
    )
    let packet = AssistantContextPacket(
        currentTask: AssistantAgentTaskContext(
            providerID: "codex-agent",
            providerName: "Codex",
            mode: .ask,
            prompt: "list passkey endpoints",
            project: project
        ),
        priorAgentResult: AssistantAgentResultContext(
            providerID: "codex-agent",
            providerName: "Codex",
            mode: .ask,
            project: project,
            summary: "Codex found 2 passkey endpoints.",
            detailsMarkdown: "- POST /v1/auth/passkey/login/begin"
        ),
        approval: AssistantApprovalContext(
            riskLevel: .medium,
            approvalBehavior: .policyDriven,
            decision: nil
        )
    )

    #expect(packet.brainContextText.contains("Context packet:"))
    #expect(packet.brainContextText.contains("Current task: provider=Codex (codex-agent); mode=ask"))
    #expect(packet.brainContextText.contains("project=Uni Auth at /workspace/uni-auth"))
    #expect(packet.brainContextText.contains("summary=Codex found 2 passkey endpoints."))
    #expect(packet.brainContextText.contains("POST /v1/auth/passkey/login/begin"))
    #expect(packet.brainContextText.contains("Approval policy: risk=medium; behavior=policyDriven; decision=notRequested"))
}
