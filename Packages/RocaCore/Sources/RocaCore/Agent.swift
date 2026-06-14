import Foundation

public protocol AgentProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: AgentCapabilities { get }

    func prepare() async throws
    func start(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(_ runID: AgentRunID) async
}

public protocol AgentApprovalAuthorizing: Sendable {
    func authorization(for requirement: AgentApprovalRequirement) async throws -> AgentApprovalAuthorization
}

public protocol AgentApprovalDecisioning: Sendable {
    func decision(for prompt: AgentApprovalPrompt) async throws -> AgentApprovalDecision
}

public struct AgentCapabilities: Codable, Equatable, Sendable {
    public var supportsStreaming: Bool
    public var supportsToolApprovals: Bool
    public var supportsLocalExecution: Bool
    public var locality: ProviderLocality
    public var supportedModes: [AgentMode]

    public init(
        supportsStreaming: Bool,
        supportsToolApprovals: Bool,
        supportsLocalExecution: Bool,
        locality: ProviderLocality,
        supportedModes: [AgentMode]
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsToolApprovals = supportsToolApprovals
        self.supportsLocalExecution = supportsLocalExecution
        self.locality = locality
        self.supportedModes = supportedModes
    }
}

public enum AgentMode: String, Codable, CaseIterable, Sendable {
    case ask
    case plan
    case act

    public var displayName: String {
        switch self {
        case .ask:
            "Ask"
        case .plan:
            "Plan"
        case .act:
            "Act"
        }
    }
}

public enum AgentDataScope: String, Codable, CaseIterable, Sendable {
    case prompt
    case selectedText
    case transcriptSummary
    case activeAppMetadata
    case workspaceFiles
    case memory
    case logs

    public var displayName: String {
        switch self {
        case .prompt:
            "prompt"
        case .selectedText:
            "selected text"
        case .transcriptSummary:
            "transcript summary"
        case .activeAppMetadata:
            "active app metadata"
        case .workspaceFiles:
            "workspace files"
        case .memory:
            "memory"
        case .logs:
            "logs"
        }
    }
}

public enum AgentActionScope: String, Codable, CaseIterable, Sendable {
    case readWorkspace
    case editWorkspace
    case runCommands
    case useNetwork
    case useBrowser
    case createArtifacts
    case pushBranch

    public var displayName: String {
        switch self {
        case .readWorkspace:
            "read workspace"
        case .editWorkspace:
            "edit workspace"
        case .runCommands:
            "run commands"
        case .useNetwork:
            "use network"
        case .useBrowser:
            "use browser"
        case .createArtifacts:
            "create artifacts"
        case .pushBranch:
            "push branches"
        }
    }
}

public struct AgentRunRequest: Codable, Equatable, Sendable {
    public var runID: AgentRunID
    public var prompt: String
    public var mode: AgentMode
    public var role: BrainRole?
    public var workspacePath: String?
    public var modelID: String?
    public var dataScopes: [AgentDataScope]
    public var actionScopes: [AgentActionScope]
    public var metadata: [String: String]

    public init(
        runID: AgentRunID,
        prompt: String,
        mode: AgentMode,
        role: BrainRole? = .coding,
        workspacePath: String? = nil,
        modelID: String? = nil,
        dataScopes: [AgentDataScope] = [.prompt],
        actionScopes: [AgentActionScope] = [],
        metadata: [String: String] = [:]
    ) {
        self.runID = runID
        self.prompt = prompt
        self.mode = mode
        self.role = role
        self.workspacePath = workspacePath
        self.modelID = modelID
        self.dataScopes = Self.normalized(dataScopes)
        self.actionScopes = Self.normalized(actionScopes)
        self.metadata = metadata
    }
}

public enum AgentEvent: Equatable, Sendable {
    case started(runID: AgentRunID, providerID: ProviderID)
    case status(String)
    case textDelta(String)
    case toolActivity(AgentToolActivity)
    case approvalRequired(AgentApprovalRequirement)
    case final(AgentResponse)
    case cancelled(runID: AgentRunID)
}

public struct AgentToolActivity: Codable, Equatable, Sendable {
    public var itemID: String?
    public var kind: AgentToolKind
    public var title: String
    public var status: String?

    public init(itemID: String? = nil, kind: AgentToolKind, title: String, status: String? = nil) {
        self.itemID = itemID
        self.kind = kind
        self.title = title
        self.status = status
    }
}

public enum AgentToolKind: String, Codable, Equatable, Sendable {
    case command
    case fileChange
    case browser
    case network
    case other
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var text: String
    public var usedProvider: ProviderID
    public var metadata: [String: String]

    public init(text: String, usedProvider: ProviderID, metadata: [String: String] = [:]) {
        self.text = text
        self.usedProvider = usedProvider
        self.metadata = metadata
    }
}

