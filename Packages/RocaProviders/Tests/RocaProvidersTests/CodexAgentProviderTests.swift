import Foundation
import RocaCore
@testable import RocaProviders
import Testing

@Test
func codexAgentProviderRequiresApprovalForActModeBeforeCallingClient() async throws {
    let client = RecordingCodexAgentClient()
    let provider = CodexAgentProvider(
        client: client,
        approvalAuthorizer: FixedAgentApprovalAuthorizer(.denied)
    )
    let request = codexRequest(mode: .act)

    do {
        _ = try await provider.start(request)
        Issue.record("Expected Codex provider to require approval.")
    } catch RocaError.approvalRequired(_) {
        #expect(await client.runCallCount == 0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func codexAgentProviderRunsExplicitAskWithoutRocaApproval() async throws {
    let client = RecordingCodexAgentClient()
    let provider = CodexAgentProvider(
        client: client,
        approvalAuthorizer: FixedAgentApprovalAuthorizer(.denied)
    )
    let request = codexRequest(mode: .ask)

    let stream = try await provider.start(request)
    var events: [AgentEvent] = []
    for try await event in stream {
        events.append(event)
    }

    #expect(await client.runCallCount == 1)
    #expect(events == [.final(AgentResponse(text: "done", usedProvider: BuiltInProviderIDs.codexAgent))])
}

@Test
func codexAgentProviderIncludesWorkspaceAccessInApprovalScope() async throws {
    let client = RecordingCodexAgentClient()
    let authorizer = RecordingAgentApprovalAuthorizer(AgentApprovalAuthorization(isApproved: true))
    let provider = CodexAgentProvider(client: client, approvalAuthorizer: authorizer)
    let request = AgentRunRequest(
        runID: "run",
        prompt: "Assess this project.",
        mode: .act,
        role: .coding,
        workspacePath: "/tmp/project",
        dataScopes: [.prompt],
        actionScopes: []
    )

    _ = try await provider.start(request)
    let requirement = try #require(await authorizer.requirements.first)

    #expect(requirement.dataScopes.contains(.workspaceFiles))
    #expect(requirement.actionScopes.contains(.readWorkspace))
    #expect(requirement.actionScopes.contains(.runCommands))
    #expect(requirement.actionScopes.contains(.editWorkspace))
}

@Test
func codexAgentPolicyKeepsNetworkAndPushScopesExplicit() {
    let defaultRequest = AgentRunRequest(
        runID: "run",
        prompt: "Assess this project.",
        mode: .plan,
        workspacePath: "/tmp/project"
    )
    let explicitRequest = AgentRunRequest(
        runID: "run",
        prompt: "Assess this project.",
        mode: .plan,
        workspacePath: "/tmp/project",
        actionScopes: [.pushBranch, .useNetwork]
    )

    let defaultScopedRequest = CodexAgentPolicy.approvalScopedRequest(defaultRequest)
    let explicitScopedRequest = CodexAgentPolicy.approvalScopedRequest(explicitRequest)

    #expect(defaultScopedRequest.actionScopes.contains(.readWorkspace))
    #expect(defaultScopedRequest.actionScopes.contains(.runCommands))
    #expect(!defaultScopedRequest.actionScopes.contains(.useNetwork))
    #expect(!defaultScopedRequest.actionScopes.contains(.pushBranch))
    #expect(explicitScopedRequest.actionScopes.contains(.useNetwork))
    #expect(explicitScopedRequest.actionScopes.contains(.pushBranch))
    #expect(!CodexAgentPolicy.requiresRocaApproval(defaultRequest))
    #expect(CodexAgentPolicy.requiresRocaApproval(explicitRequest))
}

@Test
func codexAgentPolicyAddsEditScopeForActMode() {
    let request = AgentRunRequest(
        runID: "run",
        prompt: "Update this project.",
        mode: .act,
        workspacePath: "/tmp/project"
    )

    let scopedRequest = CodexAgentPolicy.approvalScopedRequest(request)

    #expect(scopedRequest.actionScopes.contains(.editWorkspace))
    #expect(scopedRequest.actionScopes.contains(.runCommands))
    #expect(CodexAgentPolicy.requiresRocaApproval(request))
}

@Test
func codexAgentProviderRequiresWorkspaceForActMode() async throws {
    let client = RecordingCodexAgentClient()
    let provider = CodexAgentProvider(
        client: client,
        approvalAuthorizer: FixedAgentApprovalAuthorizer(AgentApprovalAuthorization(isApproved: true))
    )
    let request = AgentRunRequest(
        runID: "run",
        prompt: "Update this project.",
        mode: .act,
        workspacePath: nil,
        dataScopes: [.prompt],
        actionScopes: [.editWorkspace]
    )

    do {
        _ = try await provider.start(request)
        Issue.record("Expected Codex act mode to require a workspace.")
    } catch RocaError.approvalRequired(_) {
        #expect(await client.runCallCount == 0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func codexAgentProviderDelegatesProjectDiscovery() async throws {
    let client = RecordingCodexAgentClient()
    let provider = CodexAgentProvider(client: client)
    let query = ProjectDiscoveryQuery(projectName: "uni-auth", prompt: "what passkey endpoints exist?")

    _ = try await provider.discoverProjects(matching: query)

    #expect(await client.discoveryQueries == [query])
}

@Test
func codexAppServerProjectDiscoveryTimesOut() async throws {
    let executableURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-hanging-\(UUID().uuidString).sh")
    try """
    #!/bin/sh
    sleep 10
    """.write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    defer { try? FileManager.default.removeItem(at: executableURL) }

    let client = CodexAppServerClient(
        configuration: CodexAppServerConfiguration(
            executableURL: executableURL,
            projectDiscoveryTimeoutSeconds: 0.1
        )
    )

    await #expect(throws: RocaError.providerTimedOut(providerID: BuiltInProviderIDs.codexAgent, modelID: "Codex project discovery")) {
        _ = try await client.discoverProjects(
            matching: ProjectDiscoveryQuery(projectName: "uni-auth", prompt: "what passkey endpoints exist?"),
            providerID: BuiltInProviderIDs.codexAgent
        )
    }
}

@Test
func codexAppServerProjectDiscoveryCanReturnEarlyForClearHighConfidenceMatch() {
    let candidate = ProjectDiscoveryCandidate(
        project: ProjectIdentity(displayName: "Uni Auth", localPath: "/tmp/uni-auth"),
        confidence: .high,
        score: 108
    )
    let runnerUp = ProjectDiscoveryCandidate(
        project: ProjectIdentity(displayName: "Uni Auth Infra", localPath: "/tmp/uni-auth-infra"),
        confidence: .medium,
        score: 70
    )

    #expect(CodexAppServerClient.shouldReturnEarly([candidate, runnerUp]))
}

@Test
func codexAppServerProjectDiscoveryKeepsSearchingForCloseMatches() {
    let candidate = ProjectDiscoveryCandidate(
        project: ProjectIdentity(displayName: "TER Backend", localPath: "/tmp/ter-backend"),
        confidence: .high,
        score: 104
    )
    let runnerUp = ProjectDiscoveryCandidate(
        project: ProjectIdentity(displayName: "TER Frontend", localPath: "/tmp/ter-frontend"),
        confidence: .high,
        score: 92
    )

    #expect(!CodexAppServerClient.shouldReturnEarly([candidate, runnerUp]))
}

@Test
func codexRequestBuilderMapsPlanToReadOnlySandbox() throws {
    let request = codexRequest(mode: .plan, actionScopes: [.useNetwork])

    let params = CodexAppServerRequestBuilder.turnStartParams(for: request, threadID: "thread")
    let sandbox = try #require(params["sandboxPolicy"]?.objectValue)

    #expect(sandbox["type"]?.stringValue == "readOnly")
    #expect(sandbox["networkAccess"] == .bool(true))
}

@Test
func codexRequestBuilderMapsActToWorkspaceWriteSandbox() throws {
    let request = codexRequest(mode: .act, actionScopes: [.editWorkspace, .runCommands])

    let params = CodexAppServerRequestBuilder.turnStartParams(for: request, threadID: "thread")
    let sandbox = try #require(params["sandboxPolicy"]?.objectValue)
    let writableRoots = try #require(sandbox["writableRoots"]?.arrayValue)

    #expect(sandbox["type"]?.stringValue == "workspaceWrite")
    #expect(sandbox["networkAccess"] == .bool(false))
    #expect(writableRoots == [.string("/tmp/project")])
}

@Test
func codexApprovalResponseMapsPermissionsApprovalToRequestedProfile() {
    let permissions = CodexJSONValue.object([
        "network": .object(["enabled": .bool(true)])
    ])
    let message = CodexRPCMessage(
        id: .int(7),
        method: "item/permissions/requestApproval",
        params: .object(["permissions": permissions])
    )

    let response = CodexAppServerClient.approvalResponse(for: message, decision: .approveForSession)

    #expect(response == .object([
        "permissions": permissions,
        "scope": .string("session")
    ]))
}

