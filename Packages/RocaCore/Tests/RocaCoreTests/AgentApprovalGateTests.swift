import Foundation
import RocaCore
import Testing

@Test
func agentApprovalGateDeniesWhenNoRememberedApprovalExists() async throws {
    let store = InMemoryApprovalStore()
    let gate = AgentApprovalGate(store: store)
    let requirement = codexPlanRequirement()

    let authorization = try await gate.authorization(for: requirement)

    #expect(!authorization.isApproved)
    #expect(authorization.approvalID == nil)
}

@Test
func agentApprovalGateGrantsAndMatchesExactRememberedApproval() async throws {
    let store = InMemoryApprovalStore()
    let gate = AgentApprovalGate(store: store)
    let requirement = codexPlanRequirement()
    let createdAt = Date(timeIntervalSince1970: 1_000)

    let record = try await gate.grant(requirement, createdAt: createdAt)
    let authorization = try await gate.authorization(for: requirement)
    let approvals = try await store.load()

    #expect(authorization.isApproved)
    #expect(authorization.approvalID == record.id)
    #expect(approvals.first?.lastUsedAt != nil)
    #expect(record.agentScope?.covers(requirement) == true)
}

@Test
func agentApprovalGateDoesNotLetNarrowApprovalCoverBroaderRequest() async throws {
    let store = InMemoryApprovalStore()
    let gate = AgentApprovalGate(store: store)
    let narrow = codexPlanRequirement(actionScopes: [.readWorkspace])
    let broader = codexPlanRequirement(actionScopes: [.readWorkspace, .runCommands])

    try await gate.grant(narrow)
    let authorization = try await gate.authorization(for: broader)

    #expect(!authorization.isApproved)
}

@Test
func agentApprovalGateAllowsBroaderApprovalToCoverNarrowerRequest() async throws {
    let store = InMemoryApprovalStore()
    let gate = AgentApprovalGate(store: store)
    let broader = codexPlanRequirement(dataScopes: [.prompt, .workspaceFiles], actionScopes: [.readWorkspace])
    let narrower = codexPlanRequirement(dataScopes: [.prompt], actionScopes: [])

    try await gate.grant(broader)
    let authorization = try await gate.authorization(for: narrower)

    #expect(authorization.isApproved)
}

@Test
func agentApprovalGateDecisionUsesRememberedApprovalRecords() async throws {
    let store = InMemoryApprovalStore()
    let gate = AgentApprovalGate(store: store)
    let requirement = codexPlanRequirement(actionScopes: [.readWorkspace, .runCommands])
    let prompt = AgentApprovalPrompt(
        requirement: requirement,
        title: "Codex Command",
        detail: "ls"
    )

    let missingDecision = try await gate.decision(for: prompt)
    try await gate.grant(requirement)
    let rememberedDecision = try await gate.decision(for: prompt)

    #expect(missingDecision == .cancel)
    #expect(rememberedDecision == .approve)
}

@Test
func interactiveAgentApprovalGateApprovesOnceWithoutRemembering() async throws {
    let store = InMemoryApprovalStore()
    let presenter = RecordingApprovalPresenter(decisions: [.approve])
    let gate = InteractiveAgentApprovalGate(
        store: store,
        presenter: { prompt in
            await presenter.present(prompt)
        }
    )
    let requirement = codexPlanRequirement()

    let authorization = try await gate.authorization(for: requirement)
    let approvals = try await store.load()

    #expect(authorization.isApproved)
    #expect(authorization.approvalID == nil)
    #expect(approvals.isEmpty)
    #expect(await presenter.prompts.map(\.requirement) == [requirement])
}

@Test
func interactiveAgentApprovalGateRemembersApprovalAndSkipsFuturePrompts() async throws {
    let store = InMemoryApprovalStore()
    let presenter = RecordingApprovalPresenter(decisions: [.approveForSession])
    let gate = InteractiveAgentApprovalGate(
        store: store,
        presenter: { prompt in
            await presenter.present(prompt)
        }
    )
    let requirement = codexPlanRequirement()

    let firstAuthorization = try await gate.authorization(for: requirement)
    let secondAuthorization = try await gate.authorization(for: requirement)
    let approvals = try await store.load()

    #expect(firstAuthorization.isApproved)
    #expect(firstAuthorization.approvalID != nil)
    #expect(secondAuthorization.isApproved)
    #expect(approvals.count == 1)
    #expect(await presenter.prompts.count == 1)
}

@Test
func interactiveAgentApprovalGateDeniesPromptedApproval() async throws {
    let store = InMemoryApprovalStore()
    let presenter = RecordingApprovalPresenter(decisions: [.deny])
    let gate = InteractiveAgentApprovalGate(
        store: store,
        presenter: { prompt in
            await presenter.present(prompt)
        }
    )
    let requirement = codexPlanRequirement()

    await #expect(throws: RocaError.approvalDenied(requirement.detailText)) {
        _ = try await gate.authorization(for: requirement)
    }
    #expect(try await store.load().isEmpty)
}

@Test
func interactiveAgentApprovalGateReturnsToolDenialDecision() async throws {
    let store = InMemoryApprovalStore()
    let presenter = RecordingApprovalPresenter(decisions: [.deny])
    let gate = InteractiveAgentApprovalGate(
        store: store,
        presenter: { prompt in
            await presenter.present(prompt)
        }
    )
    let requirement = codexPlanRequirement()
    let prompt = AgentApprovalPrompt(requirement: requirement, title: "Codex Command", detail: "git status")

    let decision = try await gate.decision(for: prompt)

    #expect(decision == .deny)
    #expect(try await store.load().isEmpty)
}

private func codexPlanRequirement(
    dataScopes: [AgentDataScope] = [.prompt, .workspaceFiles],
    actionScopes: [AgentActionScope] = [.readWorkspace]
) -> AgentApprovalRequirement {
    AgentApprovalRequirement(
        providerID: "codex-agent",
        role: .coding,
        mode: .plan,
        workspacePath: "/tmp/project",
        dataScopes: dataScopes,
        actionScopes: actionScopes
    )
}

private actor RecordingApprovalPresenter {
    private var decisions: [AgentApprovalDecision]
    private(set) var prompts: [AgentApprovalPrompt] = []

    init(decisions: [AgentApprovalDecision]) {
        self.decisions = decisions
    }

    func present(_ prompt: AgentApprovalPrompt) -> AgentApprovalDecision {
        prompts.append(prompt)
        return decisions.isEmpty ? .cancel : decisions.removeFirst()
    }
}

private actor InMemoryApprovalStore: ApprovalStoring {
    private var approvals: [ApprovalRecord] = []

    func load() async throws -> [ApprovalRecord] {
        approvals
    }

    func save(_ approvals: [ApprovalRecord]) async throws {
        self.approvals = approvals
    }

    func revoke(_ approvalID: ApprovalID) async throws {
        approvals.removeAll { $0.id == approvalID }
    }

    func revokeAll() async throws {
        approvals = []
    }
}
