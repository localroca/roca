import Foundation

public protocol SettingsStoring: Sendable {
    func load() async throws -> RocaSettings
    func save(_ settings: RocaSettings) async throws
}

public struct RocaSettings: Codable, Sendable, Equatable {
    public var selectedTTSProvider: ProviderID?
    public var providerVoiceSelections: [ProviderID: VoiceID]
    public var speechSpeed: Double
    public var selectedSTTProvider: ProviderID?
    public var dictationHotkey: HotkeyDefinition
    public var dictationMode: STTMode
    public var sttModelRecords: [ProviderID: STTModelRecord]
    public var brainRoles: [BrainRole: BrainProviderSelection]
    public var assistantOnboardingCompleted: Bool
    public var hotkey: HotkeyDefinition
    public var companionVisible: Bool
    public var companionWarmth: CompanionWarmth
    public var assistantSpeechMuted: Bool
    public var privacyPreference: PrivacyPreference

    public init(
        selectedTTSProvider: ProviderID?,
        providerVoiceSelections: [ProviderID: VoiceID],
        speechSpeed: Double,
        selectedSTTProvider: ProviderID?,
        dictationHotkey: HotkeyDefinition,
        dictationMode: STTMode,
        sttModelRecords: [ProviderID: STTModelRecord],
        brainRoles: [BrainRole: BrainProviderSelection],
        assistantOnboardingCompleted: Bool,
        hotkey: HotkeyDefinition,
        companionVisible: Bool,
        companionWarmth: CompanionWarmth,
        assistantSpeechMuted: Bool,
        privacyPreference: PrivacyPreference
    ) {
        self.selectedTTSProvider = selectedTTSProvider
        self.providerVoiceSelections = providerVoiceSelections
        self.speechSpeed = speechSpeed
        self.selectedSTTProvider = selectedSTTProvider
        self.dictationHotkey = dictationHotkey
        self.dictationMode = dictationMode
        self.sttModelRecords = sttModelRecords
        self.brainRoles = brainRoles
        self.assistantOnboardingCompleted = assistantOnboardingCompleted
        self.hotkey = hotkey
        self.companionVisible = companionVisible
        self.companionWarmth = companionWarmth
        self.assistantSpeechMuted = assistantSpeechMuted
        self.privacyPreference = privacyPreference
    }

    public static let phaseOneDefault = RocaSettings(
        selectedTTSProvider: nil,
        providerVoiceSelections: [:],
        speechSpeed: 1.0,
        selectedSTTProvider: nil,
        dictationHotkey: HotkeyDefinition(key: "K", modifiers: ["control", "option", "command"]),
        dictationMode: .toggleToTalk,
        sttModelRecords: [:],
        brainRoles: [:],
        assistantOnboardingCompleted: false,
        hotkey: HotkeyDefinition(key: "K", modifiers: ["option", "command"]),
        companionVisible: true,
        companionWarmth: .warm,
        assistantSpeechMuted: false,
        privacyPreference: .localOnly
    )

    public var speechConfiguration: SpeechConfiguration {
        SpeechConfiguration(
            providerID: selectedTTSProvider,
            providerVoiceSelections: providerVoiceSelections,
            speed: speechSpeed,
            allowFallback: selectedTTSProvider == nil
        )
    }

    public var dictationConfiguration: DictationConfiguration {
        DictationConfiguration(
            providerID: selectedSTTProvider,
            mode: dictationMode,
            locale: "en-US",
            allowFallback: selectedSTTProvider == nil
        )
    }
}

public enum CompanionWarmth: String, Codable, Sendable, CaseIterable, Identifiable {
    case quiet
    case warm

    public var id: String { rawValue }
}

public struct BrainProviderSelection: Codable, Hashable, Sendable {
    public var providerID: ProviderID
    public var modelID: String?
    public var displayName: String?

    public init(providerID: ProviderID, modelID: String? = nil, displayName: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
    }
}

public struct SpeechConfiguration: Codable, Equatable, Sendable {
    public var providerID: ProviderID?
    public var providerVoiceSelections: [ProviderID: VoiceID]
    public var speed: Double
    public var allowFallback: Bool

    public init(
        providerID: ProviderID?,
        providerVoiceSelections: [ProviderID: VoiceID],
        speed: Double,
        allowFallback: Bool
    ) {
        self.providerID = providerID
        self.providerVoiceSelections = providerVoiceSelections
        self.speed = speed
        self.allowFallback = allowFallback
    }
}

public struct HotkeyDefinition: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct STTModelRecord: Codable, Equatable, Sendable {
    public var modelID: String
    public var displayName: String
    public var localPath: String
    public var installedAt: Date
    public var verifiedAt: Date

    public init(modelID: String, displayName: String, localPath: String, installedAt: Date, verifiedAt: Date) {
        self.modelID = modelID
        self.displayName = displayName
        self.localPath = localPath
        self.installedAt = installedAt
        self.verifiedAt = verifiedAt
    }
}
