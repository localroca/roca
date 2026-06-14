import Foundation

public protocol ApprovalStoring: Sendable {
    func load() async throws -> [ApprovalRecord]
    func save(_ approvals: [ApprovalRecord]) async throws
    func revoke(_ approvalID: ApprovalID) async throws
    func revokeAll() async throws
}

public struct ApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: ApprovalID
    public var title: String
    public var detail: String
    public var category: ApprovalCategory
    public var agentScope: AgentApprovalScope?
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(
        id: ApprovalID,
        title: String,
        detail: String,
        category: ApprovalCategory,
        agentScope: AgentApprovalScope? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.category = category
        self.agentScope = agentScope
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public enum ApprovalCategory: String, Codable, CaseIterable, Sendable {
    case agent
    case provider
    case privacy
    case memory
    case other

    public var displayName: String {
        switch self {
        case .agent:
            "Agent"
        case .provider:
            "Provider"
        case .privacy:
            "Privacy"
        case .memory:
            "Memory"
        case .other:
            "Other"
        }
    }
}
