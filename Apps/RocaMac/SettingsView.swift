import AppKit
import RocaCore
import RocaProviders
import SwiftUI

struct RocaSettingsView: View {
    @ObservedObject var model: RocaAppModel
    @State private var selectedPane: SettingsPane? = .speech

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch selectedPane ?? .speech {
            case .speech:
                SpeechSettingsPane(
                    model: model,
                    openProviders: {
                        selectedPane = .providers
                    }
                )
            case .dictation:
                DictationSettingsPane(model: model)
            case .assistant:
                AssistantSettingsPane(model: model)
            case .companion:
                CompanionSettingsPane(model: model)
            case .providers:
                ProvidersSettingsPane(model: model)
            case .hotkey:
                HotkeySettingsPane(model: model)
            case .permissions:
                PermissionsSettingsPane(model: model)
            case .logs:
                LogsSettingsPane(model: model)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear {
            model.openSettingsWindowState()
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case speech
    case dictation
    case assistant
    case companion
    case providers
    case hotkey
    case permissions
    case logs

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .speech:
            "Speech"
        case .dictation:
            "Voice Input"
        case .assistant:
            "Assistant"
        case .companion:
            "Companion"
        case .providers:
            "Providers"
        case .hotkey:
            "Hotkey"
        case .permissions:
            "Permissions"
        case .logs:
            "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .speech:
            "speaker.wave.2"
        case .dictation:
            "mic"
        case .assistant:
            "sparkles"
        case .companion:
            "person.crop.circle"
        case .providers:
            "shippingbox"
        case .hotkey:
            "keyboard"
        case .permissions:
            "checkmark.shield"
        case .logs:
            "doc.text.magnifyingglass"
        }
    }
}

private struct CompanionSettingsPane: View {
    @ObservedObject var model: RocaAppModel

