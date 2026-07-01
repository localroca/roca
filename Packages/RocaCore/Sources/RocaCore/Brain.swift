import Foundation

public protocol BrainProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: BrainCapabilities { get }

    func prepare() async throws
    func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error>
    func cancel(_ requestID: BrainRequestID) async
}

public protocol RouterBrain: Sendable {
    func route(_ request: RoutingRequest) async throws -> RoutingDecision
}

public struct BrainCapabilities: Codable, Sendable {
    public var supportsStreaming: Bool
    public var supportsToolCalls: Bool
    public var supportsLocalExecution: Bool
    public var locality: ProviderLocality

    public init(
        supportsStreaming: Bool,
        supportsToolCalls: Bool,
        supportsLocalExecution: Bool,
        locality: ProviderLocality
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalls = supportsToolCalls
        self.supportsLocalExecution = supportsLocalExecution
        self.locality = locality
    }
}

public struct BrainMessage: Codable, Sendable {
    public var role: BrainMessageRole
    public var content: String

    public init(role: BrainMessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

public enum BrainMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

public struct RequestContext: Codable, Sendable {
    public var selectedText: String?
    public var activeAppBundleID: String?
    public var activeAppName: String?
    public var memoryIDs: [MemoryID]

    public init(selectedText: String?, activeAppBundleID: String?, activeAppName: String?, memoryIDs: [MemoryID]) {
        self.selectedText = selectedText
        self.activeAppBundleID = activeAppBundleID
        self.activeAppName = activeAppName
        self.memoryIDs = memoryIDs
    }
}

public struct BrainRequest: Codable, Sendable {
    public var requestID: BrainRequestID
    public var messages: [BrainMessage]
    public var role: BrainRole?
    public var modelID: String?
    public var context: RequestContext
    public var metadata: [String: String]

    public init(
        requestID: BrainRequestID,
        messages: [BrainMessage],
        role: BrainRole?,
        modelID: String? = nil,
        context: RequestContext,
        metadata: [String: String] = [:]
    ) {
        self.requestID = requestID
        self.messages = messages
        self.role = role
        self.modelID = modelID
        self.context = context
        self.metadata = metadata
    }
}

public enum BrainRequestMetadataKeys {
    public static let requestTimeoutSeconds = "requestTimeoutSeconds"
}

public enum BrainEvent: Sendable {
    case started(requestID: BrainRequestID, providerID: ProviderID)
    case textDelta(String)
    case final(BrainResponse)
    case cancelled(requestID: BrainRequestID)
}

public struct BrainResponse: Codable, Sendable {
    public var text: String
    public var usedProvider: ProviderID
    public var metadata: [String: String]

    public init(text: String, usedProvider: ProviderID, metadata: [String: String]) {
        self.text = text
        self.usedProvider = usedProvider
        self.metadata = metadata
    }
}

public struct RoutingRequest: Codable, Sendable {
    public var userText: String
    public var selectedText: String?
    public var activeAppBundleID: String?
    public var availableRoles: [BrainRole: BrainProviderSelection]
    public var privacyPreference: PrivacyPreference
    public var disclosure: ContextDisclosure

    public init(
        userText: String,
        selectedText: String?,
        activeAppBundleID: String?,
        availableRoles: [BrainRole: BrainProviderSelection],
        privacyPreference: PrivacyPreference,
        disclosure: ContextDisclosure
    ) {
        self.userText = userText
        self.selectedText = selectedText
        self.activeAppBundleID = activeAppBundleID
        self.availableRoles = availableRoles
        self.privacyPreference = privacyPreference
        self.disclosure = disclosure
    }
}

public struct RoutingDecision: Codable, Sendable {
    public var role: BrainRole
    public var providerID: ProviderID?
    public var requiresUserApproval: Bool
    public var explanation: String

    public init(role: BrainRole, providerID: ProviderID?, requiresUserApproval: Bool, explanation: String) {
        self.role = role
        self.providerID = providerID
        self.requiresUserApproval = requiresUserApproval
        self.explanation = explanation
    }
}

public enum PrivacyPreference: String, Codable, Sendable {
    case localOnly
    case allowRemoteWithApproval
    case allowConfiguredRemote
}

public enum ContextDisclosure: String, Codable, Sendable {
    case localFullContext
    case remoteMinimalMetadata
    case remoteApprovedContext
}
