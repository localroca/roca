import Foundation
import RocaCore
@testable import RocaProviders
import Testing

@Test
func claudeCodeProviderRequiresApprovalForActModeBeforeCallingClient() async throws {
    let client = RecordingClaudeCodeClient()
    let provider = ClaudeCodeProvider(
        client: client,
        approvalAuthorizer: FixedClaudeCodeApprovalAuthorizer(.denied)
    )
    let request = claudeRequest(mode: .act)

    do {
        _ = try await provider.start(request)
        Issue.record("Expected Claude Code provider to require approval.")
    } catch RocaError.approvalRequired(_) {
        #expect(await client.runCallCount == 0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func claudeCodeProviderRunsExplicitAskWithoutRocaApproval() async throws {
    let client = RecordingClaudeCodeClient()
    let provider = ClaudeCodeProvider(
        client: client,
        approvalAuthorizer: FixedClaudeCodeApprovalAuthorizer(.denied)
    )
    let request = claudeRequest(mode: .ask)

    let stream = try await provider.start(request)
    var events: [AgentEvent] = []
    for try await event in stream {
        events.append(event)
    }

    #expect(await client.runCallCount == 1)
    #expect(events == [.final(AgentResponse(text: "done", usedProvider: BuiltInProviderIDs.claudeCode))])
}

@Test
func claudeCodePolicyBuildsNonInteractiveCLIArguments() {
    let ask = claudeRequest(mode: .ask)
    let plan = claudeRequest(mode: .plan)
    let act = claudeRequest(mode: .act)

    #expect(ClaudeCodePolicy.arguments(for: ask).contains("-p"))
    #expect(ClaudeCodePolicy.arguments(for: ask).contains("--no-session-persistence"))
    #expect(ClaudeCodePolicy.arguments(for: ask).contains("default"))
    #expect(ClaudeCodePolicy.arguments(for: plan).contains("plan"))
    #expect(ClaudeCodePolicy.arguments(for: act).contains("acceptEdits"))
    #expect(ClaudeCodePolicy.requiresRocaApproval(act))
}

@Test
func claudeCodeSetupReportsMissingCLI() async {
    let client = ClaudeCodeCLIClient(
        isExecutableFile: { _ in false },
        fileExists: { _ in false }
    )

    let status = await client.setupStatus(providerID: BuiltInProviderIDs.claudeCode, displayName: "Claude Code")

    #expect(status.state == .runtimeMissing)
    #expect(status.summary.contains("CLI is not installed"))
    #expect(status.installCommand == ClaudeCodePolicy.setupInstallCommand)
    #expect(status.guidance.contains("Claude Code"))
    #expect(!status.guidance.contains("API key"))
}

@Test
func claudeCodeCLIClientTimesOutHungRunsPromptly() async throws {
    let scriptURL = try temporaryExecutableScript(
        """
        #!/bin/sh
        exec /bin/sleep 5
        """
    )
    let client = ClaudeCodeCLIClient(
        configuration: ClaudeCodeConfiguration(
            executableURL: scriptURL,
            setupTimeoutSeconds: 0.1,
            runTimeoutSeconds: 0.1
        )
    )
    var request = claudeRequest(mode: .ask)
    request.workspacePath = nil
    let stream = try await client.run(request, providerID: BuiltInProviderIDs.claudeCode)
    let startedAt = Date()

    do {
        for try await _ in stream {}
        Issue.record("Expected Claude Code run to time out.")
    } catch RocaError.providerTimedOut(let providerID, _) {
        #expect(providerID == BuiltInProviderIDs.claudeCode)
        #expect(Date().timeIntervalSince(startedAt) < 2)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func claudeRequest(mode: AgentMode, actionScopes: [AgentActionScope] = []) -> AgentRunRequest {
    AgentRunRequest(
        runID: "run",
        prompt: "Assess this project.",
        mode: mode,
        role: .coding,
        workspacePath: "/tmp/project",
        dataScopes: [.prompt],
        actionScopes: actionScopes
    )
}

private func temporaryExecutableScript(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-claude-code-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scriptURL = directory.appendingPathComponent("claude")
    try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

private actor RecordingClaudeCodeClient: ClaudeCodeClient {
    private(set) var runCallCount = 0

    func setupStatus(providerID: ProviderID, displayName: String) async -> AgentProviderSetupStatus {
        AgentProviderSetupStatus(
            providerID: providerID,
            displayName: displayName,
            state: .ready,
            summary: "\(displayName) is ready.",
            guidance: ""
        )
    }

    func prepare(providerID: ProviderID, displayName: String) async throws {}

    func run(_ request: AgentRunRequest, providerID: ProviderID) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        runCallCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.final(AgentResponse(text: "done", usedProvider: providerID)))
            continuation.finish()
        }
    }

    func cancel(_ runID: AgentRunID) async {}
}

private struct FixedClaudeCodeApprovalAuthorizer: AgentApprovalAuthorizing {
    let authorization: AgentApprovalAuthorization

    init(_ authorization: AgentApprovalAuthorization) {
        self.authorization = authorization
    }

    func authorization(for requirement: AgentApprovalRequirement) async throws -> AgentApprovalAuthorization {
        authorization
    }
}