@Test
func codexApprovalResponseDeniesPermissionsWithEmptyGrant() {
    let permissions = CodexJSONValue.object([
        "network": .object(["enabled": .bool(true)])
    ])
    let message = CodexRPCMessage(
        id: .int(7),
        method: "item/permissions/requestApproval",
        params: .object(["permissions": permissions])
    )

    let response = CodexAppServerClient.approvalResponse(for: message, decision: .deny)

    #expect(response == .object([
        "permissions": .object([:]),
        "scope": .string("turn")
    ]))
}

private func codexRequest(
    mode: AgentMode,
    actionScopes: [AgentActionScope] = [.readWorkspace]
) -> AgentRunRequest {
    AgentRunRequest(
        runID: "run",
        prompt: "Assess this project.",
        mode: mode,
        role: .coding,
        workspacePath: "/tmp/project",
        modelID: "gpt-5",
        dataScopes: [.prompt, .workspaceFiles],
        actionScopes: actionScopes
    )
}

private struct FixedAgentApprovalAuthorizer: AgentApprovalAuthorizing {
    var authorization: AgentApprovalAuthorization

    init(_ authorization: AgentApprovalAuthorization) {
        self.authorization = authorization
    }

    func authorization(for requirement: AgentApprovalRequirement) async throws -> AgentApprovalAuthorization {
        authorization
    }
}

private actor RecordingAgentApprovalAuthorizer: AgentApprovalAuthorizing {
    private(set) var requirements: [AgentApprovalRequirement] = []
    var authorization: AgentApprovalAuthorization

    init(_ authorization: AgentApprovalAuthorization) {
        self.authorization = authorization
    }

    func authorization(for requirement: AgentApprovalRequirement) async throws -> AgentApprovalAuthorization {
        requirements.append(requirement)
        return authorization
    }
}

private actor RecordingCodexAgentClient: CodexAgentClient {
    private(set) var runCallCount = 0
    private(set) var discoveryQueries: [ProjectDiscoveryQuery] = []

    func prepare() async throws {}

    func run(_ request: AgentRunRequest, providerID: ProviderID) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        runCallCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.final(AgentResponse(text: "done", usedProvider: providerID)))
            continuation.finish()
        }
    }

    func discoverProjects(
        matching query: ProjectDiscoveryQuery,
        providerID: ProviderID
    ) async throws -> [ProjectDiscoveryCandidate] {
        discoveryQueries.append(query)
        return []
    }

    func cancel(_ runID: AgentRunID) async {}
}
