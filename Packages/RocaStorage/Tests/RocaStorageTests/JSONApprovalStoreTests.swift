import Foundation
import RocaCore
import RocaStorage
import Testing

@Test
func approvalStoreLoadsEmptyWhenMissing() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("RocaApprovalStoreTests-\(UUID().uuidString)", isDirectory: true)
    let store = JSONApprovalStore(fileURL: directory.appendingPathComponent("approvals.json"))

    let approvals = try await store.load()

    #expect(approvals.isEmpty)

    try? FileManager.default.removeItem(at: directory)
}

@Test
func approvalStoreRoundTripsAndRevokesApprovals() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("RocaApprovalStoreTests-\(UUID().uuidString)", isDirectory: true)
    let store = JSONApprovalStore(fileURL: directory.appendingPathComponent("approvals.json"))
    let remoteProviderApproval = ApprovalRecord(
        id: "remote-provider.openai",
        title: "OpenAI Provider",
        detail: "Allow assistant requests to use the OpenAI provider.",
        category: .provider,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastUsedAt: Date(timeIntervalSince1970: 1_200)
    )
    let memoryApproval = ApprovalRecord(
        id: "memory.profile",
        title: "Profile Memory",
        detail: "Allow Roca to remember profile preferences.",
        category: .memory,
        createdAt: Date(timeIntervalSince1970: 1_100)
    )

    try await store.save([memoryApproval, remoteProviderApproval])
    let loaded = try await store.load()

    #expect(loaded.map(\.id) == [memoryApproval.id, remoteProviderApproval.id])
    #expect(loaded.first?.category == .memory)
    #expect(loaded.last?.lastUsedAt == remoteProviderApproval.lastUsedAt)

    try await store.revoke(memoryApproval.id)
    let afterRevoke = try await store.load()

    #expect(afterRevoke == [remoteProviderApproval])

    try await store.revokeAll()
    let afterRevokeAll = try await store.load()

    #expect(afterRevokeAll.isEmpty)

    try? FileManager.default.removeItem(at: directory)
}

@Test
func approvalStoreRoundTripsAgentApprovalScope() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("RocaApprovalStoreTests-\(UUID().uuidString)", isDirectory: true)
    let store = JSONApprovalStore(fileURL: directory.appendingPathComponent("approvals.json"))
    let requirement = AgentApprovalRequirement(
        providerID: "codex-agent",
        role: .coding,
        mode: .act,
        workspacePath: "/tmp/project",
        dataScopes: [.prompt, .workspaceFiles],
        actionScopes: [.editWorkspace, .runCommands]
    )
    let record = AgentApprovalGate.record(for: requirement, createdAt: Date(timeIntervalSince1970: 2_000))

    try await store.save([record])
    let loaded = try await store.load()

    #expect(loaded == [record])
    #expect(loaded.first?.agentScope?.covers(requirement) == true)

    try? FileManager.default.removeItem(at: directory)
}