public struct AgentApprovalRequirement: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var role: BrainRole?
    public var mode: AgentMode
    public var workspacePath: String?
    public var dataScopes: [AgentDataScope]
    public var actionScopes: [AgentActionScope]

    public init(
        providerID: ProviderID,
        role: BrainRole?,
        mode: AgentMode,
        workspacePath: String?,
        dataScopes: [AgentDataScope],
        actionScopes: [AgentActionScope]
    ) {
        self.providerID = providerID
        self.role = role
        self.mode = mode
        self.workspacePath = workspacePath
        self.dataScopes = AgentRunRequest.normalized(dataScopes)
        self.actionScopes = AgentRunRequest.normalized(actionScopes)
    }

    public var detailText: String {
        var pieces = ["\(mode.displayName.lowercased()) mode"]
        if let workspacePath {
            pieces.append(workspacePath)
        }
        if !dataScopes.isEmpty {
            pieces.append("data: \(dataScopes.map(\.displayName).joined(separator: ", "))")
        }
        if !actionScopes.isEmpty {
            pieces.append("actions: \(actionScopes.map(\.displayName).joined(separator: ", "))")
        }
        return pieces.joined(separator: " | ")
    }
}

public struct AgentApprovalPrompt: Codable, Equatable, Sendable {
    public var requirement: AgentApprovalRequirement
    public var title: String
    public var detail: String
    public var toolActivity: AgentToolActivity?

    public init(
        requirement: AgentApprovalRequirement,
        title: String,
        detail: String,
        toolActivity: AgentToolActivity? = nil
    ) {
        self.requirement = requirement
        self.title = title
        self.detail = detail
        self.toolActivity = toolActivity
    }
}

public struct AgentApprovalScope: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var role: BrainRole?
    public var mode: AgentMode
    public var workspacePath: String?
    public var dataScopes: [AgentDataScope]
    public var actionScopes: [AgentActionScope]

    public init(
        providerID: ProviderID,
        role: BrainRole?,
        mode: AgentMode,
        workspacePath: String?,
        dataScopes: [AgentDataScope],
        actionScopes: [AgentActionScope]
    ) {
        self.providerID = providerID
        self.role = role
        self.mode = mode
        self.workspacePath = workspacePath
        self.dataScopes = AgentRunRequest.normalized(dataScopes)
        self.actionScopes = AgentRunRequest.normalized(actionScopes)
    }

    public init(requirement: AgentApprovalRequirement) {
        self.init(
            providerID: requirement.providerID,
            role: requirement.role,
            mode: requirement.mode,
            workspacePath: requirement.workspacePath,
            dataScopes: requirement.dataScopes,
            actionScopes: requirement.actionScopes
        )
    }

    public func covers(_ requirement: AgentApprovalRequirement) -> Bool {
        providerID == requirement.providerID
            && role == requirement.role
            && mode == requirement.mode
            && workspacePath == requirement.workspacePath
            && Set(dataScopes).isSuperset(of: Set(requirement.dataScopes))
            && Set(actionScopes).isSuperset(of: Set(requirement.actionScopes))
    }
}

public enum AgentApprovalDecision: String, Codable, Equatable, Sendable {
    case approve
    case approveForSession
    case deny
    case cancel
}

public struct AgentApprovalAuthorization: Codable, Equatable, Sendable {
    public var isApproved: Bool
    public var approvalID: ApprovalID?

    public init(isApproved: Bool, approvalID: ApprovalID? = nil) {
        self.isApproved = isApproved
        self.approvalID = approvalID
    }

    public static let denied = AgentApprovalAuthorization(isApproved: false)
}

public struct DenyingAgentApprovalAuthorizer: AgentApprovalAuthorizing {
    public init() {}

    public func authorization(for requirement: AgentApprovalRequirement) async throws -> AgentApprovalAuthorization {
        .denied
    }
}

public struct DenyingAgentApprovalDecisioner: AgentApprovalDecisioning {
    public init() {}

    public func decision(for prompt: AgentApprovalPrompt) async throws -> AgentApprovalDecision {
        .cancel
    }
}

