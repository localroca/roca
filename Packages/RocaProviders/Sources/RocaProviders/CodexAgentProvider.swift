import Foundation
import RocaCore

public actor CodexAgentProvider: AgentProvider, AgentProjectDiscovering {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: AgentCapabilities

    private let client: any CodexAgentClient
    private let approvalAuthorizer: any AgentApprovalAuthorizing

    public init(
        id: ProviderID = BuiltInProviderIDs.codexAgent,
        displayName: String = "Codex",
        client: any CodexAgentClient = CodexAppServerClient(),
        approvalAuthorizer: any AgentApprovalAuthorizing = DenyingAgentApprovalAuthorizer()
    ) {
        self.id = id
        self.displayName = displayName
        self.client = client
        self.approvalAuthorizer = approvalAuthorizer
        self.capabilities = AgentCapabilities(
            supportsStreaming: true,
            supportsToolApprovals: true,
            supportsLocalExecution: true,
            locality: .remote,
            supportedModes: AgentMode.allCases
        )
    }

    public func prepare() async throws {
        try await client.prepare()
    }

    public func start(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let scopedRequest = CodexAgentPolicy.approvalScopedRequest(request)
        guard capabilities.supportedModes.contains(scopedRequest.mode) else {
            throw RocaError.providerUnavailable(id)
        }
        guard scopedRequest.mode != .act || scopedRequest.workspacePath != nil else {
            throw RocaError.approvalRequired("Codex act mode needs an approved workspace.")
        }

        if CodexAgentPolicy.requiresRocaApproval(request) {
            let requirement = CodexAgentPolicy.approvalRequirement(providerID: id, request: request)
            let authorization = try await approvalAuthorizer.authorization(for: requirement)
            guard authorization.isApproved else {
                throw RocaError.approvalRequired(requirement.detailText)
            }
        }

        return try await client.run(scopedRequest, providerID: id)
    }

    public func discoverProjects(matching query: ProjectDiscoveryQuery) async throws -> [ProjectDiscoveryCandidate] {
        try await client.discoverProjects(matching: query, providerID: id)
    }

    public func cancel(_ runID: AgentRunID) async {
        await client.cancel(runID)
    }
}
