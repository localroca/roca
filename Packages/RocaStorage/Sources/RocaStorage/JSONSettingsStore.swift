import Foundation
import RocaCore

public actor JSONSettingsStore: SettingsStoring {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public static func phaseOneDefault(paths: ApplicationSupportPaths) -> JSONSettingsStore {
        JSONSettingsStore(fileURL: paths.settingsDirectory.appendingPathComponent("settings.json"))
    }

    public func load() async throws -> RocaSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .phaseOneDefault
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let disk = try decoder.decode(RocaSettingsDisk.self, from: data)
            return disk.domain
        } catch {
            throw RocaError.storageFailed(error.localizedDescription)
        }
    }

    public func save(_ settings: RocaSettings) async throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(RocaSettingsDisk(settings))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw RocaError.storageFailed(error.localizedDescription)
        }
    }
}

private struct RocaSettingsDisk: Codable {
    var selectedTTSProvider: String?
    var providerVoiceSelections: [String: String]
    var speechSpeed: Double
    var selectedSTTProvider: String?
    var dictationHotkey: HotkeyDefinition
    var dictationMode: STTMode
    var sttModelRecords: [String: STTModelRecord]
    var brainRoles: [String: BrainProviderSelection]
    var assistantOnboardingCompleted: Bool
    var hotkey: HotkeyDefinition
    var companionVisible: Bool
    var companionWarmth: CompanionWarmth
    var assistantSpeechMuted: Bool
    var privacyPreference: PrivacyPreference
    var rawTranscriptLoggingEnabled: Bool

    init(_ settings: RocaSettings) {
        self.selectedTTSProvider = settings.selectedTTSProvider?.rawValue
        self.providerVoiceSelections = Dictionary(
            uniqueKeysWithValues: settings.providerVoiceSelections.map { provider, voice in
                (provider.rawValue, voice.rawValue)
            }
        )
        self.speechSpeed = settings.speechSpeed
        self.selectedSTTProvider = settings.selectedSTTProvider?.rawValue
        self.dictationHotkey = settings.dictationHotkey
        self.dictationMode = settings.dictationMode
        self.sttModelRecords = Dictionary(uniqueKeysWithValues: settings.sttModelRecords.map { provider, record in
            (provider.rawValue, record)
        })
        self.brainRoles = Dictionary(uniqueKeysWithValues: settings.brainRoles.map { ($0.key.rawValue, $0.value) })
        self.assistantOnboardingCompleted = settings.assistantOnboardingCompleted
        self.hotkey = settings.hotkey
        self.companionVisible = settings.companionVisible
        self.companionWarmth = settings.companionWarmth
        self.assistantSpeechMuted = settings.assistantSpeechMuted
        self.privacyPreference = settings.privacyPreference
        self.rawTranscriptLoggingEnabled = settings.rawTranscriptLoggingEnabled
    }

    var domain: RocaSettings {
        RocaSettings(
            selectedTTSProvider: selectedTTSProvider.map(ProviderID.init(rawValue:)),
            providerVoiceSelections: Dictionary(uniqueKeysWithValues: providerVoiceSelections.map { provider, voice in
                (ProviderID(rawValue: provider), VoiceID(rawValue: voice))
            }),
            speechSpeed: speechSpeed,
            selectedSTTProvider: selectedSTTProvider.map(ProviderID.init(rawValue:)),
            dictationHotkey: dictationHotkey,
            dictationMode: dictationMode,
            sttModelRecords: Dictionary(uniqueKeysWithValues: sttModelRecords.map { provider, record in
                (ProviderID(rawValue: provider), record)
            }),
            brainRoles: Dictionary(uniqueKeysWithValues: brainRoles.compactMap { role, selection in
                guard let brainRole = BrainRole(rawValue: role) else {
                    return nil
                }
                return (brainRole, selection)
            }),
            assistantOnboardingCompleted: assistantOnboardingCompleted,
            hotkey: hotkey,
            companionVisible: companionVisible,
            companionWarmth: companionWarmth,
            assistantSpeechMuted: assistantSpeechMuted,
            privacyPreference: privacyPreference,
            rawTranscriptLoggingEnabled: rawTranscriptLoggingEnabled
        )
    }

    enum CodingKeys: String, CodingKey {
        case selectedTTSProvider
        case providerVoiceSelections
        case speechSpeed
        case selectedSTTProvider
        case dictationHotkey
        case dictationMode
        case sttModelRecords
        case brainRoles
        case assistantOnboardingCompleted
        case hotkey
        case companionVisible
        case companionWarmth
        case assistantSpeechMuted
        case privacyPreference
        case rawTranscriptLoggingEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedTTSProvider = try container.decodeIfPresent(String.self, forKey: .selectedTTSProvider)
        providerVoiceSelections = try container.decodeIfPresent([String: String].self, forKey: .providerVoiceSelections) ?? [:]
        speechSpeed = try container.decodeIfPresent(Double.self, forKey: .speechSpeed) ?? 1.0
        selectedSTTProvider = try container.decodeIfPresent(String.self, forKey: .selectedSTTProvider)
        dictationHotkey = try container.decodeIfPresent(HotkeyDefinition.self, forKey: .dictationHotkey)
            ?? RocaSettings.phaseOneDefault.dictationHotkey
        dictationMode = try container.decodeIfPresent(STTMode.self, forKey: .dictationMode) ?? .toggleToTalk
        sttModelRecords = try container.decodeIfPresent([String: STTModelRecord].self, forKey: .sttModelRecords) ?? [:]
        do {
            brainRoles = try container.decodeIfPresent([String: BrainProviderSelection].self, forKey: .brainRoles) ?? [:]
        } catch {
            let legacyRoles = try container.decodeIfPresent([String: String].self, forKey: .brainRoles) ?? [:]
            brainRoles = Dictionary(
                uniqueKeysWithValues: legacyRoles.map { role, provider in
                    (role, BrainProviderSelection(providerID: ProviderID(rawValue: provider)))
                }
            )
        }
        assistantOnboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .assistantOnboardingCompleted) ?? false
        hotkey = try container.decodeIfPresent(HotkeyDefinition.self, forKey: .hotkey) ?? RocaSettings.phaseOneDefault.hotkey
        companionVisible = try container.decodeIfPresent(Bool.self, forKey: .companionVisible) ?? true
        companionWarmth = try container.decodeIfPresent(CompanionWarmth.self, forKey: .companionWarmth) ?? .warm
        assistantSpeechMuted = try container.decodeIfPresent(Bool.self, forKey: .assistantSpeechMuted) ?? false
        privacyPreference = try container.decodeIfPresent(PrivacyPreference.self, forKey: .privacyPreference) ?? .localOnly
        rawTranscriptLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .rawTranscriptLoggingEnabled) ?? false
    }
}