public actor AgentApprovalGate: AgentApprovalAuthorizing, AgentApprovalDecisioning {
    private let store: any ApprovalStoring

    public init(store: any ApprovalStoring) {
        self.store = store
    }

    public func authorization(for requirement: AgentApprovalRequirement) async throws -> AgentApprovalAuthorization {
        var approvals = try await store.load()
        guard let index = approvals.firstIndex(where: { $0.agentScope?.covers(requirement) == true }) else {
            return .denied
        }

        approvals[index].lastUsedAt = Date()
        try await store.save(approvals)
        return AgentApprovalAuthorization(isApproved: true, approvalID: approvals[index].id)
    }

    public func decision(for prompt: AgentApprovalPrompt) async throws -> AgentApprovalDecision {
        let authorization = try await authorization(for: prompt.requirement)
        return authorization.isApproved ? .approve : .cancel
    }

    @discardableResult
    public func grant(_ requirement: AgentApprovalRequirement, createdAt: Date = Date()) async throws -> ApprovalRecord {
        let record = Self.record(for: requirement, createdAt: createdAt)
        var approvals = try await store.load()
        approvals.removeAll { $0.id == record.id }
        approvals.append(record)
        try await store.save(approvals)
        return record
    }

    public static func record(for requirement: AgentApprovalRequirement, createdAt: Date = Date()) -> ApprovalRecord {
        let scope = AgentApprovalScope(requirement: requirement)
        return ApprovalRecord(
            id: approvalID(for: scope),
            title: "\(requirement.providerID.rawValue) \(requirement.mode.displayName)",
            detail: requirement.detailText,
            category: .agent,
            agentScope: scope,
            createdAt: createdAt
        )
    }

    public static func approvalID(for scope: AgentApprovalScope) -> ApprovalID {
        let key = [
            scope.providerID.rawValue,
            scope.role?.rawValue ?? "none",
            scope.mode.rawValue,
            scope.workspacePath ?? "none",
            scope.dataScopes.map(\.rawValue).joined(separator: ","),
            scope.actionScopes.map(\.rawValue).joined(separator: ",")
        ].joined(separator: "|")
        return ApprovalID(rawValue: "agent.\(stableHash(key))")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public actor InteractiveAgentApprovalGate: AgentApprovalAuthorizing, AgentApprovalDecisioning {
    public typealias ApprovalPresenter = @Sendable (AgentApprovalPrompt) async -> AgentApprovalDecision
    public typealias ApprovalChangeHandler = @Sendable () async -> Void

    private let rememberedGate: AgentApprovalGate
    private let presenter: ApprovalPresenter
    private let onApprovalsChanged: ApprovalChangeHandler

    public init(
        store: any ApprovalStoring,
        presenter: @escaping ApprovalPresenter,
        onApprovalsChanged: @escaping ApprovalChangeHandler = {}
    ) {
        self.rememberedGate = AgentApprovalGate(store: store)
        self.presenter = presenter
        self.onApprovalsChanged = onApprovalsChanged
    }

    public func authorization(for requirement: AgentApprovalRequirement) async throws -> AgentApprovalAuthorization {
        let remembered = try await rememberedGate.authorization(for: requirement)
        guard !remembered.isApproved else {
            return remembered
        }

        let decision = await presenter(Self.prompt(for: requirement))
        return try await authorization(for: decision, requirement: requirement)
    }

    public func decision(for prompt: AgentApprovalPrompt) async throws -> AgentApprovalDecision {
        let remembered = try await rememberedGate.authorization(for: prompt.requirement)
        guard !remembered.isApproved else {
            return .approve
        }

        let decision = await presenter(prompt)
        if decision == .approveForSession {
            try await remember(prompt.requirement)
        }
        return decision
    }

    private func authorization(
        for decision: AgentApprovalDecision,
        requirement: AgentApprovalRequirement
    ) async throws -> AgentApprovalAuthorization {
        switch decision {
        case .approve:
            return AgentApprovalAuthorization(isApproved: true)
        case .approveForSession:
            let record = try await remember(requirement)
            return AgentApprovalAuthorization(isApproved: true, approvalID: record.id)
        case .deny:
            throw RocaError.approvalDenied(requirement.detailText)
        case .cancel:
            throw RocaError.cancelled
        }
    }

    @discardableResult
    private func remember(_ requirement: AgentApprovalRequirement) async throws -> ApprovalRecord {
        let record = try await rememberedGate.grant(requirement)
        await onApprovalsChanged()
        return record
    }

    private nonisolated static func prompt(for requirement: AgentApprovalRequirement) -> AgentApprovalPrompt {
        AgentApprovalPrompt(
            requirement: requirement,
            title: "\(providerDisplayName(for: requirement.providerID)) needs approval",
            detail: requirement.detailText
        )
    }

    private nonisolated static func providerDisplayName(for providerID: ProviderID) -> String {
        switch providerID.rawValue {
        case "codex-agent":
            "Codex"
        case "claude-agent":
            "Claude"
        case "cursor-agent":
            "Cursor"
        default:
            providerID.rawValue
        }
    }
}

public extension AgentRunRequest {
    static func normalized<T: RawRepresentable>(_ values: [T]) -> [T] where T.RawValue == String {
        var seen = Set<String>()
        return values
            .sorted { $0.rawValue < $1.rawValue }
            .filter { seen.insert($0.rawValue).inserted }
    }
}
