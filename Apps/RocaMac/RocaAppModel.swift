import AppKit
import Foundation
import OSLog
import RocaCore
import RocaProviders
import RocaServices
import RocaStorage

@MainActor
final class RocaAppModel: ObservableObject {
    @Published private(set) var statusText = "Starting Roca..."
    @Published private(set) var speechProviderMode: SpeechProviderMode = .automatic
    @Published private(set) var speechSpeed = 1.0
    @Published private(set) var providerVoiceSelections: [ProviderID: VoiceID] = [:]
    @Published private(set) var ttsVoices: [ProviderID: [TTSVoice]] = [:]
    @Published private(set) var voiceLoadMessages: [ProviderID: String] = [:]
    @Published private(set) var loadingVoiceProviderIDs: Set<ProviderID> = []
    @Published private(set) var previewStatus = "Ready"
    @Published private(set) var isPreviewing = false
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var kokoroNativeStatus = "Not checked"
    @Published private(set) var isKokoroModelInstalled = false
    @Published private(set) var isInstallingKokoroModel = false
    @Published private(set) var kokoroDownloadProgress: ManagedDownloadProgress?
    @Published private(set) var kokoroVoiceGroups: [KokoroVoiceGroupSettingsState] = []
    @Published private(set) var installingKokoroVoiceGroupIDs: Set<String> = []
    @Published private(set) var isSpeechActive = false
    @Published private(set) var isSpeechAudioPlaying = false
    @Published private(set) var speechAudioLevel = 0.0
    @Published private(set) var dictationStatus = "Ready"
    @Published private(set) var isDictationActive = false
    @Published private(set) var isMicrophoneAllowed = false
    @Published private(set) var microphoneStatus = "Not checked"
    @Published private(set) var isSpeechRecognitionAllowed = false
    @Published private(set) var speechRecognitionStatus = "Not checked"
    @Published private(set) var sttProviderMode: STTProviderMode = .automatic
    @Published private(set) var moonshineModelStatus = "Not checked"
    @Published private(set) var isMoonshineModelInstalled = false
    @Published private(set) var isInstallingMoonshineModel = false
    @Published private(set) var moonshineDownloadProgress: ManagedDownloadProgress?
    @Published private(set) var hasRecoverableDictationTranscript = false
    @Published private(set) var assistantStatus = "Not configured"
    @Published private(set) var isAssistantActive = false
    @Published private(set) var isAssistantTurnActive = false
    @Published private(set) var assistantTurnMetrics: [AssistantTurnMetrics] = []
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var ollamaStatus = "Not checked"
    @Published private(set) var ollamaModels: [OllamaModel] = []
    @Published private(set) var selectedOllamaModelID: String?
    @Published private(set) var selectedCompanionRouterOllamaModelID: String?
    @Published private(set) var selectedGeneralChatOllamaModelID: String?
    @Published private(set) var companionVisible = true
    @Published private(set) var companionWarmth: CompanionWarmth = .warm
    @Published private(set) var assistantSpeechMuted = false
    @Published private(set) var rawTranscriptLoggingEnabled = false
    @Published private(set) var hasChatTranscriptLog = false
    @Published private(set) var chatTranscriptLogSummary = "No raw transcript log yet"
    @Published private(set) var chatTranscriptLogActionStatus = ""
    @Published private(set) var companionActivity: RocaActivity = .idle
    @Published private(set) var companionMessage = "Ready"

    private let paths: ApplicationSupportPaths
    private let settingsStore: JSONSettingsStore
    private let registry: InMemoryProviderRegistry
    private let permissionsService = DefaultPermissionsService()
    private let companionState = CompanionStateCenter()
    private let playback = DefaultSpeechPlaybackController()
    private let selectionReader = DefaultSelectionReader()
    private let currentSpeechSettings = CurrentSpeechSettingsStore(settings: .phaseOneDefault)
    private let currentDictationSettings = CurrentDictationSettingsStore(settings: .phaseOneDefault)
    private let kokoroAssetStore: ProviderAssetStore
    private let moonshineModelStore: MoonshineModelStore
    private let assistantMetricsLogStore: AssistantTurnMetricsLogStore
    private let chatTranscriptLogStore: ChatTranscriptLogStore
    private let chatTranscriptLogger = Logger(subsystem: "Roca", category: "ChatTranscript")

    private var settings: RocaSettings = .phaseOneDefault
    private var ttsProviders: [ProviderID: any TTSProvider] = [:]
    private var sttProviders: [ProviderID: any STTProvider] = [:]
    private var speechOrchestrator: DefaultSpeechOrchestrator?
    private var readSelectionCommand: ReadSelectionCommand?
    private var dictationOrchestrator: DefaultDictationOrchestrator?
    private var assistantSession: DefaultAssistantSessionOrchestrator?
    private var companionTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var dictationTask: Task<Void, Never>?
    private var dictationStateTask: Task<Void, Never>?
    private var assistantTask: Task<Void, Never>?
    private var assistantStateTask: Task<Void, Never>?
    private var assistantMessageTask: Task<Void, Never>?
    private var assistantMetricsTask: Task<Void, Never>?
    private var kokoroInstallTask: Task<Void, Never>?
    private var kokoroWarmupTask: Task<Void, Never>?
    private var moonshineInstallTask: Task<Void, Never>?
    private var settingsSaveTask: Task<String?, Never>?
    private var isTerminating = false
    private var voiceLoadGenerations: [ProviderID: Int] = [:]
    private var previewGeneration = 0
    private var rawTranscriptLoggingGeneration = 0
    private var activePreviewPlaybackGeneration: Int?
    private var ollamaInstalledAppURL: URL?
    private var chatPanelPresenter: (@MainActor () -> Void)?
    private var loggedChatTranscriptMessageIDs: Set<ChatMessageID> = []
    private var pendingChatTranscriptMessageIDs: Set<ChatMessageID> = []

    init() {
        do {
            let paths = try ApplicationSupportPaths.roca()
            self.paths = paths
            self.settingsStore = JSONSettingsStore.phaseOneDefault(paths: paths)
            self.kokoroAssetStore = ProviderAssetStore(rootDirectory: paths.modelsDirectory)
            self.moonshineModelStore = MoonshineModelStore(rootDirectory: paths.modelsDirectory)
            self.assistantMetricsLogStore = AssistantTurnMetricsLogStore(logsDirectory: paths.logsDirectory)
            self.chatTranscriptLogStore = ChatTranscriptLogStore(logsDirectory: paths.logsDirectory)
        } catch {
            let fallback = ApplicationSupportPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Roca"))
            self.paths = fallback
            self.settingsStore = JSONSettingsStore.phaseOneDefault(paths: fallback)
            self.kokoroAssetStore = ProviderAssetStore(rootDirectory: fallback.modelsDirectory)
            self.moonshineModelStore = MoonshineModelStore(rootDirectory: fallback.modelsDirectory)
            self.assistantMetricsLogStore = AssistantTurnMetricsLogStore(logsDirectory: fallback.logsDirectory)
            self.chatTranscriptLogStore = ChatTranscriptLogStore(logsDirectory: fallback.logsDirectory)
            self.statusText = "Storage unavailable."
        }

        self.registry = InMemoryProviderRegistry(descriptors: BuiltInProviderDescriptors.phaseTwo())
    }

    func bootstrap() async {
        do {
            try paths.createDirectories()
            settings = try await settingsStore.load()
            currentSpeechSettings.update(settings)
            currentDictationSettings.update(settings)
            updatePublishedSettings()
            try await settingsStore.save(settings)
        } catch {
            statusText = "Settings unavailable."
        }

        configureSpeechPipeline()
        configureDictationPipeline()
        configureAssistantPipeline()

        observeCompanionState()
        observePlaybackState()
        observeDictationState()
        observeAssistantState()
        observeAssistantMessages()
        observeAssistantTurnMetrics()
        refreshSettingsWindowState()
        await refreshKokoroAssetStatus()
        await refreshMoonshineModelStatus()
        await refreshOllamaStatus()
        if statusText == "Starting Roca..." {
            statusText = "Ready"
        }
    }

    func stopSpeech() async {
        await speechOrchestrator?.stopSpeaking()
        statusText = "Stopped"
    }

    func stopSpeechFromMenu() {
        Task {
            await stopSpeech()
        }
    }

    func prepareForTermination() async {
        isTerminating = true
        statusText = "Quitting..."
        dictationTask?.cancel()
        assistantTask?.cancel()
        kokoroInstallTask?.cancel()
        kokoroWarmupTask?.cancel()
        moonshineInstallTask?.cancel()

        if let message = await settingsSaveTask?.value {
            statusText = message
        }

        await speechOrchestrator?.stopSpeaking()
        await dictationOrchestrator?.cancel()
        await assistantSession?.cancel()
    }

    func openSettingsWindowState() {
        refreshSettingsWindowState()
    }

    func setCompanionVisible(_ visible: Bool) {
        guard settings.companionVisible != visible else {
            return
        }
        settings.companionVisible = visible
        updatePublishedSettings()
        persistSettings()
    }

    func showCompanion() {
        setCompanionVisible(true)
    }

    func hideCompanion() {
        setCompanionVisible(false)
    }

    func toggleCompanionVisibility() {
        setCompanionVisible(!settings.companionVisible)
    }

