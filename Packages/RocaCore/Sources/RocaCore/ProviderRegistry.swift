import Foundation

public protocol ProviderRegistry: Sendable {
    func providers(kind: ProviderKind) async -> [ProviderDescriptor]
    func provider(id: ProviderID) async -> ProviderDescriptor?
    func register(_ descriptor: ProviderDescriptor) async
    func setEnabled(_ enabled: Bool, for id: ProviderID) async throws
}

public struct ProviderDescriptor: Codable, Hashable, Sendable {
    public var id: ProviderID
    public var kind: ProviderKind
    public var displayName: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var locality: ProviderLocality

    public init(
        id: ProviderID,
        kind: ProviderKind,
        displayName: String,
        isEnabled: Bool,
        isBuiltIn: Bool,
        locality: ProviderLocality
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.locality = locality
    }
}

public actor InMemoryProviderRegistry: ProviderRegistry {
    private var descriptors: [ProviderID: ProviderDescriptor]

    public init(descriptors: [ProviderDescriptor] = []) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public func providers(kind: ProviderKind) async -> [ProviderDescriptor] {
        descriptors.values
            .filter { $0.kind == kind }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func provider(id: ProviderID) async -> ProviderDescriptor? {
        descriptors[id]
    }

    public func register(_ descriptor: ProviderDescriptor) async {
        descriptors[descriptor.id] = descriptor
    }

    public func setEnabled(_ enabled: Bool, for id: ProviderID) async throws {
        guard var descriptor = descriptors[id] else {
            throw RocaError.providerUnavailable(id)
        }
        descriptor.isEnabled = enabled
        descriptors[id] = descriptor
    }
}

public protocol ProviderResolving: Sendable {
    func ttsProvider(_ request: TTSResolutionRequest) async throws -> any TTSProvider
    func sttProvider(_ request: STTResolutionRequest) async throws -> any STTProvider
    func brainProvider(id: ProviderID?) async throws -> any BrainProvider
    func agentProvider(id: ProviderID?) async throws -> any AgentProvider
}

public extension ProviderResolving {
    func agentProvider(id: ProviderID?) async throws -> any AgentProvider {
        throw RocaError.providerUnavailable(id ?? ProviderID(rawValue: "agent.default"))
    }
}

public struct TTSResolutionRequest: Sendable {
    public var requestedProviderID: ProviderID?
    public var source: SpeechSource?
    public var allowFallback: Bool

    public init(requestedProviderID: ProviderID?, source: SpeechSource?, allowFallback: Bool) {
        self.requestedProviderID = requestedProviderID
        self.source = source
        self.allowFallback = allowFallback
    }
}

public struct STTResolutionRequest: Sendable {
    public var requestedProviderID: ProviderID?
    public var locale: String?
    public var intent: VoiceInputIntent
    public var allowFallback: Bool
    public var requireLocal: Bool

    public init(
        requestedProviderID: ProviderID?,
        locale: String?,
        intent: VoiceInputIntent,
        allowFallback: Bool,
        requireLocal: Bool
    ) {
        self.requestedProviderID = requestedProviderID
        self.locale = locale
        self.intent = intent
        self.allowFallback = allowFallback
        self.requireLocal = requireLocal
    }
}

public actor DefaultProviderResolver: ProviderResolving {
    public typealias SelectedProviderLoader = @Sendable () async -> ProviderID?

    private let registry: any ProviderRegistry
    private let ttsProviders: [ProviderID: any TTSProvider]
    private let sttProviders: [ProviderID: any STTProvider]
    private let brainProviders: [ProviderID: any BrainProvider]
    private let agentProviders: [ProviderID: any AgentProvider]
    private let selectedTTSProvider: SelectedProviderLoader
    private let selectedSTTProvider: SelectedProviderLoader
    private let ttsFallbackOrder: [ProviderID]
    private let sttFallbackOrder: [ProviderID]

    public init(
        registry: any ProviderRegistry,
        ttsProviders: [any TTSProvider],
        sttProviders: [any STTProvider] = [],
        brainProviders: [any BrainProvider] = [],
        agentProviders: [any AgentProvider] = [],
        selectedTTSProvider: @escaping SelectedProviderLoader = { nil },
        selectedSTTProvider: @escaping SelectedProviderLoader = { nil },
        ttsFallbackOrder: [ProviderID],
        sttFallbackOrder: [ProviderID] = []
    ) {
        self.registry = registry
        self.ttsProviders = Dictionary(uniqueKeysWithValues: ttsProviders.map { ($0.id, $0) })
        self.sttProviders = Dictionary(uniqueKeysWithValues: sttProviders.map { ($0.id, $0) })
        self.brainProviders = Dictionary(uniqueKeysWithValues: brainProviders.map { ($0.id, $0) })
        self.agentProviders = Dictionary(uniqueKeysWithValues: agentProviders.map { ($0.id, $0) })
        self.selectedTTSProvider = selectedTTSProvider
        self.selectedSTTProvider = selectedSTTProvider
        self.ttsFallbackOrder = ttsFallbackOrder
        self.sttFallbackOrder = sttFallbackOrder
    }

    public func ttsProvider(_ request: TTSResolutionRequest) async throws -> any TTSProvider {
        var candidates: [ProviderID] = []
        if let requestedProviderID = request.requestedProviderID {
            candidates.append(requestedProviderID)
        }
        if request.source != .voicePreview, let selected = await selectedTTSProvider() {
            candidates.append(selected)
        }
        if request.allowFallback {
            candidates.append(contentsOf: ttsFallbackOrder)
        }

        var seen = Set<ProviderID>()
        var firstPreparationError: Error?
        for candidate in candidates where seen.insert(candidate).inserted {
            guard let descriptor = await registry.provider(id: candidate), descriptor.isEnabled else {
                if request.allowFallback {
                    continue
                }
                throw RocaError.providerUnavailable(candidate)
            }
            guard let provider = ttsProviders[candidate] else {
                if request.allowFallback {
                    continue
                }
                throw RocaError.providerUnavailable(candidate)
            }
            do {
                try await provider.prepare()
                return provider
            } catch {
                firstPreparationError = firstPreparationError ?? error
                if request.allowFallback {
                    continue
                }
                throw error
            }
        }

        if let firstPreparationError {
            throw firstPreparationError
        }
        throw RocaError.providerUnavailable(request.requestedProviderID ?? ProviderID(rawValue: "tts.default"))
    }

    public func sttProvider(_ request: STTResolutionRequest) async throws -> any STTProvider {
        var candidates: [ProviderID] = []
        if let requestedProviderID = request.requestedProviderID {
            candidates.append(requestedProviderID)
        }
        if let selected = await selectedSTTProvider() {
            candidates.append(selected)
        }
        if request.allowFallback {
            candidates.append(contentsOf: sttFallbackOrder)
        }

        var seen = Set<ProviderID>()
        var firstPreparationError: Error?
        for candidate in candidates where seen.insert(candidate).inserted {
            guard let descriptor = await registry.provider(id: candidate), descriptor.isEnabled else {
                if request.allowFallback {
                    continue
                }
                throw RocaError.providerUnavailable(candidate)
            }
            guard !request.requireLocal || descriptor.locality != .remote else {
                if request.allowFallback {
                    continue
                }
                throw RocaError.providerUnavailable(candidate)
            }
            guard let provider = sttProviders[candidate] else {
                if request.allowFallback {
                    continue
                }
                throw RocaError.providerUnavailable(candidate)
            }
            do {
                try await provider.prepare()
                return provider
            } catch {
                firstPreparationError = firstPreparationError ?? error
                if request.allowFallback {
                    continue
                }
                throw error
            }
        }

        if let firstPreparationError {
            throw firstPreparationError
        }
        throw RocaError.providerUnavailable(request.requestedProviderID ?? ProviderID(rawValue: "stt.default"))
    }

    public func brainProvider(id: ProviderID?) async throws -> any BrainProvider {
        if let id, let provider = brainProviders[id] {
            return provider
        }
        throw RocaError.providerUnavailable(id ?? ProviderID(rawValue: "brain.default"))
    }

    public func agentProvider(id: ProviderID?) async throws -> any AgentProvider {
        guard let id else {
            throw RocaError.providerUnavailable(ProviderID(rawValue: "agent.default"))
        }
        guard let descriptor = await registry.provider(id: id),
              descriptor.kind == .agent,
              descriptor.isEnabled else {
            throw RocaError.providerUnavailable(id)
        }
        guard let provider = agentProviders[id] else {
            throw RocaError.providerUnavailable(id)
        }
        try await provider.prepare()
        return provider
    }
}
