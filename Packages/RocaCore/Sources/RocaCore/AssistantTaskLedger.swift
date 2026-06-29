import Foundation

public struct AssistantTaskID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static func make() -> AssistantTaskID {
        AssistantTaskID(rawValue: UUID().uuidString)
    }
}

public enum AssistantTaskStatus: String, Codable, CaseIterable, Sendable {
    case created
    case resolvingProject
    case waitingForClarification
    case waitingForApproval
    case running
    case formattingResult
    case completed
    case failed
    case cancelled
}

public enum AssistantTaskEventKind: String, Codable, CaseIterable, Sendable {
    case created
    case providerResolved
    case projectResolutionStarted
    case projectResolved
    case clarificationRequested
    case clarificationResolved
    case approvalRequested
    case approvalResolved
    case skillRunStarted
    case skillRunFinished
    case providerRunStarted
    case providerRunFinished
    case resultFormattingStarted
    case resultFormatted
    case completed
    case failed
    case cancelled
}

public struct AssistantTaskEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var kind: AssistantTaskEventKind
    public var turnID: BrainRequestID?
    public var status: AssistantTaskStatus?
    public var phase: String?
    public var summary: String?
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        kind: AssistantTaskEventKind,
        turnID: BrainRequestID? = nil,
        status: AssistantTaskStatus? = nil,
        phase: String? = nil,
        summary: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.turnID = turnID
        self.status = status
        self.phase = phase
        self.summary = summary
        self.metadata = metadata
    }
}

public struct AssistantTaskRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: AssistantTaskID
    public var parentTaskID: AssistantTaskID?
    public var turnID: BrainRequestID
    public var createdAt: Date
    public var updatedAt: Date
    public var userRequest: String
    public var capabilityID: CapabilityID?
    public var providerID: ProviderID?
    public var providerName: String?
    public var mode: AgentMode?
    public var projectQuery: String?
    public var resolvedProject: ProjectIdentity?
    public var providerRunID: AgentRunID?
    public var providerSessionID: String?
    public var approvalDecision: AgentApprovalDecision?
    public var status: AssistantTaskStatus
    public var resultSummary: String?
    public var resultDetailsMarkdown: String?
    public var failurePhase: String?
    public var failureMessage: String?
    public var diagnosticCorrelationID: String?
    public var events: [AssistantTaskEvent]

    public init(
        id: AssistantTaskID = .make(),
        parentTaskID: AssistantTaskID? = nil,
        turnID: BrainRequestID,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        userRequest: String,
        capabilityID: CapabilityID? = nil,
        providerID: ProviderID? = nil,
        providerName: String? = nil,
        mode: AgentMode? = nil,
        projectQuery: String? = nil,
        resolvedProject: ProjectIdentity? = nil,
        providerRunID: AgentRunID? = nil,
        providerSessionID: String? = nil,
        approvalDecision: AgentApprovalDecision? = nil,
        status: AssistantTaskStatus = .created,
        resultSummary: String? = nil,
        resultDetailsMarkdown: String? = nil,
        failurePhase: String? = nil,
        failureMessage: String? = nil,
        diagnosticCorrelationID: String? = nil,
        events: [AssistantTaskEvent] = []
    ) {
        self.id = id
        self.parentTaskID = parentTaskID
        self.turnID = turnID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userRequest = userRequest
        self.capabilityID = capabilityID
        self.providerID = providerID
        self.providerName = providerName
        self.mode = mode
        self.projectQuery = projectQuery
        self.resolvedProject = resolvedProject
        self.providerRunID = providerRunID
        self.providerSessionID = providerSessionID
        self.approvalDecision = approvalDecision
        self.status = status
        self.resultSummary = resultSummary
        self.resultDetailsMarkdown = resultDetailsMarkdown
        self.failurePhase = failurePhase
        self.failureMessage = failureMessage
        self.diagnosticCorrelationID = diagnosticCorrelationID
        self.events = events
    }
}

public protocol AssistantTaskLedger: Sendable {
    @discardableResult
    func createTask(_ task: AssistantTaskRecord) async -> AssistantTaskRecord
    func recordEvent(_ event: AssistantTaskEvent, for taskID: AssistantTaskID) async
    func updateTask(
        _ taskID: AssistantTaskID,
        status: AssistantTaskStatus?,
        event: AssistantTaskEvent?,
        mutate: @Sendable (inout AssistantTaskRecord) -> Void
    ) async
    func task(id: AssistantTaskID) async -> AssistantTaskRecord?
    func tasks(for turnID: BrainRequestID) async -> [AssistantTaskRecord]
    func tasks() async -> [AssistantTaskRecord]
    func clear() async
}

public actor InMemoryAssistantTaskLedger: AssistantTaskLedger {
    private var records: [AssistantTaskID: AssistantTaskRecord] = [:]

    public init(records: [AssistantTaskRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    @discardableResult
    public func createTask(_ task: AssistantTaskRecord) async -> AssistantTaskRecord {
        var task = task
        let createdEvent = AssistantTaskEvent(
            kind: .created,
            turnID: task.turnID,
            status: task.status,
            summary: "Task created."
        )
        task.events.append(createdEvent)
        task.updatedAt = createdEvent.createdAt
        records[task.id] = task
        return task
    }

    public func recordEvent(_ event: AssistantTaskEvent, for taskID: AssistantTaskID) async {
        guard var record = records[taskID] else {
            return
        }
        record.events.append(event)
        record.updatedAt = event.createdAt
        if let status = event.status {
            record.status = status
        }
        records[taskID] = record
    }

    public func updateTask(
        _ taskID: AssistantTaskID,
        status: AssistantTaskStatus? = nil,
        event: AssistantTaskEvent? = nil,
        mutate: @Sendable (inout AssistantTaskRecord) -> Void = { _ in }
    ) async {
        guard var record = records[taskID] else {
            return
        }
        mutate(&record)
        if let status {
            record.status = status
        }
        if let event {
            record.events.append(event)
            record.updatedAt = event.createdAt
        } else {
            record.updatedAt = Date()
        }
        records[taskID] = record
    }

    public func task(id: AssistantTaskID) async -> AssistantTaskRecord? {
        records[id]
    }

    public func tasks(for turnID: BrainRequestID) async -> [AssistantTaskRecord] {
        sorted(records.values.filter { $0.turnID == turnID })
    }

    public func tasks() async -> [AssistantTaskRecord] {
        sorted(records.values)
    }

    public func clear() async {
        records.removeAll()
    }

    private func sorted(_ records: some Sequence<AssistantTaskRecord>) -> [AssistantTaskRecord] {
        records.sorted { $0.createdAt < $1.createdAt }
    }
}
