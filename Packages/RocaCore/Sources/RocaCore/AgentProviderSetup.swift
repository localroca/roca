import Foundation

public enum AgentProviderSetupState: String, Codable, Equatable, Sendable {
    case ready
    case appDetectedNeedsRuntime
    case runtimeMissing
    case authMissing
    case unavailable
    case unknown
}

public struct AgentProviderSetupStatus: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var displayName: String
    public var state: AgentProviderSetupState
    public var summary: String
    public var guidance: String
    public var installCommand: String?
    public var detectedApplicationPath: String?

    public init(
        providerID: ProviderID,
        displayName: String,
        state: AgentProviderSetupState,
        summary: String,
        guidance: String,
        installCommand: String? = nil,
        detectedApplicationPath: String? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.state = state
        self.summary = summary
        self.guidance = guidance
        self.installCommand = installCommand
        self.detectedApplicationPath = detectedApplicationPath
    }

    public var isReady: Bool {
        state == .ready
    }

    public var userMessage: String {
        [summary, guidance].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public protocol AgentProviderSetupChecking: Sendable {
    func setupStatus() async -> AgentProviderSetupStatus
}