    func setCompanionWarmth(_ warmth: CompanionWarmth) {
        guard settings.companionWarmth != warmth else {
            return
        }
        settings.companionWarmth = warmth
        updatePublishedSettings()
        persistSettings()
    }

    func makeCompanionQuieter() {
        setCompanionWarmth(.quiet)
    }

    func toggleAssistantSpeechMuted() {
        settings.assistantSpeechMuted.toggle()
        updatePublishedSettings()
        persistSettings()
        if settings.assistantSpeechMuted {
            Task {
                await speechOrchestrator?.stopSpeaking()
            }
        }
    }

    func setRawTranscriptLoggingEnabled(_ enabled: Bool) {
        guard settings.rawTranscriptLoggingEnabled != enabled else {
            return
        }
        rawTranscriptLoggingGeneration += 1
        if enabled {
            loggedChatTranscriptMessageIDs.formUnion(chatMessages.map(\.id))
        } else {
            pendingChatTranscriptMessageIDs.removeAll()
        }
        settings.rawTranscriptLoggingEnabled = enabled
        updatePublishedSettings()
        persistSettings()
    }

    func refreshChatTranscriptLogInfo() {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let info = try await chatTranscriptLogStore.fileInfo()
                await MainActor.run {
                    self.applyChatTranscriptLogInfo(info)
                }
            } catch {
                await MainActor.run {
                    self.hasChatTranscriptLog = false
                    self.chatTranscriptLogSummary = error.localizedDescription
                }
            }
        }
    }

    func exportChatTranscriptLog(to destinationURL: URL) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await chatTranscriptLogStore.export(to: destinationURL)
                let info = try await chatTranscriptLogStore.fileInfo()
                await MainActor.run {
                    self.chatTranscriptLogActionStatus = "Exported raw transcript log."
                    self.applyChatTranscriptLogInfo(info)
                }
            } catch {
                await MainActor.run {
                    self.chatTranscriptLogActionStatus = error.localizedDescription
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    func deleteChatTranscriptLog() {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await chatTranscriptLogStore.delete()
                let info = try await chatTranscriptLogStore.fileInfo()
                await MainActor.run {
                    self.pendingChatTranscriptMessageIDs.removeAll()
                    self.chatTranscriptLogActionStatus = "Deleted raw transcript log."
                    self.applyChatTranscriptLogInfo(info)
                }
            } catch {
                await MainActor.run {
                    self.chatTranscriptLogActionStatus = error.localizedDescription
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    func setChatPanelPresenter(_ presenter: @escaping @MainActor () -> Void) {
        chatPanelPresenter = presenter
    }

    func showChatPanel() {
        chatPanelPresenter?()
    }

    func refreshSettingsWindowState() {
        refreshAccessibilityStatus()
        refreshMicrophoneStatus()
        refreshSpeechRecognitionStatus()
        refreshChatTranscriptLogInfo()
        Task {
            await refreshKokoroAssetStatus()
            await loadVoices(for: activeSettingsVoiceProviderID)
            await refreshMoonshineModelStatus()
            await refreshOllamaStatus()
        }
    }

    func setSpeechProviderMode(_ mode: SpeechProviderMode) {
        if mode == .kokoro, !canTurnOnKokoroNative {
            statusText = kokoroUnavailableModeMessage
            updatePublishedSettings()
            return
        }
        settings.selectedTTSProvider = mode.providerID
        currentSpeechSettings.update(settings)
        updatePublishedSettings()
        persistSettings()
        refreshVoicesForCurrentSelection()
    }

    func setSpeechSpeed(_ speed: Double) {
        let clamped = min(2.0, max(0.5, speed))
        settings.speechSpeed = clamped
        currentSpeechSettings.update(settings)
        updatePublishedSettings()
        persistSettings()
    }

    func selectedVoice(for providerID: ProviderID) -> VoiceID? {
        providerVoiceSelections[providerID]
    }

    func setSelectedVoice(_ voiceID: VoiceID?, for providerID: ProviderID) {
        if let voiceID {
            settings.providerVoiceSelections[providerID] = voiceID
        } else {
            settings.providerVoiceSelections.removeValue(forKey: providerID)
        }
        currentSpeechSettings.update(settings)
        updatePublishedSettings()
        persistSettings()
    }

    func refreshVoicesForCurrentSelection() {
        let providerID = activeSettingsVoiceProviderID
        Task {
            await loadVoices(for: providerID)
        }
    }

    func previewSpeechFromSettings() {
        let providerID = previewProviderID
        let voice = settings.providerVoiceSelections[providerID]
        let voiceSelections = settings.providerVoiceSelections
        let speed = settings.speechSpeed
        previewGeneration += 1
        let generation = previewGeneration
        activePreviewPlaybackGeneration = nil
        isPreviewing = true
        previewStatus = "Starting preview"

        Task {
            await speechOrchestrator?.stopSpeaking()
            do {
                try await speechOrchestrator?.speak(
                    SpeechRequest(
                        utteranceID: .make(),
                        text: "Roca voice preview.",
                        providerID: providerID,
                        voice: voice,
                        providerVoiceSelections: voiceSelections,
                        format: providerID == BuiltInProviderIDs.macOSVoice ? .wav16Mono : .wav24Mono,
                        speed: speed,
                        source: .voicePreview,
                        allowFallback: false
                    )
                )
                await MainActor.run {
                    guard self.previewGeneration == generation else {
                        return
                    }
                    self.activePreviewPlaybackGeneration = generation
                    self.previewStatus = "Preview playing"
                }
            } catch {
                await MainActor.run {
                    guard self.previewGeneration == generation else {
                        return
                    }
                    self.previewStatus = error.localizedDescription
                    self.statusText = error.localizedDescription
                    self.isPreviewing = false
                    self.activePreviewPlaybackGeneration = nil
                }
            }
        }
    }

    func refreshAccessibilityStatus() {
        Task {
            let trusted = await permissionsService.isAccessibilityTrusted()
            await MainActor.run {
                self.isAccessibilityTrusted = trusted
            }
        }
    }

    func requestAccessibilityPermission() {
        Task {
            let trusted = await permissionsService.requestAccessibilityIfNeeded()
            await MainActor.run {
                self.isAccessibilityTrusted = trusted
                self.statusText = trusted ? "Accessibility ready" : "Accessibility permission needed"
            }
        }
    }

    func refreshMicrophoneStatus() {
        Task {
            let status = await permissionsService.microphonePermissionStatus()
            await MainActor.run {
                self.applyMicrophoneStatus(status)
            }
        }
    }

    func requestMicrophonePermission() {
        Task {
            let allowed = await permissionsService.requestMicrophoneIfNeeded()
            let status = await permissionsService.microphonePermissionStatus()
            await MainActor.run {
                self.applyMicrophoneStatus(status)
                self.statusText = allowed ? "Microphone ready" : "Microphone permission needed"
            }
        }
    }

    func refreshSpeechRecognitionStatus() {
        Task {
            let status = await permissionsService.speechRecognitionPermissionStatus()
            await MainActor.run {
                self.applySpeechRecognitionStatus(status)
            }
        }
    }

    func requestSpeechRecognitionPermission() {
        Task {
            let allowed = await permissionsService.requestSpeechRecognitionIfNeeded()
            let status = await permissionsService.speechRecognitionPermissionStatus()
            await MainActor.run {
                self.applySpeechRecognitionStatus(status)
                self.statusText = allowed ? "Speech recognition ready" : "Speech recognition permission needed"
            }
        }
    }

    func setSTTProviderMode(_ mode: STTProviderMode) {
        if mode == .moonshine, !canUseMoonshine {
            statusText = "Download Moonshine before turning it on."
            updatePublishedSettings()
            return
        }
        settings.selectedSTTProvider = mode.providerID
        currentDictationSettings.update(settings)
        updatePublishedSettings()
        persistSettings()
    }

    func toggleDictation() {
        if isDictationActive {
            stopDictation()
        } else if dictationTask != nil {
            cancelStartingDictation()
        } else {
            startDictation()
        }
    }

    func toggleVoiceInput() {
        toggleAssistant()
    }

    func toggleAssistant() {
        if isAssistantActive || isAssistantTurnActive {
            stopAssistant()
        } else if assistantTask != nil {
            cancelAssistant()
        } else {
            startAssistant()
        }
    }

    func startAssistant() {
        guard assistantTask == nil else {
            return
        }
        showChatPanel()
        guard let brainSelection = assistantBrainSelection else {
            assistantStatus = "Assistant needs a brain"
            statusText = "Choose an assistant brain in Settings"
            Task {
                let message = "Choose an assistant brain in Settings before talking to Roca."
                await assistantSession?.postStatus(message, status: .failed)
                await speakAssistantRecovery(message)
            }
            return
        }
        let roleSelections = assistantBrainRoleSelections

        assistantStatus = "Checking assistant"
        statusText = "Checking assistant..."
        let dictationConfiguration = settings.dictationConfiguration
        let speechConfiguration = settings.speechConfiguration
        let outputMode = assistantOutputMode
        assistantTask = Task { [weak self] in
            guard let self else {
                return
            }
            if let recoveryMessage = await self.assistantUnavailableMessageIfNeeded(
                for: brainSelection,
                roleSelections: roleSelections
            ) {
                await self.assistantSession?.postStatus(recoveryMessage, status: .failed)
                await self.speakAssistantRecovery(recoveryMessage)
                await MainActor.run {
                    self.isAssistantActive = false
                    self.isAssistantTurnActive = false
                    self.assistantTask = nil
                }
                return
            }

            await MainActor.run {
                self.assistantStatus = "Starting"
                self.statusText = "Starting assistant..."
            }

            do {
                try await self.assistantSession?.startVoice(
                    AssistantSessionTurnRequest(
                        turnID: BrainRequestID(rawValue: UUID().uuidString),
                        transcriptionID: TranscriptionID(rawValue: UUID().uuidString),
                        inputMode: .voice,
                        outputMode: outputMode,
                        sttProviderID: dictationConfiguration.providerID,
                        brainSelection: brainSelection,
                        roleSelections: roleSelections,
                        locale: dictationConfiguration.locale,
                        mode: dictationConfiguration.mode,
                        speechConfiguration: speechConfiguration
                    )
                )
            } catch {
                await MainActor.run {
                    self.assistantStatus = error.localizedDescription
                    self.statusText = error.localizedDescription
                    self.isAssistantActive = false
                    self.assistantTask = nil
                }
            }
        }
    }

    func sendChatMessage(_ text: String) {
        guard assistantTask == nil else {
            Task {
                await assistantSession?.postStatus("Finish the current turn first.", status: .failed)
            }
            return
        }
        showChatPanel()
        guard let brainSelection = assistantBrainSelection else {
            assistantStatus = "Assistant needs a brain"
            statusText = "Choose an assistant brain in Settings"
            Task {
                let message = "Choose an assistant brain in Settings before chatting with Roca."
                await assistantSession?.postStatus(message, status: .failed)
                await speakAssistantRecovery(message)
            }
            return
        }
        let roleSelections = assistantBrainRoleSelections

        assistantStatus = "Thinking"
        statusText = "Thinking..."
        let dictationConfiguration = settings.dictationConfiguration
        let speechConfiguration = settings.speechConfiguration
        let outputMode = assistantOutputMode
        assistantTask = Task { [weak self] in
            guard let self else {
                return
            }
            if let recoveryMessage = await self.assistantUnavailableMessageIfNeeded(
                for: brainSelection,
                roleSelections: roleSelections
            ) {
                await self.assistantSession?.postStatus(recoveryMessage, status: .failed)
                await self.speakAssistantRecovery(recoveryMessage)
                await MainActor.run {
                    self.isAssistantTurnActive = false
                    self.assistantTask = nil
                }
                return
            }

            await self.assistantSession?.submitText(
                text,
                request: AssistantSessionTurnRequest(
                    turnID: BrainRequestID(rawValue: UUID().uuidString),
                    transcriptionID: TranscriptionID(rawValue: UUID().uuidString),
                    inputMode: .typed,
                    outputMode: outputMode,
                    sttProviderID: dictationConfiguration.providerID,
                    brainSelection: brainSelection,
                    roleSelections: roleSelections,
                    locale: dictationConfiguration.locale,
                    mode: dictationConfiguration.mode,
                    speechConfiguration: speechConfiguration
                )
            )
            await MainActor.run {
                self.assistantTask = nil
            }
        }
    }

    private var assistantOutputMode: AssistantOutputMode {
        settings.assistantSpeechMuted ? .textOnly : .speakAll
    }

    func clearChatConversation() {
        Task {
            await assistantSession?.clearConversation()
        }
    }

    func stopAssistant() {
        guard assistantTask != nil || isAssistantActive || isAssistantTurnActive else {
            return
        }
        statusText = "Stopping assistant..."
        Task { [weak self] in
            await self?.assistantSession?.stopVoice()
            await MainActor.run {
                self?.assistantTask = nil
            }
        }
    }

    func cancelAssistant() {
        assistantTask?.cancel()
        statusText = "Cancelling assistant..."
        Task { [weak self] in
            await self?.assistantSession?.cancel()
            await MainActor.run {
                self?.assistantTask = nil
                self?.isAssistantActive = false
                self?.isAssistantTurnActive = false
                self?.assistantStatus = "Ready"
                self?.statusText = "Ready"
            }
        }
    }

    func startDictation() {
        guard dictationTask == nil else {
            return
        }

        dictationStatus = "Starting"
        statusText = "Starting dictation..."
        let configuration = settings.dictationConfiguration
        dictationTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.dictationOrchestrator?.start(
                    DictationRequest(
                        transcriptionID: TranscriptionID(rawValue: UUID().uuidString),
                        providerID: configuration.providerID,
                        locale: configuration.locale,
                        mode: configuration.mode,
                        intent: .dictation,
                        insertionTarget: .focusedApp
                    )
                )
                await self.refreshMoonshineModelStatus()
            } catch {
                await MainActor.run {
                    self.dictationStatus = error.localizedDescription
                    self.statusText = error.localizedDescription
                    self.isDictationActive = false
                    self.dictationTask = nil
                }
            }
        }
    }

    func stopDictation() {
        guard dictationTask != nil || isDictationActive else {
            return
        }
        statusText = "Stopping dictation..."
        Task { [weak self] in
            await self?.dictationOrchestrator?.stop()
            await MainActor.run {
                self?.dictationTask = nil
            }
        }
    }

    private func cancelStartingDictation() {
        dictationTask?.cancel()
        statusText = "Cancelling dictation..."
        Task { [weak self] in
            await self?.dictationOrchestrator?.cancel()
            await MainActor.run {
                self?.dictationTask = nil
                self?.isDictationActive = false
                self?.dictationStatus = "Ready"
                self?.statusText = "Ready"
            }
        }
    }

    func installKokoroFromSettings() {
        guard kokoroInstallTask == nil else {
            return
        }

        isInstallingKokoroModel = true
        kokoroDownloadProgress = nil
        kokoroNativeStatus = "Downloading Kokoro..."
        statusText = "Downloading Kokoro..."
        let progressHandler = kokoroProgressHandler()
        kokoroInstallTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let manifest = try KokoroManagedAssets.bundledManifest()
                let installation = try await self.kokoroAssetStore.prepareAssets(for: manifest, progress: progressHandler)
                await MainActor.run {
                    self.applyKokoroAssetInstallation(
                        installation,
                        manifest: manifest,
                        verifiedVoiceGroupIDs: Set(manifest.defaultVoiceGroupIDs)
                    )
                    self.isInstallingKokoroModel = false
                    self.kokoroDownloadProgress = nil
                    self.kokoroInstallTask = nil
                    self.statusText = "Kokoro downloaded"
                }
            } catch {
                await MainActor.run {
                    self.finishKokoroInstallFailure(error)
                }
            }
        }
    }

    func installKokoroVoiceGroupFromSettings(_ groupID: String) {
        guard kokoroInstallTask == nil, !installingKokoroVoiceGroupIDs.contains(groupID) else {
            return
        }

        installingKokoroVoiceGroupIDs.insert(groupID)
        kokoroDownloadProgress = nil
        updateKokoroVoiceGroupInstallingState()
        let progressHandler = kokoroProgressHandler()
        kokoroInstallTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let manifest = try KokoroManagedAssets.bundledManifest()
                let groupName = manifest.voiceGroup(id: groupID)?.displayName ?? "Voice pack"
                await MainActor.run {
                    self.statusText = "Downloading \(groupName)..."
                }
                let requestedGroupIDs = Set(manifest.defaultVoiceGroupIDs + [groupID])
                let installation = try await self.kokoroAssetStore.prepareAssets(
                    for: manifest,
                    voiceGroupIDs: requestedGroupIDs,
                    progress: progressHandler
                )
                await MainActor.run {
                    self.installingKokoroVoiceGroupIDs.remove(groupID)
                    self.applyKokoroAssetInstallation(
                        installation,
                        manifest: manifest,
                        verifiedVoiceGroupIDs: requestedGroupIDs
                    )
                    self.kokoroDownloadProgress = nil
                    self.kokoroInstallTask = nil
                    self.statusText = "\(groupName) downloaded"
                }
            } catch {
                await MainActor.run {
                    self.installingKokoroVoiceGroupIDs.remove(groupID)
                    self.updateKokoroVoiceGroupInstallingState()
                    self.finishKokoroInstallFailure(error)
                }
            }
        }
    }

    func cancelKokoroDownloadFromSettings() {
        guard kokoroInstallTask != nil else {
            return
        }
        statusText = "Cancelling Kokoro download..."
        kokoroInstallTask?.cancel()
    }

    func installMoonshineModelFromSettings() {
        guard moonshineInstallTask == nil else {
            return
        }

        isInstallingMoonshineModel = true
        moonshineDownloadProgress = nil
        moonshineModelStatus = "Installing model..."
        let progressHandler = moonshineProgressHandler()
        moonshineInstallTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let model = try await self.moonshineModelStore.prepareModel(progress: progressHandler)
                let record = await self.moonshineModelStore.record(for: model)
                await MainActor.run {
                    self.settings.sttModelRecords[BuiltInProviderIDs.moonshineSTT] = record
                    self.currentDictationSettings.update(self.settings)
                    self.updatePublishedSettings()
                    self.persistSettings()
                    self.isMoonshineModelInstalled = true
                    self.isInstallingMoonshineModel = false
                    self.moonshineDownloadProgress = nil
                    self.moonshineModelStatus = "Moonshine downloaded"
                    self.moonshineInstallTask = nil
                    self.statusText = "Moonshine downloaded"
                }
            } catch {
                await MainActor.run {
                    self.finishMoonshineInstallFailure(error)
                }
            }
        }
    }

    func cancelMoonshineDownloadFromSettings() {
        guard moonshineInstallTask != nil else {
            return
        }
        statusText = "Cancelling Moonshine download..."
        moonshineInstallTask?.cancel()
    }

    func retryRecoverableDictation() {
        Task { [weak self] in
            do {
                try await self?.dictationOrchestrator?.retryRecoverableTranscript()
                await self?.refreshRecoverableDictationState()
            } catch {
                await MainActor.run {
                    self?.dictationStatus = error.localizedDescription
                    self?.statusText = error.localizedDescription
                }
            }
        }
    }

    func copyRecoverableDictation() {
        Task { [weak self] in
            guard let transcript = await self?.dictationOrchestrator?.recoverableTranscript() else {
                return
            }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript.text, forType: .string)
                self?.statusText = "Recovered dictation copied"
            }
        }
    }

    func discardRecoverableDictation() {
        Task { [weak self] in
            await self?.dictationOrchestrator?.discardRecoverableTranscript()
            await self?.refreshRecoverableDictationState()
        }
    }

    var activeSettingsVoiceProviderID: ProviderID {
        switch speechProviderMode {
        case .automatic:
            isKokoroNativeReady ? BuiltInProviderIDs.kokoroNative : BuiltInProviderIDs.macOSVoice
        case .kokoro:
            canTurnOnKokoroNative ? BuiltInProviderIDs.kokoroNative : BuiltInProviderIDs.macOSVoice
        case .macOSVoice:
            BuiltInProviderIDs.macOSVoice
        }
    }

    var activeSettingsVoiceProviderName: String {
        providerDisplayName(activeSettingsVoiceProviderID)
    }

    var voiceProviderMenuDescription: String {
        switch speechProviderMode {
        case .automatic:
            "\(activeSettingsVoiceProviderName) (Automatic)"
        case .kokoro, .macOSVoice:
            activeSettingsVoiceProviderName
        }
    }

    var logsDirectoryPath: String {
        paths.logsDirectory.path
    }

    var assistantMetricsLogPath: String {
        assistantMetricsLogStore.fileURL.path
    }

    var chatTranscriptLogPath: String {
        chatTranscriptLogStore.fileURL.path
    }

    var modelsDirectoryPath: String {
        paths.modelsDirectory.path
    }

    private func applyChatTranscriptLogInfo(_ info: ChatTranscriptLogFileInfo) {
        hasChatTranscriptLog = info.exists
        guard info.exists else {
            chatTranscriptLogSummary = "No raw transcript log yet"
            return
        }

        let rowLabel = info.rowCount == 1 ? "1 row" : "\(info.rowCount) rows"
        let byteText = Self.fileByteFormatter.string(fromByteCount: info.byteCount)
        if let modifiedAt = info.modifiedAt {
            let modifiedText = DateFormatter.localizedString(
                from: modifiedAt,
                dateStyle: .medium,
                timeStyle: .short
            )
            chatTranscriptLogSummary = "\(rowLabel), \(byteText), updated \(modifiedText)"
        } else {
            chatTranscriptLogSummary = "\(rowLabel), \(byteText)"
        }
    }

    private static var fileByteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        return formatter
    }

    var hotkeyDescription: String {
        hotkeyDescription(for: settings.hotkey)
    }

    var activeSTTProviderName: String {
        switch sttProviderMode {
        case .automatic:
            canUseMoonshine ? "Apple Speech, Moonshine fallback" : "Apple Speech"
        case .appleSpeech:
            "Apple Speech"
        case .moonshine:
            "Moonshine"
        case .whisperKit:
            "WhisperKit"
        }
    }

    var dictationModeDescription: String {
        switch settings.dictationMode {
        case .toggleToTalk:
            "Toggle-to-talk"
        case .pushToTalk:
            "Push-to-talk"
        }
    }

    var dictationLanguageDescription: String {
        "English (US)"
    }

    var voiceInputMenuActionTitle: String {
        if isAssistantActive || isAssistantTurnActive {
            return "Stop Roca"
        }
        if assistantTask != nil {
            return "Cancel Roca"
        }
        return "Talk to Roca"
    }

    var assistantHotkeyDescription: String {
        hotkeyDescription
    }

    var hasConfiguredAssistantBrain: Bool {
        assistantBrainSelection?.modelID?.isEmpty == false
    }

    var assistantBrainName: String {
        assistantBrainSelection?.displayName ?? assistantBrainSelection?.modelID ?? "Not configured"
    }

    var shouldShowAssistantOnboarding: Bool {
        !settings.assistantOnboardingCompleted
    }

    var recommendedOllamaModelID: String? {
        OllamaModelRecommendationPolicy.recommendedModel(from: ollamaModels)?.id
    }

    var ollamaModelsForPicker: [OllamaModel] {
        OllamaModelRecommendationPolicy.selectableModels(ollamaModels)
    }

    func ollamaModelsForPicker(for role: BrainRole) -> [OllamaModel] {
        OllamaModelRecommendationPolicy.selectableModels(ollamaModels, role: role)
    }

    func ollamaModelPickerSystemImage(for model: OllamaModel, role: BrainRole? = nil) -> String {
        let recommendation = OllamaModelRecommendationPolicy.recommendation(for: model.id, role: role)
        switch recommendation.status {
        case .preferred:
            return "star.fill"
        case .acceptable:
            return "checkmark.circle"
        case .untested:
            return "questionmark.circle"
        case .discouraged:
            return "exclamationmark.triangle"
        case .unsupported:
            return "xmark.octagon"
        }
    }

    private var assistantBrainSelection: BrainProviderSelection? {
        assistantBrainSelection(for: .companionRouter)
    }

    private var assistantBrainRoleSelections: [BrainRole: BrainProviderSelection] {
        var selections: [BrainRole: BrainProviderSelection] = [:]
        for role in [BrainRole.companionRouter, .generalChat] {
            if let selection = assistantBrainSelection(for: role) {
                selections[role] = selection
            }
        }
        return selections
    }

    private func assistantBrainSelection(for role: BrainRole) -> BrainProviderSelection? {
        guard let selection = settings.brainRoles[role] else {
            return nil
        }
        return isUsableAssistantBrainSelection(selection, role: role) ? selection : nil
    }

    private func isUsableAssistantBrainSelection(_ selection: BrainProviderSelection, role: BrainRole) -> Bool {
        guard let modelID = selection.modelID, !modelID.isEmpty else {
            return false
        }
        guard selection.providerID == BuiltInProviderIDs.ollamaBrain else {
            return true
        }
        return OllamaModelRecommendationPolicy.isSelectable(modelID, role: role)
    }

    private func assistantUnavailableMessageIfNeeded(
        for selection: BrainProviderSelection,
        roleSelections: [BrainRole: BrainProviderSelection]
    ) async -> String? {
        var selectionsToCheck = Array(roleSelections.values)
        if selectionsToCheck.isEmpty {
            selectionsToCheck = [selection]
        } else if !selectionsToCheck.contains(selection) {
            selectionsToCheck.append(selection)
        }
        let ollamaModelIDs = Set(
            selectionsToCheck
                .filter { $0.providerID == BuiltInProviderIDs.ollamaBrain }
                .compactMap { $0.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        guard !ollamaModelIDs.isEmpty else {
            return nil
        }

        let state = await OllamaBrainProvider.discover()
        applyOllamaDiscoveryState(state)

        switch state {
        case .ready(let models):
            let availableModelIDs = Set(models.map(\.id))
            guard ollamaModelIDs.isSubset(of: availableModelIDs) else {
                return "Ollama is running, but a selected assistant model isn't available. Choose a model in Assistant settings."
            }
            return nil
        case .runningWithoutModels:
            return "Ollama is running, but no models are available. Install a model in Ollama or choose a different brain in Settings."
        case .installedNotRunning:
            return "Ollama isn't running. Start Ollama, then try talking to me again."
        case .unavailable:
            return "Assistant mode needs a local LLM. Install Ollama or set up a brain in Assistant settings."
        }
    }

    private func speakAssistantRecovery(_ message: String) async {
        assistantStatus = message
        statusText = message
        guard !settings.assistantSpeechMuted else {
            return
        }
        let speechConfiguration = settings.speechConfiguration
        do {
            try await speechOrchestrator?.speak(
                SpeechRequest(
                    utteranceID: .make(),
                    text: message,
                    providerID: speechConfiguration.providerID,
                    voice: nil,
                    providerVoiceSelections: speechConfiguration.providerVoiceSelections,
                    format: .wav24Mono,
                    speed: speechConfiguration.speed,
                    source: .assistantResponse,
                    allowFallback: speechConfiguration.allowFallback
                )
            )
        } catch {
            statusText = message
        }
    }

    func refreshOllamaFromSettings() {
        Task {
            await refreshOllamaStatus()
        }
    }

    func setAssistantOllamaModel(_ modelID: String?) {
        guard let modelID, !modelID.isEmpty else {
            settings.brainRoles.removeValue(forKey: .companionRouter)
            settings.brainRoles.removeValue(forKey: .generalChat)
            updatePublishedAssistantBrainSelection()
            assistantStatus = "Not configured"
            persistSettings()
            return
        }
        guard OllamaModelRecommendationPolicy.isSelectable(modelID) else {
            statusText = "That model is not compatible with Roca assistant chat."
            return
        }

        let model = ollamaModels.first { $0.id == modelID }
        let selection = BrainProviderSelection(
            providerID: BuiltInProviderIDs.ollamaBrain,
            modelID: modelID,
            displayName: model?.displayName ?? modelID
        )
        settings.brainRoles[.companionRouter] = selection
        settings.brainRoles[.generalChat] = selection
        updatePublishedAssistantBrainSelection()
        assistantStatus = "Ready with \(selection.displayName ?? modelID)"
        statusText = "Assistant ready"
        persistSettings()
    }

    func setAssistantOllamaModel(_ modelID: String?, for role: BrainRole) {
        guard role == .companionRouter || role == .generalChat else {
            return
        }
        guard let modelID, !modelID.isEmpty else {
            if role == .companionRouter {
                setAssistantOllamaModel(nil)
            } else {
                settings.brainRoles.removeValue(forKey: role)
                updatePublishedAssistantBrainSelection()
                persistSettings()
            }
            return
        }
        guard OllamaModelRecommendationPolicy.isSelectable(modelID, role: role) else {
            statusText = "That model is not compatible with Roca assistant chat."
            return
        }

        let model = ollamaModels.first { $0.id == modelID }
        let selection = BrainProviderSelection(
            providerID: BuiltInProviderIDs.ollamaBrain,
            modelID: modelID,
            displayName: model?.displayName ?? modelID
        )
        settings.brainRoles[role] = selection
        updatePublishedAssistantBrainSelection()
        assistantStatus = "Ready with \(assistantBrainName)"
        statusText = "Assistant ready"
        persistSettings()
    }

    func startOllamaFromSettings() {
        guard let ollamaInstalledAppURL else {
            statusText = "Ollama app not found"
            return
        }
        NSWorkspace.shared.openApplication(
            at: ollamaInstalledAppURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.statusText = error.localizedDescription
                } else {
                    self?.statusText = "Starting Ollama..."
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await self?.refreshOllamaStatus()
                    }
                }
            }
        }
    }

    func skipAssistantOnboarding() {
        settings.assistantOnboardingCompleted = true
        persistSettings()
    }

    func finishAssistantOnboarding() {
        settings.assistantOnboardingCompleted = true
        persistSettings()
    }

    private func hotkeyDescription(for hotkey: HotkeyDefinition) -> String {
        let modifiers = hotkey.modifiers.map { modifier in
            switch modifier {
            case "command":
                "Command"
            case "option":
                "Option"
            case "control":
                "Control"
            case "shift":
                "Shift"
            default:
                modifier.capitalized
            }
        }
        return (modifiers + [hotkey.key.uppercased()]).joined(separator: "+")
    }

    var macOSVoiceStatus: String {
        voiceLoadMessages[BuiltInProviderIDs.macOSVoice] ?? "Local"
    }

    var hasMissingDownloadableSpeechProviders: Bool {
        !isKokoroModelInstalled
    }

    var availableSTTProviderModes: [STTProviderMode] {
        var modes: [STTProviderMode] = [.automatic, .appleSpeech]
        if canUseMoonshine {
            modes.append(.moonshine)
        }
        return modes
    }

    var canUseMoonshine: Bool {
        isMoonshineModelInstalled
    }

    var availableSpeechProviderModes: [SpeechProviderMode] {
        if canTurnOnKokoroNative {
            return [.automatic, .kokoro, .macOSVoice]
        }
        return [.automatic, .macOSVoice]
    }

    var isKokoroNativeReady: Bool {
        isKokoroModelInstalled && isKokoroNativeEngineAvailable
    }

    var canTurnOnKokoroNative: Bool {
        isKokoroNativeReady
    }

    func providerDisplayName(_ id: ProviderID) -> String {
        switch id {
        case BuiltInProviderIDs.kokoroNative:
            "Kokoro"
        case BuiltInProviderIDs.macOSVoice:
            "macOS Voices"
        case BuiltInProviderIDs.appleSpeechSTT:
            "Apple Speech"
        case BuiltInProviderIDs.moonshineSTT:
            "Moonshine"
        case BuiltInProviderIDs.whisperKitSTT:
            "WhisperKit"
        case BuiltInProviderIDs.ollamaBrain:
            "Ollama"
        default:
            id.rawValue
        }
    }

    private var previewProviderID: ProviderID {
        if speechProviderMode == .kokoro, !canTurnOnKokoroNative {
            return activeSettingsVoiceProviderID
        }
        if let explicit = speechProviderMode.providerID {
            return explicit
        }
        return activeSettingsVoiceProviderID
    }

    private var isKokoroNativeEngineAvailable: Bool {
        true
    }

    private var kokoroUnavailableModeMessage: String {
        if isKokoroModelInstalled {
            return "Kokoro speech is not available yet."
        }
        return "Download Kokoro before turning it on."
    }

    private func kokoroProgressHandler() -> @Sendable (ManagedDownloadProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard self?.kokoroInstallTask != nil else {
                    return
                }
                self?.kokoroDownloadProgress = progress
            }
        }
    }

    private func moonshineProgressHandler() -> @Sendable (ManagedDownloadProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard self?.moonshineInstallTask != nil else {
                    return
                }
                self?.moonshineDownloadProgress = progress
            }
        }
    }

    private func finishKokoroInstallFailure(_ error: Error) {
        isInstallingKokoroModel = false
        kokoroDownloadProgress = nil
        kokoroInstallTask = nil
        if isCancellation(error) {
            kokoroNativeStatus = "Download cancelled"
            statusText = "Kokoro download cancelled"
        } else {
            kokoroNativeStatus = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    private func finishMoonshineInstallFailure(_ error: Error) {
        isInstallingMoonshineModel = false
        isMoonshineModelInstalled = false
        moonshineDownloadProgress = nil
        moonshineInstallTask = nil
        if isCancellation(error) {
            moonshineModelStatus = "Download cancelled"
            statusText = "Moonshine download cancelled"
        } else {
            moonshineModelStatus = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    private func observeCompanionState() {
        companionTask?.cancel()
        companionTask = Task { [weak self, companionState] in
            for await event in companionState.events {
                await MainActor.run {
                    self?.applyCompanionEvent(event)
                }
            }
        }
    }

    private func applyCompanionEvent(_ event: CompanionStateEvent) {
        companionActivity = event.activity
        companionMessage = event.sensitivity == .publicStatus
            ? (event.message ?? event.activity.safeCompanionMessage)
            : event.activity.safeCompanionMessage

        if event.sensitivity == .publicStatus, let message = event.message {
            statusText = message
        }
    }

    private func configureSpeechPipeline() {
        let kokoroProvider = KokoroTTSProvider(assetStore: kokoroAssetStore)
        let macProvider = MacOSVoiceProvider()
        ttsProviders = [
            kokoroProvider.id: kokoroProvider,
            macProvider.id: macProvider
        ]

        let resolver = DefaultProviderResolver(
            registry: registry,
            ttsProviders: [kokoroProvider, macProvider],
            selectedTTSProvider: { [currentSpeechSettings] in
                currentSpeechSettings.selectedTTSProvider()
            },
            ttsFallbackOrder: [
                BuiltInProviderIDs.kokoroNative,
                BuiltInProviderIDs.macOSVoice
            ]
        )
        let speechOrchestrator = DefaultSpeechOrchestrator(
            resolver: resolver,
            playback: playback,
            companionState: companionState
        )
        self.speechOrchestrator = speechOrchestrator
        self.readSelectionCommand = ReadSelectionCommand(
            selectionReader: selectionReader,
            speechOrchestrator: speechOrchestrator,
            speechConfiguration: { [currentSpeechSettings] in
                currentSpeechSettings.speechConfiguration()
            }
        )
    }

    private func configureDictationPipeline() {
        let appleSpeechProvider = AppleSpeechSTTProvider()
        let moonshineProvider = MoonshineSTTProvider(modelStore: moonshineModelStore)
        sttProviders = [
            appleSpeechProvider.id: appleSpeechProvider,
            moonshineProvider.id: moonshineProvider
        ]

        let resolver = DefaultProviderResolver(
            registry: registry,
            ttsProviders: Array(ttsProviders.values),
            sttProviders: [appleSpeechProvider, moonshineProvider],
            selectedTTSProvider: { [currentSpeechSettings] in
                currentSpeechSettings.selectedTTSProvider()
            },
            selectedSTTProvider: { [currentDictationSettings] in
                currentDictationSettings.selectedSTTProvider()
            },
            ttsFallbackOrder: [
                BuiltInProviderIDs.kokoroNative,
                BuiltInProviderIDs.macOSVoice
            ],
            sttFallbackOrder: [
                BuiltInProviderIDs.appleSpeechSTT,
                BuiltInProviderIDs.moonshineSTT
            ]
        )

        dictationOrchestrator = DefaultDictationOrchestrator(
            resolver: resolver,
            audioInput: DefaultAudioInputSession(permissions: permissionsService),
            inserter: DefaultFocusedTextInserter(permissions: permissionsService),
            permissions: permissionsService,
            stopSpeech: { [weak self] in
                await self?.speechOrchestrator?.stopSpeaking()
            },
            companionState: companionState
        )
    }

    private func configureAssistantPipeline() {
        let ollamaProvider = OllamaBrainProvider()
        let resolver = DefaultProviderResolver(
            registry: registry,
            ttsProviders: Array(ttsProviders.values),
            sttProviders: Array(sttProviders.values),
            brainProviders: [ollamaProvider],
            selectedTTSProvider: { [currentSpeechSettings] in
                currentSpeechSettings.selectedTTSProvider()
            },
            selectedSTTProvider: { [currentDictationSettings] in
                currentDictationSettings.selectedSTTProvider()
            },
            ttsFallbackOrder: [
                BuiltInProviderIDs.kokoroNative,
                BuiltInProviderIDs.macOSVoice
            ],
            sttFallbackOrder: [
                BuiltInProviderIDs.appleSpeechSTT,
                BuiltInProviderIDs.moonshineSTT
            ]
        )

        assistantSession = DefaultAssistantSessionOrchestrator(
            resolver: resolver,
            audioInput: DefaultAudioInputSession(permissions: permissionsService),
            inserter: DefaultFocusedTextInserter(permissions: permissionsService),
            permissions: permissionsService,
            speechOrchestrator: speechOrchestrator ?? DefaultSpeechOrchestrator(
                resolver: resolver,
                playback: playback,
                companionState: companionState
            ),
            readSelectionCommand: readSelectionCommand,
            companionState: companionState,
            stopSpeech: { [weak self] in
                await self?.speechOrchestrator?.stopSpeaking()
            }
        )
    }

    private func loadVoices(for providerID: ProviderID) async {
        if providerID == BuiltInProviderIDs.kokoroNative {
            await refreshKokoroAssetStatus()
            return
        }

        guard let provider = ttsProviders[providerID] else {
            return
        }

        let generation = (voiceLoadGenerations[providerID] ?? 0) + 1
        voiceLoadGenerations[providerID] = generation
        loadingVoiceProviderIDs.insert(providerID)
        voiceLoadMessages[providerID] = "Loading voices"
        defer {
            if voiceLoadGenerations[providerID] == generation {
                loadingVoiceProviderIDs.remove(providerID)
            }
        }

        do {
            let voices = try await provider.listVoices()
            guard voiceLoadGenerations[providerID] == generation else {
                return
            }
            ttsVoices[providerID] = voices
            voiceLoadMessages[providerID] = voices.isEmpty ? "No voices reported" : "\(voices.count) voices"
        } catch {
            guard voiceLoadGenerations[providerID] == generation else {
                return
            }
            ttsVoices[providerID] = []
            voiceLoadMessages[providerID] = error.localizedDescription
        }
    }

    private func updatePublishedSettings() {
        let storedSpeechProviderMode = SpeechProviderMode(providerID: settings.selectedTTSProvider)
        speechProviderMode = normalizedSpeechProviderMode(storedSpeechProviderMode)
        sttProviderMode = normalizedSTTProviderMode(STTProviderMode(providerID: settings.selectedSTTProvider))
        speechSpeed = settings.speechSpeed
        providerVoiceSelections = settings.providerVoiceSelections
        updatePublishedAssistantBrainSelection()
        companionVisible = settings.companionVisible
        companionWarmth = settings.companionWarmth
        assistantSpeechMuted = settings.assistantSpeechMuted
        rawTranscriptLoggingEnabled = settings.rawTranscriptLoggingEnabled
    }

    private func updatePublishedAssistantBrainSelection() {
        selectedCompanionRouterOllamaModelID = assistantBrainSelection(for: .companionRouter)?.modelID
        selectedGeneralChatOllamaModelID = assistantBrainSelection(for: .generalChat)?.modelID
        selectedOllamaModelID = selectedCompanionRouterOllamaModelID
    }

    private func normalizedSpeechProviderMode(_ mode: SpeechProviderMode) -> SpeechProviderMode {
        if mode == .kokoro, !canTurnOnKokoroNative {
            return .automatic
        }
        return mode
    }

    private func normalizedSTTProviderMode(_ mode: STTProviderMode) -> STTProviderMode {
        if mode == .moonshine, !canUseMoonshine {
            return .automatic
        }
        return mode
    }

    private func refreshKokoroAssetStatus() async {
        do {
            let manifest = try KokoroManagedAssets.bundledManifest()
            let status = await kokoroAssetStore.status(for: manifest)
            await MainActor.run {
                switch status {
                case .missing:
                    self.isKokoroModelInstalled = false
                    self.kokoroNativeStatus = "Not downloaded"
                    self.kokoroVoiceGroups = self.kokoroVoiceGroupStates(for: manifest, installedGroupIDs: [])
                    self.ttsVoices[BuiltInProviderIDs.kokoroNative] = []
                    self.voiceLoadMessages[BuiltInProviderIDs.kokoroNative] = "Download Kokoro to install voices"
                    self.reconcileUnavailableKokoroSelection()
                case .installed(let installation):
                    self.applyKokoroAssetInstallation(
                        installation,
                        manifest: manifest,
                        verifiedVoiceGroupIDs: Set(manifest.defaultVoiceGroupIDs)
                    )
                case .invalid(let message):
                    self.isKokoroModelInstalled = false
                    self.kokoroNativeStatus = message
                    self.kokoroVoiceGroups = self.kokoroVoiceGroupStates(for: manifest, installedGroupIDs: [])
                    self.ttsVoices[BuiltInProviderIDs.kokoroNative] = []
                    self.voiceLoadMessages[BuiltInProviderIDs.kokoroNative] = message
                    self.reconcileUnavailableKokoroSelection()
                }
            }
        } catch {
            await MainActor.run {
                self.isKokoroModelInstalled = false
                self.kokoroNativeStatus = error.localizedDescription
                self.ttsVoices[BuiltInProviderIDs.kokoroNative] = []
                self.voiceLoadMessages[BuiltInProviderIDs.kokoroNative] = error.localizedDescription
                self.reconcileUnavailableKokoroSelection()
            }
        }
    }

    private func applyKokoroAssetInstallation(
        _ installation: ProviderAssetInstallation,
        manifest: ProviderAssetManifest,
        verifiedVoiceGroupIDs: Set<String>
    ) {
        isKokoroModelInstalled = true
        let groupCount = installation.installedVoiceGroupIDs.count
        let groupText = groupCount == 1 ? "1 voice group" : "\(groupCount) voice groups"
        if isKokoroNativeEngineAvailable {
            kokoroNativeStatus = "Downloaded (\(groupText))"
        } else {
            kokoroNativeStatus = "Downloaded; speech not available yet"
        }
        let voices = kokoroVoices(from: manifest, installedGroupIDs: Set(installation.installedVoiceGroupIDs))
        ttsVoices[BuiltInProviderIDs.kokoroNative] = voices
        voiceLoadMessages[BuiltInProviderIDs.kokoroNative] = voices.isEmpty ? "No installed voices" : "\(voices.count) voices"
        kokoroVoiceGroups = kokoroVoiceGroupStates(
            for: manifest,
            installedGroupIDs: Set(installation.installedVoiceGroupIDs)
        )
        reconcileUnavailableKokoroSelection()
        warmKokoroInBackground(
            installation: installation,
            manifest: manifest,
            verifiedVoiceGroupIDs: verifiedVoiceGroupIDs
        )
    }

    private func warmKokoroInBackground(
        installation: ProviderAssetInstallation,
        manifest: ProviderAssetManifest,
        verifiedVoiceGroupIDs: Set<String>
    ) {
        guard isKokoroNativeReady, kokoroWarmupTask == nil else {
            return
        }
        guard let provider = ttsProviders[BuiltInProviderIDs.kokoroNative] else {
            return
        }

        kokoroWarmupTask = Task(priority: .utility) { [weak self, provider] in
            do {
                if let kokoroProvider = provider as? KokoroTTSProvider {
                    await kokoroProvider.noteVerifiedInstallation(
                        installation,
                        manifest: manifest,
                        verifiedVoiceGroupIDs: verifiedVoiceGroupIDs
                    )
                }
                try await provider.prepare()
            } catch {
                await MainActor.run {
                    guard let self, !self.isTerminating else {
                        return
                    }
                    self.kokoroNativeStatus = error.localizedDescription
                    self.voiceLoadMessages[BuiltInProviderIDs.kokoroNative] = error.localizedDescription
                }
            }
            await MainActor.run {
                guard let self, !self.isTerminating else {
                    return
                }
                self.kokoroWarmupTask = nil
            }
        }
    }

    private func kokoroVoiceGroupStates(
        for manifest: ProviderAssetManifest,
        installedGroupIDs: Set<String>
    ) -> [KokoroVoiceGroupSettingsState] {
        manifest.voiceGroups.map { group in
            let isInstalled = installedGroupIDs.contains(group.id)
            return KokoroVoiceGroupSettingsState(
                id: group.id,
                displayName: group.displayName,
                locale: group.locale,
                voiceCount: group.voices.count,
                isDefault: group.defaultInstalled,
                isInstalled: isInstalled,
                isInstalling: installingKokoroVoiceGroupIDs.contains(group.id),
                status: isInstalled ? "\(group.voices.count) voices" : "Not downloaded"
            )
        }
    }

    private func updateKokoroVoiceGroupInstallingState() {
        kokoroVoiceGroups = kokoroVoiceGroups.map { state in
            var updated = state
            updated.isInstalling = installingKokoroVoiceGroupIDs.contains(state.id)
            return updated
        }
    }

    private func reconcileUnavailableKokoroSelection() {
        guard settings.selectedTTSProvider == BuiltInProviderIDs.kokoroNative, !canTurnOnKokoroNative else {
            updatePublishedSettings()
            return
        }
        settings.selectedTTSProvider = nil
        currentSpeechSettings.update(settings)
        updatePublishedSettings()
        persistSettings()
    }

    private func kokoroVoices(
        from manifest: ProviderAssetManifest,
        installedGroupIDs: Set<String>
    ) -> [TTSVoice] {
        manifest.voiceGroups
            .filter { installedGroupIDs.contains($0.id) }
            .flatMap { group in
                group.voices.map { voice in
                    TTSVoice(
                        id: voice.id,
                        displayName: voice.displayName,
                        locale: group.locale,
                        traits: [group.displayName]
                    )
                }
            }
    }

    private func refreshMoonshineModelStatus() async {
        let status = await moonshineModelStore.status()
        await MainActor.run {
            switch status {
            case .missing:
                self.isMoonshineModelInstalled = false
                self.moonshineModelStatus = "Moonshine not downloaded"
            case .installed(let model):
                self.isMoonshineModelInstalled = true
                self.moonshineModelStatus = "Moonshine downloaded"
                self.settings.sttModelRecords[BuiltInProviderIDs.moonshineSTT] = self.moonshineModelStoreRecord(for: model)
            case .invalid(let message):
                self.isMoonshineModelInstalled = false
                self.moonshineModelStatus = message
            }
            self.reconcileUnavailableMoonshineSelection()
        }
    }

    private func refreshOllamaStatus() async {
        let state = await OllamaBrainProvider.discover()
        await MainActor.run {
            self.applyOllamaDiscoveryState(state)
        }
    }

    private func applyOllamaDiscoveryState(_ state: OllamaDiscoveryState) {
        switch state {
        case .ready(let models):
            ollamaInstalledAppURL = nil
            ollamaModels = models
            ollamaStatus = models.isEmpty ? "Running with no models" : "\(models.count) models available"
            updatePublishedAssistantBrainSelection()
            if hasConfiguredAssistantBrain {
                assistantStatus = selectedAssistantModelsAreAvailable(in: models)
                    ? "Ready with \(assistantBrainName)"
                    : "Selected model unavailable"
            } else {
                assistantStatus = "Choose an Ollama model"
            }
        case .runningWithoutModels:
            ollamaInstalledAppURL = nil
            ollamaModels = []
            selectedOllamaModelID = nil
            selectedCompanionRouterOllamaModelID = nil
            selectedGeneralChatOllamaModelID = nil
            ollamaStatus = "Ollama is running with no models"
            assistantStatus = "No Ollama models"
        case .installedNotRunning(let appURL):
            ollamaInstalledAppURL = appURL
            ollamaModels = []
            ollamaStatus = "Installed, not running"
            assistantStatus = hasConfiguredAssistantBrain ? "Start Ollama" : "Ollama not running"
        case .unavailable:
            ollamaInstalledAppURL = nil
            ollamaModels = []
            ollamaStatus = "Not found"
            assistantStatus = hasConfiguredAssistantBrain ? "Ollama unavailable" : "Not configured"
        }
    }

    private func selectedAssistantModelsAreAvailable(in models: [OllamaModel]) -> Bool {
        let selectedModelIDs = Set(
            assistantBrainRoleSelections.values
                .compactMap { $0.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !selectedModelIDs.isEmpty else {
            return false
        }
        let availableModelIDs = Set(models.map(\.id))
        return selectedModelIDs.isSubset(of: availableModelIDs)
    }

    private func moonshineModelStoreRecord(for model: MoonshineManagedModel) -> STTModelRecord {
        STTModelRecord(
            modelID: model.id,
            displayName: model.displayName,
            localPath: model.directory.path,
            installedAt: model.installedAt ?? model.verifiedAt,
            verifiedAt: model.verifiedAt
        )
    }

    private func reconcileUnavailableMoonshineSelection() {
        guard settings.selectedSTTProvider == BuiltInProviderIDs.moonshineSTT, !canUseMoonshine else {
            updatePublishedSettings()
            return
        }
        settings.selectedSTTProvider = nil
        currentDictationSettings.update(settings)
        updatePublishedSettings()
        persistSettings()
    }

    private func persistSettings() {
        let settings = settings
        let previousSave = settingsSaveTask
        let task = Task<String?, Never> { [settingsStore] in
            _ = await previousSave?.value
            do {
                try await settingsStore.save(settings)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        settingsSaveTask = task

        Task { [weak self, task] in
            guard let message = await task.value else {
                return
            }
            await MainActor.run {
                self?.statusText = message
            }
        }
    }

    var hotkeyDefinition: HotkeyDefinition {
        settings.hotkey
    }

    func reportStartupWarning(_ message: String) {
        statusText = message
    }

    deinit {
        companionTask?.cancel()
        playbackTask?.cancel()
        audioLevelTask?.cancel()
        dictationTask?.cancel()
        dictationStateTask?.cancel()
        assistantTask?.cancel()
        assistantStateTask?.cancel()
        assistantMessageTask?.cancel()
        assistantMetricsTask?.cancel()
        kokoroInstallTask?.cancel()
        kokoroWarmupTask?.cancel()
        moonshineInstallTask?.cancel()
    }

    private func observePlaybackState() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self, playback] in
            for await state in playback.stateUpdates {
                await MainActor.run {
                    self?.isSpeechActive = state.isMenuStopState
                    self?.isSpeechAudioPlaying = state == .playing
                    if state != .playing {
                        self?.speechAudioLevel = 0
                    }
                    self?.updatePreviewState(for: state)
                }
            }
        }

        audioLevelTask?.cancel()
        audioLevelTask = Task { [weak self, playback] in
            for await level in playback.audioLevelUpdates {
                await MainActor.run {
                    guard self?.isSpeechAudioPlaying == true else {
                        self?.speechAudioLevel = 0
                        return
                    }
                    self?.speechAudioLevel = level
                }
            }
        }
    }

    private func observeDictationState() {
        dictationStateTask?.cancel()
        guard let dictationOrchestrator else {
            return
        }

        dictationStateTask = Task { [weak self, dictationOrchestrator] in
            for await state in dictationOrchestrator.stateUpdates {
                await MainActor.run {
                    self?.applyDictationState(state)
                }
                await self?.refreshRecoverableDictationState()
            }
        }
    }

    private func observeAssistantState() {
        assistantStateTask?.cancel()
        guard let assistantSession else {
            return
        }

        assistantStateTask = Task { [weak self, assistantSession] in
            for await state in assistantSession.stateUpdates {
                await MainActor.run {
                    self?.applyAssistantState(state)
                }
            }
        }
    }

    private func observeAssistantMessages() {
        assistantMessageTask?.cancel()
        guard let assistantSession else {
            return
        }

        assistantMessageTask = Task { [weak self, assistantSession] in
            for await messages in assistantSession.messageUpdates {
                await MainActor.run {
                    self?.chatMessages = messages
                    self?.logNewChatTranscriptMessages(messages)
                }
            }
        }
    }

    private func logNewChatTranscriptMessages(_ messages: [ChatMessage]) {
        guard settings.rawTranscriptLoggingEnabled else {
            return
        }

        let messagesToLog = messages.filter { message in
            guard shouldLogChatTranscriptMessage(message),
                  !loggedChatTranscriptMessageIDs.contains(message.id),
                  !pendingChatTranscriptMessageIDs.contains(message.id)
            else {
                return false
            }

            pendingChatTranscriptMessageIDs.insert(message.id)
            return true
        }
        guard !messagesToLog.isEmpty else {
            return
        }

        let logStore = chatTranscriptLogStore
        let loggingGeneration = rawTranscriptLoggingGeneration
        Task { [weak self, logStore] in
            for message in messagesToLog {
                let shouldAppend = await MainActor.run {
                    guard let self else {
                        return false
                    }
                    return self.settings.rawTranscriptLoggingEnabled
                        && self.rawTranscriptLoggingGeneration == loggingGeneration
                }
                guard shouldAppend else {
                    await MainActor.run {
                        guard let self else {
                            return
                        }
                        _ = self.pendingChatTranscriptMessageIDs.remove(message.id)
                    }
                    continue
                }

                do {
                    try await logStore.append(message)
                    await MainActor.run {
                        self?.markChatTranscriptMessageLogged(message.id)
                    }
                } catch {
                    await MainActor.run {
                        self?.markChatTranscriptMessageFailed(message.id, error: error)
                    }
                }
            }
        }
    }

    private func markChatTranscriptMessageLogged(_ messageID: ChatMessageID) {
        pendingChatTranscriptMessageIDs.remove(messageID)
        loggedChatTranscriptMessageIDs.insert(messageID)
        refreshChatTranscriptLogInfo()
    }

    private func markChatTranscriptMessageFailed(_ messageID: ChatMessageID, error: Error) {
        pendingChatTranscriptMessageIDs.remove(messageID)
        chatTranscriptLogger.error(
            "Failed to append chat transcript \(messageID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    private func shouldLogChatTranscriptMessage(_ message: ChatMessage) -> Bool {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        switch message.status {
        case .completed, .failed, .cancelled:
            return message.turnID != nil || message.status == .failed
        case .pending, .streaming:
            return false
        }
    }

    private func observeAssistantTurnMetrics() {
        assistantMetricsTask?.cancel()
        guard let assistantSession else {
            return
        }

        assistantMetricsTask = Task { [weak self, assistantSession] in
            for await metrics in assistantSession.turnMetricsUpdates {
                await MainActor.run {
                    self?.recordAssistantTurnMetrics(metrics)
                }
            }
        }
    }

    private func recordAssistantTurnMetrics(_ metrics: AssistantTurnMetrics) {
        assistantTurnMetrics.insert(metrics, at: 0)
        if assistantTurnMetrics.count > 20 {
            assistantTurnMetrics.removeLast(assistantTurnMetrics.count - 20)
        }

        let logStore = assistantMetricsLogStore
        Task {
            try? await logStore.append(metrics)
        }
    }

    private func applyDictationState(_ state: DictationState) {
        switch state {
        case .idle:
            isDictationActive = false
            dictationStatus = "Ready"
        case .requestingPermission:
            isDictationActive = false
            dictationStatus = "Requesting permission"
        case .listening:
            isDictationActive = true
            dictationStatus = "Listening"
            statusText = "Listening"
        case .transcribing:
            isDictationActive = true
            dictationStatus = "Transcribing"
            statusText = "Transcribing"
        case .inserting:
            isDictationActive = false
            dictationStatus = "Inserting"
            statusText = "Inserting dictation"
        case .stopped:
            isDictationActive = false
            dictationStatus = "Stopped"
            statusText = "Ready"
            dictationTask = nil
        case .failed(let message):
            isDictationActive = false
            dictationStatus = message
            statusText = message
            dictationTask = nil
        }
    }

    private func applyAssistantState(_ state: AssistantState) {
        switch state {
        case .idle:
            isAssistantActive = false
            isAssistantTurnActive = false
            assistantStatus = hasConfiguredAssistantBrain ? "Ready" : "Not configured"
        case .requestingPermission:
            isAssistantActive = false
            isAssistantTurnActive = true
            assistantStatus = "Requesting permission"
        case .listening:
            isAssistantActive = true
            isAssistantTurnActive = true
            assistantStatus = "Listening"
            statusText = "Listening"
        case .transcribing:
            isAssistantActive = true
            isAssistantTurnActive = true
            assistantStatus = "Transcribing"
            statusText = "Transcribing"
        case .thinking:
            isAssistantActive = false
            isAssistantTurnActive = true
            assistantStatus = "Thinking"
            statusText = "Thinking"
        case .acting(let action):
            isAssistantActive = false
            isAssistantTurnActive = true
            assistantStatus = action
            statusText = action
        case .speaking:
            isAssistantActive = false
            isAssistantTurnActive = true
            assistantStatus = "Speaking"
            statusText = "Speaking"
            assistantTask = nil
        case .stopped:
            isAssistantActive = false
            isAssistantTurnActive = false
            assistantStatus = hasConfiguredAssistantBrain ? "Ready" : "Not configured"
            statusText = "Ready"
            assistantTask = nil
        case .failed(let message):
            isAssistantActive = false
            isAssistantTurnActive = false
            assistantStatus = message
            statusText = message
            assistantTask = nil
        }
    }

    private func applyMicrophoneStatus(_ status: MicrophonePermissionStatus) {
        switch status {
        case .allowed:
            isMicrophoneAllowed = true
            microphoneStatus = "Allowed"
        case .notDetermined:
            isMicrophoneAllowed = false
            microphoneStatus = "Not requested"
        case .denied:
            isMicrophoneAllowed = false
            microphoneStatus = "Denied"
        case .restricted:
            isMicrophoneAllowed = false
            microphoneStatus = "Restricted"
        }
    }

    private func applySpeechRecognitionStatus(_ status: SpeechRecognitionPermissionStatus) {
        switch status {
        case .allowed:
            isSpeechRecognitionAllowed = true
            speechRecognitionStatus = "Allowed"
        case .notDetermined:
            isSpeechRecognitionAllowed = false
            speechRecognitionStatus = "Not requested"
        case .denied:
            isSpeechRecognitionAllowed = false
            speechRecognitionStatus = "Denied"
        case .restricted:
            isSpeechRecognitionAllowed = false
            speechRecognitionStatus = "Restricted"
        }
    }

    private func refreshRecoverableDictationState() async {
        let recovery = await dictationOrchestrator?.recoverableTranscript()
        await MainActor.run {
            self.hasRecoverableDictationTranscript = recovery != nil
        }
    }

    private func updatePreviewState(for state: SpeechPlaybackState) {
        guard isPreviewing else {
            return
        }

        switch state {
        case .idle:
            guard activePreviewPlaybackGeneration == previewGeneration else {
                return
            }
            previewGeneration += 1
            activePreviewPlaybackGeneration = nil
            isPreviewing = false
            previewStatus = "Preview finished"
        case .stopped:
            guard activePreviewPlaybackGeneration == previewGeneration else {
                return
            }
            previewGeneration += 1
            activePreviewPlaybackGeneration = nil
            isPreviewing = false
            previewStatus = "Preview stopped"
        case .failed(let message):
            previewGeneration += 1
            activePreviewPlaybackGeneration = nil
            isPreviewing = false
            previewStatus = message
        case .loading:
            previewStatus = "Starting preview"
        case .playing:
            previewStatus = "Preview playing"
        }
    }
}

extension RocaActivity {
    var safeCompanionMessage: String {
        switch self {
        case .idle:
            "Ready"
        case .readingSelection:
            "Reading selection"
        case .listening:
            "Listening"
        case .transcribing:
            "Transcribing"
        case .thinking:
            "Thinking"
        case .preparingSpeech:
            "Preparing voice"
        case .speaking:
            "Speaking"
        case .interrupted:
            "Interrupted"
        case .muted:
            "Muted"
        case .offline(let reason):
            reason.isEmpty ? "Offline" : reason
        case .waitingForPermission(let kind):
            "Waiting for \(kind.displayName)"
        }
    }
}

private extension PermissionKind {
    var displayName: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .microphone:
            "Microphone"
        case .speechRecognition:
            "Speech Recognition"
        }
    }
}

private extension SpeechPlaybackState {
    var isMenuStopState: Bool {
        switch self {
        case .loading, .playing:
            true
        case .idle, .stopped, .failed:
            false
        }
    }
}

struct KokoroVoiceGroupSettingsState: Identifiable, Equatable {
    var id: String
    var displayName: String
    var locale: String
    var voiceCount: Int
    var isDefault: Bool
    var isInstalled: Bool
    var isInstalling: Bool
    var status: String
}

enum SpeechProviderMode: String, CaseIterable, Identifiable {
    case automatic
    case kokoro
    case macOSVoice

    var id: String {
        rawValue
    }

    init(providerID: ProviderID?) {
        switch providerID {
        case BuiltInProviderIDs.kokoroNative:
            self = .kokoro
        case BuiltInProviderIDs.macOSVoice:
            self = .macOSVoice
        default:
            self = .automatic
        }
    }

    var providerID: ProviderID? {
        switch self {
        case .automatic:
            nil
        case .kokoro:
            BuiltInProviderIDs.kokoroNative
        case .macOSVoice:
            BuiltInProviderIDs.macOSVoice
        }
    }

    var title: String {
        switch self {
        case .automatic:
            "Automatic"
        case .kokoro:
            "Kokoro"
        case .macOSVoice:
            "macOS Voices"
        }
    }
}

enum STTProviderMode: String, CaseIterable, Identifiable {
    case automatic
    case appleSpeech
    case moonshine
    case whisperKit

    static let allCases: [STTProviderMode] = [.automatic, .appleSpeech, .moonshine]

    var id: String {
        rawValue
    }

    init(providerID: ProviderID?) {
        switch providerID {
        case BuiltInProviderIDs.appleSpeechSTT:
            self = .appleSpeech
        case BuiltInProviderIDs.moonshineSTT:
            self = .moonshine
        case BuiltInProviderIDs.whisperKitSTT:
            self = .whisperKit
        default:
            self = .automatic
        }
    }

    var providerID: ProviderID? {
        switch self {
        case .automatic:
            nil
        case .appleSpeech:
            BuiltInProviderIDs.appleSpeechSTT
        case .moonshine:
            BuiltInProviderIDs.moonshineSTT
        case .whisperKit:
            BuiltInProviderIDs.whisperKitSTT
        }
    }

    var title: String {
        switch self {
        case .automatic:
            "Automatic"
        case .appleSpeech:
            "Apple Speech"
        case .moonshine:
            "Moonshine"
        case .whisperKit:
            "WhisperKit"
        }
    }
}

private final class CurrentSpeechSettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: RocaSettings

    init(settings: RocaSettings) {
        self.settings = settings
    }

    func update(_ settings: RocaSettings) {
        lock.lock()
        defer {
            lock.unlock()
        }
        self.settings = settings
    }

    func selectedTTSProvider() -> ProviderID? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let provider = settings.selectedTTSProvider
        return provider
    }

    func speechConfiguration() -> SpeechConfiguration {
        lock.lock()
        defer {
            lock.unlock()
        }
        let configuration = settings.speechConfiguration
        return configuration
    }
}

private final class CurrentDictationSettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: RocaSettings

    init(settings: RocaSettings) {
        self.settings = settings
    }

    func update(_ settings: RocaSettings) {
        lock.lock()
        defer {
            lock.unlock()
        }
        self.settings = settings
    }

    func selectedSTTProvider() -> ProviderID? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return settings.selectedSTTProvider
    }

    func dictationConfiguration() -> DictationConfiguration {
        lock.lock()
        defer {
            lock.unlock()
        }
        return settings.dictationConfiguration
    }
}