    var body: some View {
        SettingsPaneContainer(title: "Companion") {
            SettingsSection("Presence") {
                Toggle(
                    "Show Companion",
                    isOn: Binding(
                        get: { model.companionVisible },
                        set: { model.setCompanionVisible($0) }
                    )
                )

                SettingsRow(label: "Status") {
                    StatusText(
                        isActive: model.companionVisible,
                        text: model.companionVisible ? "Visible" : "Hidden"
                    )
                }

                SettingsRow(label: "Current State") {
                    Text(model.companionActivity.safeCompanionMessage)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection("Relationship") {
                Picker(
                    "Warmth",
                    selection: Binding(
                        get: { model.companionWarmth },
                        set: { model.setCompanionWarmth($0) }
                    )
                ) {
                    ForEach(CompanionWarmth.allCases) { warmth in
                        Text(warmth.title).tag(warmth)
                    }
                }
                .pickerStyle(.segmented)

                SettingsRow(label: "Behavior") {
                    Text(model.companionWarmth.description)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection("Motion") {
                SettingsRow(label: "Reduced Motion") {
                    Text("Follows macOS Accessibility settings")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SpeechSettingsPane: View {
    @ObservedObject var model: RocaAppModel
    var openProviders: () -> Void

    private var activeProviderID: ProviderID {
        model.activeSettingsVoiceProviderID
    }

    var body: some View {
        SettingsPaneContainer(title: "Speech") {
            SettingsSection("Provider") {
                Picker(
                    "Mode",
                    selection: Binding(
                        get: { model.speechProviderMode },
                        set: { model.setSpeechProviderMode($0) }
                    )
                ) {
                    ForEach(model.availableSpeechProviderModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if model.speechProviderMode == .automatic {
                    SettingsRow(label: "Active Provider") {
                        Text(model.activeSettingsVoiceProviderName)
                            .foregroundStyle(.secondary)
                    }

                    if model.hasMissingDownloadableSpeechProviders {
                        downloadMoreProvidersButton
                    }
                } else if model.hasMissingDownloadableSpeechProviders {
                    downloadMoreProvidersButton
                }
            }

            SettingsSection("Voice") {
                Picker(
                    "Voice",
                    selection: Binding<VoiceID?>(
                        get: { model.selectedVoice(for: activeProviderID) },
                        set: { model.setSelectedVoice($0, for: activeProviderID) }
                    )
                ) {
                    Text("Provider Default").tag(VoiceID?.none)
                    ForEach(model.ttsVoices[activeProviderID] ?? [], id: \.id) { voice in
                        Text(voiceTitle(voice)).tag(Optional(voice.id))
                    }
                }
                .disabled(model.loadingVoiceProviderIDs.contains(activeProviderID))

                SettingsRow(label: "Voice Status") {
                    HStack(spacing: 8) {
                        if model.loadingVoiceProviderIDs.contains(activeProviderID) {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(model.voiceLoadMessages[activeProviderID] ?? "Not loaded")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        model.refreshVoicesForCurrentSelection()
                    } label: {
                        Label("Reload Voices", systemImage: "arrow.clockwise")
                    }

                    Button {
                        model.previewSpeechFromSettings()
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .disabled(model.isPreviewing)

                    Text(model.previewStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            SettingsSection("Speed") {
                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { model.speechSpeed },
                            set: { model.setSpeechSpeed($0) }
                        ),
                        in: 0.5 ... 2.0,
                        step: 0.05
                    )
                    Text(model.speechSpeed.formatted(.number.precision(.fractionLength(2))) + "x")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
    }

    private func voiceTitle(_ voice: TTSVoice) -> String {
        if let locale = voice.locale, !locale.isEmpty {
            "\(voice.displayName) (\(locale))"
        } else {
            voice.displayName
        }
    }

    private var downloadMoreProvidersButton: some View {
        Button {
            openProviders()
        } label: {
            Label("Download More Providers", systemImage: "arrow.down.circle")
        }
    }
}

private struct DictationSettingsPane: View {
    @ObservedObject var model: RocaAppModel

    var body: some View {
        SettingsPaneContainer(title: "Voice Input") {
            SettingsSection("Input") {
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { model.sttProviderMode },
                        set: { model.setSTTProviderMode($0) }
                    )
                ) {
                    ForEach(model.availableSTTProviderModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if model.sttProviderMode == .automatic {
                    SettingsRow(label: "Automatic Order") {
                        Text(model.activeSTTProviderName)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsRow(label: "Language") {
                    Text(model.dictationLanguageDescription)
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: "Mode") {
                    Text(model.dictationModeDescription)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection("Recovery") {
                SettingsRow(label: "Status") {
                    StatusText(
                        isActive: model.hasRecoverableDictationTranscript,
                        text: model.hasRecoverableDictationTranscript ? "Transcript available" : "No recoverable transcript"
                    )
                }

                HStack {
                    Button {
                        model.retryRecoverableDictation()
                    } label: {
                        Label("Retry Insert", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!model.hasRecoverableDictationTranscript)

                    Button {
                        model.copyRecoverableDictation()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(!model.hasRecoverableDictationTranscript)

                    Button {
                        model.discardRecoverableDictation()
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .disabled(!model.hasRecoverableDictationTranscript)
                }
            }
        }
    }
}

private struct AssistantSettingsPane: View {
    @ObservedObject var model: RocaAppModel

    var body: some View {
        SettingsPaneContainer(title: "Assistant") {
            SettingsSection("Status") {
                SettingsRow(label: "Assistant") {
                    StatusText(isActive: model.hasConfiguredAssistantBrain, text: model.assistantStatus)
                }

                SettingsRow(label: "Shortcut") {
                    Text(model.assistantHotkeyDescription)
                        .font(.system(.body, design: .monospaced))
                }
            }

            SettingsSection("Brain") {
                SettingsRow(label: "Provider") {
                    Text("Ollama")
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: "Ollama") {
                    HStack(spacing: 10) {
                        StatusText(isActive: !model.ollamaModels.isEmpty, text: model.ollamaStatus)
                        Button {
                            model.refreshOllamaFromSettings()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                }

                if model.ollamaStatus == "Installed, not running" {
                    Button {
                        model.startOllamaFromSettings()
                    } label: {
                        Label("Start Ollama", systemImage: "play")
                    }
                }

                if !model.ollamaModels.isEmpty {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { model.selectedOllamaModelID },
                            set: { model.setAssistantOllamaModel($0) }
                        )
                    ) {
                        Text("Choose Model").tag(Optional<String>.none)
                        ForEach(model.ollamaModelsForPicker) { item in
                            Label(item.displayName, systemImage: model.ollamaModelPickerSystemImage(for: item))
                                .tag(Optional(item.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            SettingsSection("Session") {
                SettingsRow(label: "Context") {
                    Text("Ephemeral while Roca is running")
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: "Typing") {
                    Text("Only when explicitly requested")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            model.refreshOllamaFromSettings()
        }
    }
}

private struct ProvidersSettingsPane: View {
    @ObservedObject var model: RocaAppModel
    @State private var isKokoroLanguagePacksExpanded = false

    var body: some View {
        SettingsPaneContainer(title: "Providers") {
            SettingsSection("Kokoro") {
                SettingsRow(label: "Status") {
                    StatusText(isActive: model.isKokoroModelInstalled, text: model.kokoroNativeStatus)
                }

                if model.isInstallingKokoroModel {
                    DownloadProgressView(
                        progress: model.kokoroDownloadProgress,
                        cancel: model.cancelKokoroDownloadFromSettings
                    )
                } else if !model.isKokoroModelInstalled {
                    Button {
                        model.installKokoroFromSettings()
                    } label: {
                        Label("Download Kokoro", systemImage: "arrow.down.circle")
                    }
                }

                if !model.isInstallingKokoroModel, model.kokoroDownloadProgress != nil {
                    DownloadProgressView(
                        progress: model.kokoroDownloadProgress,
                        cancel: model.cancelKokoroDownloadFromSettings
                    )
                }

                if model.isKokoroModelInstalled, !model.kokoroVoiceGroups.isEmpty {
                    DisclosureGroup(isExpanded: $isKokoroLanguagePacksExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.kokoroVoiceGroups) { group in
                                SettingsRow(label: group.displayName) {
                                    HStack(spacing: 10) {
                                        if group.isInstalling {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        StatusText(isActive: group.isInstalled, text: group.status)

                                        if !group.isInstalled {
                                            Button {
                                                model.installKokoroVoiceGroupFromSettings(group.id)
                                            } label: {
                                                Label("Download", systemImage: "arrow.down.circle")
                                            }
                                            .disabled(model.isInstallingKokoroModel || group.isInstalling)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Text("Language Packs")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            SettingsSection("macOS Voices") {
                SettingsRow(label: "Status") {
                    StatusText(isActive: true, text: model.macOSVoiceStatus)
                }
            }

            SettingsSection("Moonshine") {
                SettingsRow(label: "Status") {
                    StatusText(isActive: model.isMoonshineModelInstalled, text: model.moonshineModelStatus)
                }

                if model.isInstallingMoonshineModel {
                    DownloadProgressView(
                        progress: model.moonshineDownloadProgress,
                        cancel: model.cancelMoonshineDownloadFromSettings
                    )
                } else if !model.isMoonshineModelInstalled {
                    Button {
                        model.installMoonshineModelFromSettings()
                    } label: {
                        Label("Download Moonshine", systemImage: "arrow.down.circle")
                    }
                }
            }

            SettingsSection("Apple Speech") {
                SettingsRow(label: "Status") {
                    StatusText(isActive: model.isSpeechRecognitionAllowed, text: model.speechRecognitionStatus)
                }
            }
        }
    }
}

private struct HotkeySettingsPane: View {
    @ObservedObject var model: RocaAppModel

    var body: some View {
        SettingsPaneContainer(title: "Hotkey") {
            SettingsSection("Talk to Roca") {
                SettingsRow(label: "Shortcut") {
                    Text(model.hotkeyDescription)
                        .font(.system(.body, design: .monospaced))
                }

                SettingsRow(label: "Behavior") {
                    Text("Starts or stops a voice assistant turn")
                        .foregroundStyle(.secondary)
                }

                Button {
                } label: {
                    Label("Change Shortcut", systemImage: "keyboard.badge.ellipsis")
                }
                .disabled(true)
            }
        }
    }
}

private struct PermissionsSettingsPane: View {
    @ObservedObject var model: RocaAppModel

    var body: some View {
        SettingsPaneContainer(title: "Permissions") {
            SettingsSection("Microphone") {
                SettingsRow(label: "Status") {
                    StatusText(
                        isActive: model.isMicrophoneAllowed,
                        text: model.microphoneStatus
                    )
                }

                HStack {
                    Button {
                        model.requestMicrophonePermission()
                    } label: {
                        Label("Request Access", systemImage: "mic")
                    }

                    Button {
                        model.refreshMicrophoneStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }

            SettingsSection("Speech Recognition") {
                SettingsRow(label: "Status") {
                    StatusText(
                        isActive: model.isSpeechRecognitionAllowed,
                        text: model.speechRecognitionStatus
                    )
                }

                HStack {
                    Button {
                        model.requestSpeechRecognitionPermission()
                    } label: {
                        Label("Request Access", systemImage: "waveform")
                    }

                    Button {
                        model.refreshSpeechRecognitionStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }

            SettingsSection("Accessibility") {
                SettingsRow(label: "Status") {
                    StatusText(
                        isActive: model.isAccessibilityTrusted,
                        text: model.isAccessibilityTrusted ? "Allowed" : "Needed"
                    )
                }

                HStack {
                    Button {
                        model.requestAccessibilityPermission()
                    } label: {
                        Label("Request Access", systemImage: "checkmark.shield")
                    }

                    Button {
                        model.refreshAccessibilityStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

private struct LogsSettingsPane: View {
    @ObservedObject var model: RocaAppModel

    var body: some View {
        SettingsPaneContainer(title: "Logs") {
            SettingsSection("Locations") {
                SettingsRow(label: "Logs") {
                    PathText(model.logsDirectoryPath)
                }

                SettingsRow(label: "Models") {
                    PathText(model.modelsDirectoryPath)
                }

                SettingsRow(label: "Assistant Metrics") {
                    PathText(model.assistantMetricsLogPath)
                }

                HStack {
                    Button {
                        reveal(model.logsDirectoryPath)
                    } label: {
                        Label("Reveal Logs", systemImage: "folder")
                    }

                    Button {
                        reveal(model.modelsDirectoryPath)
                    } label: {
                        Label("Reveal Models", systemImage: "folder")
                    }
                }
            }

            SettingsSection("Chat Transcripts") {
                Toggle(
                    "Save Raw Chat Transcripts",
                    isOn: Binding(
                        get: { model.rawTranscriptLoggingEnabled },
                        set: { model.setRawTranscriptLoggingEnabled($0) }
                    )
                )

                Text("Raw transcripts may include prompts, responses, and selected text used in assistant workflows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsRow(label: "Status") {
                    Text(model.chatTranscriptLogSummary)
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: "Path") {
                    PathText(model.chatTranscriptLogPath)
                }

                HStack {
                    Button {
                        exportTranscript()
                    } label: {
                        Label("Export Raw Transcript...", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!model.hasChatTranscriptLog)

                    Button(role: .destructive) {
                        confirmDeleteTranscript()
                    } label: {
                        Label("Delete Transcript Log...", systemImage: "trash")
                    }
                    .disabled(!model.hasChatTranscriptLog)

                    Button {
                        model.refreshChatTranscriptLogInfo()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                if !model.chatTranscriptLogActionStatus.isEmpty {
                    Text(model.chatTranscriptLogActionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection("Assistant Timings") {
                if model.assistantTurnMetrics.isEmpty {
                    Text("No assistant turns recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.assistantTurnMetrics.prefix(8)) { metrics in
                            AssistantTimingRow(metrics: metrics)
                        }
                    }
                }
            }
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.title = "Export Raw Transcript"
        panel.nameFieldStringValue = "assistant_chat_transcript.jsonl"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }
        model.exportChatTranscriptLog(to: url)
    }

    private func confirmDeleteTranscript() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Raw Transcript Log?"
        alert.informativeText = "This deletes the local transcript file only. The current in-memory chat stays open."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        model.deleteChatTranscriptLog()
    }
}

private struct AssistantTimingRow: View {
    var metrics: AssistantTurnMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(metrics.startedAt, style: .time)
                Text(outcomeText)
                Text("total \(durationText(metrics.totalMilliseconds))")
                if let directiveType = metrics.directiveType {
                    Text(directiveType.rawValue)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                MetricChip(label: "Setup", value: durationText(metrics.setupMilliseconds))
                MetricChip(label: "Recording", value: durationText(metrics.recordingMilliseconds))
                MetricChip(label: "STT", value: durationText(metrics.transcriptionMilliseconds))
                MetricChip(label: "Directive", value: durationText(metrics.directiveBrainMilliseconds))
                MetricChip(label: "Response", value: durationText(metrics.responseBrainMilliseconds))
                MetricChip(label: "Action", value: durationText(metrics.actionMilliseconds))
                MetricChip(label: "TTS Prep", value: durationText(metrics.ttsPreparationMilliseconds))
                MetricChip(label: "First Audio", value: durationText(metrics.ttsFirstAudioMilliseconds))
                MetricChip(label: "Synthesis", value: durationText(metrics.ttsSynthesisMilliseconds))
                MetricChip(label: "Audio", value: durationText(metrics.ttsAudioDurationMilliseconds))
                MetricChip(label: "Wait", value: durationText(metrics.ttsPlaybackMilliseconds))
                if let utterances = metrics.ttsUtteranceCount,
                   let chunks = metrics.ttsAudioChunkCount {
                    MetricChip(label: "TTS Units", value: "\(utterances) / \(chunks) chunks")
                }
                if let captured = metrics.capturedAudioFrameCount,
                   let dropped = metrics.droppedAudioFrameCount {
                    MetricChip(label: "Frames", value: "\(captured) / \(dropped) dropped")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var columns: [GridItem] {
        [
            GridItem(.fixed(112), spacing: 8, alignment: .leading),
            GridItem(.fixed(112), spacing: 8, alignment: .leading),
            GridItem(.fixed(112), spacing: 8, alignment: .leading),
            GridItem(.fixed(112), spacing: 8, alignment: .leading)
        ]
    }

    private var outcomeText: String {
        switch metrics.outcome {
        case .completed:
            "Completed"
        case .cancelled:
            "Cancelled"
        case .failed:
            "Failed"
        }
    }
}

private struct MetricChip: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private func durationText(_ milliseconds: Int?) -> String {
    guard let milliseconds else {
        return "-"
    }
    return durationText(milliseconds)
}

private func durationText(_ milliseconds: Int) -> String {
    if milliseconds < 1_000 {
        return "\(milliseconds) ms"
    }
    return String(format: "%.2f s", Double(milliseconds) / 1_000)
}

private struct SettingsPaneContainer<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title)
                    .font(.title2.weight(.semibold))

                content
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            Divider()
        }
    }
}

private struct SettingsRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatusText: View {
    var isActive: Bool
    var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isActive ? .green : .secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DownloadProgressView: View {
    var progress: ManagedDownloadProgress?
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 360)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            HStack(spacing: 10) {
                progressSummary
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)

                Button {
                    cancel()
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }

            if let currentItem = progress?.currentItem {
                Text(currentItem)
                    .foregroundStyle(.tertiary)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var fraction: Double? {
        guard let progress,
              let totalBytes = progress.totalBytes,
              totalBytes > 0
        else {
            return nil
        }
        return min(1, max(0, Double(progress.completedBytes) / Double(totalBytes)))
    }

    @ViewBuilder
    private var progressSummary: some View {
        if let progress {
            HStack(spacing: 8) {
                Text(percentText)

                ZStack(alignment: .trailing) {
                    Text(completedWidthReference)
                        .hidden()
                        .accessibilityHidden(true)
                    Text(byteText(progress.completedBytes))
                }

                Text("of")
                Text(totalText)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                ZStack(alignment: .trailing) {
                    Text(speedWidthReference)
                        .hidden()
                        .accessibilityHidden(true)
                    Text("\(byteText(Int64(progress.bytesPerSecond)))/s")
                }
            }
        } else {
            Text("Preparing download...")
        }
    }

    private var percentText: String {
        fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "..."
    }

    private var totalText: String {
        guard let totalBytes = progress?.totalBytes else {
            return "unknown size"
        }
        return byteFormatter.string(fromByteCount: totalBytes)
    }

    private var completedWidthReference: String {
        guard let totalBytes = progress?.totalBytes else {
            return "999.9 MB"
        }
        let total = byteFormatter.string(fromByteCount: totalBytes)
        let nearTotal = byteFormatter.string(fromByteCount: max(totalBytes - 1, 0))
        return [total, nearTotal, "999.9 MB"].max(by: { $0.count < $1.count }) ?? total
    }

    private var speedWidthReference: String {
        "99.9 MB/s"
    }

    private func byteText(_ byteCount: Int64) -> String {
        guard byteCount > 0 else {
            return "0 MB"
        }
        return byteFormatter.string(fromByteCount: byteCount)
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        return formatter
    }
}

private struct PathText: View {
    var path: String

    init(_ path: String) {
        self.path = path
    }

    var body: some View {
        Text(path)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

@MainActor
final class AssistantSetupWindowController: NSObject, NSWindowDelegate {
    private let model: RocaAppModel
    private let visibilityDidChange: @MainActor () -> Void
    private var window: NSWindow?
    private var isSetupOpen = false

    init(model: RocaAppModel, visibilityDidChange: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.visibilityDidChange = visibilityDidChange
        super.init()
    }

    func show() {
        if let window {
            setOpen(true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AssistantSetupView(model: model) { [weak self] in
            self?.closeSetup()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set Up Roca Assistant"
        window.setContentSize(NSSize(width: 560, height: 340))
        window.minSize = NSSize(width: 520, height: 320)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.delegate = self
        self.window = window
        setOpen(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isOpen: Bool {
        isSetupOpen
    }

    func closeSetup() {
        setOpen(false)
        window?.close()
        window = nil
    }

    func owns(_ candidate: NSWindow?) -> Bool {
        candidate === window
    }

    func windowWillClose(_ notification: Notification) {
        setOpen(false)
        window = nil
    }

    private func setOpen(_ open: Bool) {
        guard isSetupOpen != open else {
            return
        }
        isSetupOpen = open
        visibilityDidChange()
    }
}

private struct AssistantSetupView: View {
    @ObservedObject var model: RocaAppModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Roca Assistant")
                .font(.title2.weight(.semibold))

            Text("Choose a local Ollama model to talk with Roca. By skipping this, only dictation will be supported.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                readinessRow(title: "Speech", value: model.voiceProviderMenuDescription, isReady: true)
                readinessRow(title: "Dictation", value: model.activeSTTProviderName, isReady: true)
                readinessRow(title: "Assistant", value: model.assistantStatus, isReady: model.hasConfiguredAssistantBrain)
            }

            Divider()

            Text("Ollama")
                .font(.headline)
            StatusText(isActive: !model.ollamaModels.isEmpty, text: model.ollamaStatus)
                .lineLimit(1)

            if !model.ollamaModels.isEmpty {
                Picker(
                    "Model",
                    selection: Binding(
                        get: { model.selectedOllamaModelID ?? model.recommendedOllamaModelID ?? model.ollamaModelsForPicker.first?.id },
                        set: { model.setAssistantOllamaModel($0) }
                    )
                ) {
                    ForEach(model.ollamaModelsForPicker) { item in
                        Label(item.displayName, systemImage: model.ollamaModelPickerSystemImage(for: item))
                            .tag(Optional(item.id))
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Button {
                    model.refreshOllamaFromSettings()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    model.startOllamaFromSettings()
                } label: {
                    Label("Start Ollama", systemImage: "play")
                }
                .disabled(model.ollamaStatus != "Installed, not running")

                Spacer()

                Button("Skip For Now") {
                    model.skipAssistantOnboarding()
                    close()
                }

                Button("Done") {
                    if !model.hasConfiguredAssistantBrain,
                       let recommended = model.recommendedOllamaModelID {
                        model.setAssistantOllamaModel(recommended)
                    }
                    model.finishAssistantOnboarding()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 340, alignment: .topLeading)
        .onAppear {
            model.refreshOllamaFromSettings()
        }
    }

    private func readinessRow(title: String, value: String, isReady: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isReady ? .green : .secondary)
            Text(title)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
