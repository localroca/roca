import Foundation
import RocaCore
import RocaStorage
import Testing

@Test
func settingsStoreRoundTripsSpeechPreferences() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("RocaStorageTests-\(UUID().uuidString)", isDirectory: true)
    let store = JSONSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))

    let kokoro = ProviderID(rawValue: "kokoro")
    let macOS = ProviderID(rawValue: "macos-voice")
    let kokoroVoice = VoiceID(rawValue: "af_heart")
    let macOSVoice = VoiceID(rawValue: "com.apple.voice.compact.en-US.Samantha")

    var settings = RocaSettings.phaseOneDefault
    settings.selectedTTSProvider = macOS
    settings.selectedSTTProvider = ProviderID(rawValue: "moonshine")
    settings.dictationHotkey = HotkeyDefinition(key: "K", modifiers: ["control", "option", "command"])
    settings.dictationMode = .toggleToTalk
    settings.sttModelRecords = [
        ProviderID(rawValue: "moonshine"): STTModelRecord(
            modelID: "medium-streaming-en",
            displayName: "English Medium Streaming",
            localPath: "/tmp/model",
            installedAt: Date(timeIntervalSince1970: 100),
            verifiedAt: Date(timeIntervalSince1970: 120)
        )
    ]
    settings.providerVoiceSelections = [
        kokoro: kokoroVoice,
        macOS: macOSVoice
    ]
    settings.speechSpeed = 1.35
    settings.companionVisible = false
    settings.companionWarmth = .quiet
    settings.assistantSpeechMuted = true
    settings.brainRoles = [
        .companionRouter: BrainProviderSelection(
            providerID: ProviderID(rawValue: "ollama"),
            modelID: "qwen3:0.6b",
            displayName: "qwen3:0.6b"
        )
    ]
    settings.assistantOnboardingCompleted = true

    try await store.save(settings)
    let loaded = try await store.load()

    #expect(loaded.selectedTTSProvider == macOS)
    #expect(loaded.selectedSTTProvider == ProviderID(rawValue: "moonshine"))
    #expect(loaded.dictationHotkey == HotkeyDefinition(key: "K", modifiers: ["control", "option", "command"]))
    #expect(loaded.dictationMode == .toggleToTalk)
    #expect(loaded.sttModelRecords[ProviderID(rawValue: "moonshine")]?.modelID == "medium-streaming-en")
    #expect(loaded.providerVoiceSelections[kokoro] == kokoroVoice)
    #expect(loaded.providerVoiceSelections[macOS] == macOSVoice)
    #expect(loaded.speechSpeed == 1.35)
    #expect(loaded.brainRoles[.companionRouter]?.providerID == ProviderID(rawValue: "ollama"))
    #expect(loaded.brainRoles[.companionRouter]?.modelID == "qwen3:0.6b")
    #expect(loaded.assistantOnboardingCompleted)
    #expect(!loaded.companionVisible)
    #expect(loaded.companionWarmth == .quiet)
    #expect(loaded.assistantSpeechMuted)

    try? FileManager.default.removeItem(at: directory)
}
