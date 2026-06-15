import Foundation

public struct CapabilityID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

public enum CapabilityKind: String, Codable, CaseIterable, Sendable {
    case localChat
    case desktopAction
    case agent
}

public enum CapabilityWorkspaceRequirement: String, Codable, CaseIterable, Sendable {
    case none
    case optional
    case required
}

public enum CapabilityRiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

public enum CapabilityApprovalBehavior: String, Codable, CaseIterable, Sendable {
    case notRequired
    case policyDriven
    case alwaysAsk
}

public struct CapabilityDescriptor: Codable, Hashable, Sendable {
    public var id: CapabilityID
    public var providerID: ProviderID?
    public var kind: CapabilityKind
    public var displayName: String
    public var supportedAgentModes: [AgentMode]
    public var workspaceRequirement: CapabilityWorkspaceRequirement
    public var riskLevel: CapabilityRiskLevel
    public var approvalBehavior: CapabilityApprovalBehavior
    public var supportsStreaming: Bool
    public var supportsCancellation: Bool
    public var supportsProjectDiscovery: Bool
    public var locality: ProviderLocality

    public init(
        id: CapabilityID,
        providerID: ProviderID? = nil,
        kind: CapabilityKind,
        displayName: String,
        supportedAgentModes: [AgentMode] = [],
        workspaceRequirement: CapabilityWorkspaceRequirement,
        riskLevel: CapabilityRiskLevel,
        approvalBehavior: CapabilityApprovalBehavior,
        supportsStreaming: Bool,
        supportsCancellation: Bool,
        supportsProjectDiscovery: Bool,
        locality: ProviderLocality
    ) {
        self.id = id
        self.providerID = providerID
        self.kind = kind
        self.displayName = displayName
        self.supportedAgentModes = supportedAgentModes
        self.workspaceRequirement = workspaceRequirement
        self.riskLevel = riskLevel
        self.approvalBehavior = approvalBehavior
        self.supportsStreaming = supportsStreaming
        self.supportsCancellation = supportsCancellation
        self.supportsProjectDiscovery = supportsProjectDiscovery
        self.locality = locality
    }

    public static func agent(
        providerID: ProviderID,
        displayName: String,
        capabilities: AgentCapabilities,
        supportsProjectDiscovery: Bool
    ) -> CapabilityDescriptor {
        CapabilityDescriptor(
            id: CapabilityID(rawValue: providerID.rawValue),
            providerID: providerID,
            kind: .agent,
            displayName: displayName,
            supportedAgentModes: capabilities.supportedModes,
            workspaceRequirement: capabilities.supportedModes.contains(.act) ? .required : .optional,
            riskLevel: capabilities.supportedModes.contains(.act) ? .high : .medium,
            approvalBehavior: capabilities.supportsToolApprovals ? .policyDriven : .notRequired,
            supportsStreaming: capabilities.supportsStreaming,
            supportsCancellation: true,
            supportsProjectDiscovery: supportsProjectDiscovery,
            locality: capabilities.locality
        )
    }
}

public protocol CapabilityRegistry: Sendable {
    func capabilities() async -> [CapabilityDescriptor]
    func capabilities(kind: CapabilityKind) async -> [CapabilityDescriptor]
    func capability(id: CapabilityID) async -> CapabilityDescriptor?
    func register(_ descriptor: CapabilityDescriptor) async
}

public actor InMemoryCapabilityRegistry: CapabilityRegistry {
    private var descriptors: [CapabilityID: CapabilityDescriptor]

    public init(descriptors: [CapabilityDescriptor] = []) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public func capabilities() async -> [CapabilityDescriptor] {
        sorted(descriptors.values)
    }

    public func capabilities(kind: CapabilityKind) async -> [CapabilityDescriptor] {
        sorted(descriptors.values.filter { $0.kind == kind })
    }

    public func capability(id: CapabilityID) async -> CapabilityDescriptor? {
        descriptors[id]
    }

    public func register(_ descriptor: CapabilityDescriptor) async {
        descriptors[descriptor.id] = descriptor
    }

    private func sorted(_ values: some Sequence<CapabilityDescriptor>) -> [CapabilityDescriptor] {
        values.sorted { left, right in
            left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }
}
