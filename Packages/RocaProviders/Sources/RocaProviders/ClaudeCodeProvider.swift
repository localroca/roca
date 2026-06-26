import Foundation
import RocaCore

public actor ClaudeCodeProvider: AgentProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: AgentCapabilities

    private let client: any ClaudeCodeClient
    private let approvalAuthorizer: any AgentApprovalAuthorizing

    public init(
        id: ProviderID = BuiltInProviderIDs.claudeCode,
        displayName: String = "Claude Code",
        client: any ClaudeCodeClient = ClaudeCodeCLIClient(),
        approvalAuthorizer: any AgentApprovalAuthorizing = DenyingAgentApprovalAuthorizer()
    ) {
        self.id = id
        self.displayName = displayName
        self.client = client
        self.approvalAuthorizer = approvalAuthorizer
        self.capabilities = AgentCapabilities(
            supportsStreaming: false,
            supportsToolApprovals: false,
            supportsLocalExecution: true,
            locality: .remote,
            supportedModes: AgentMode.allCases
        )
    }

    public func prepare() async throws {
        try await client.prepare(providerID: id, displayName: displayName)
    }

    public func start(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let scopedRequest = ClaudeCodePolicy.approvalScopedRequest(request)
        guard capabilities.supportedModes.contains(scopedRequest.mode) else {
            throw RocaError.providerUnavailable(id)
        }
        guard scopedRequest.mode != .act || scopedRequest.workspacePath != nil else {
            throw RocaError.approvalRequired("Claude Code act mode needs an approved workspace.")
        }

        if ClaudeCodePolicy.requiresRocaApproval(request) {
            let requirement = ClaudeCodePolicy.approvalRequirement(providerID: id, request: request)
            let authorization = try await approvalAuthorizer.authorization(for: requirement)
            guard authorization.isApproved else {
                throw RocaError.approvalRequired(requirement.detailText)
            }
        }

        return try await client.run(scopedRequest, providerID: id)
    }

    public func cancel(_ runID: AgentRunID) async {
        await client.cancel(runID)
    }
}

extension ClaudeCodeProvider: AgentProviderSetupChecking {
    public func setupStatus() async -> AgentProviderSetupStatus {
        await client.setupStatus(providerID: id, displayName: displayName)
    }
}
