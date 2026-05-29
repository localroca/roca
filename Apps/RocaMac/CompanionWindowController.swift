import AppKit
import Combine
import RocaCore
import SwiftUI

@MainActor
final class CompanionWindowController: NSWindowController, NSWindowDelegate {
    private let model: RocaAppModel
    private var cancellables: Set<AnyCancellable> = []
    private var isApplyingModelVisibility = false

    init(model: RocaAppModel) {
        self.model = model

        let contentView = CompanionView(model: model)
        let hostingController = NSHostingController(rootView: contentView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 236, height: 286),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.title = "Roca Companion"
        panel.setContentSize(NSSize(width: 236, height: 286))
        panel.minSize = NSSize(width: 218, height: 260)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setFrameAutosaveName("RocaCompanionWindow")

        super.init(window: panel)

        panel.delegate = self

        model.$companionVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.applyVisibility(visible)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install() {
        applyVisibility(model.companionVisible)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isApplyingModelVisibility else {
            return
        }
        model.hideCompanion()
    }

    private func applyVisibility(_ visible: Bool) {
        guard let window else {
            return
        }

        isApplyingModelVisibility = true
        defer { isApplyingModelVisibility = false }

        if visible {
            if !window.isVisible {
                if window.frame.origin == .zero {
                    window.center()
                }
            }
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }
}

private struct CompanionView: View {
    @ObservedObject var model: RocaAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isChatHovering = false
    @State private var isMuteHovering = false
    @State private var isCloseHovering = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.companionActivity.statusColor)
                    .frame(width: 8, height: 8)
                Text("Roca")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    model.showChatPanel()
                } label: {
                    Label("Open Chat", systemImage: "message")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(isChatHovering ? Color.white : Color.primary.opacity(0.72))
                        .background(isChatHovering ? Color.accentColor.opacity(0.86) : Color.primary.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open Chat")
                .onHover { isChatHovering = $0 }

                Button {
                    model.toggleAssistantSpeechMuted()
                } label: {
                    Label(
                        model.assistantSpeechMuted ? "Unmute Assistant Replies" : "Mute Assistant Replies",
                        systemImage: model.assistantSpeechMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(isMuteHovering ? Color.white : Color.primary.opacity(0.72))
                    .background(muteButtonBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .help(model.assistantSpeechMuted ? "Unmute Assistant Replies" : "Mute Assistant Replies")
                .onHover { isMuteHovering = $0 }

                Button {
                    model.hideCompanion()
                } label: {
                    Label("Hide Companion", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(isCloseHovering ? Color.white : Color.primary.opacity(0.72))
                        .background(isCloseHovering ? Color.red.opacity(0.86) : Color.primary.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Hide Companion")
                .onHover { isCloseHovering = $0 }
            }
            .frame(height: 24)

            CompanionAvatar(
                activity: model.companionActivity,
                isSpeaking: model.companionActivity == .speaking && model.isSpeechAudioPlaying,
                speechLevel: model.speechAudioLevel,
                warmth: model.companionWarmth,
                reduceMotion: reduceMotion
            )
            .frame(width: 148, height: 148)

            VStack(spacing: 4) {
                Text(model.companionActivity.companionTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.companionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 32, alignment: .top)
            }

            if model.companionWarmth == .warm {
                Text(model.companionActivity.warmHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(height: 14)
            }
        }
        .padding(14)
        .frame(width: 236, height: 286)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var muteButtonBackground: Color {
        if isMuteHovering {
            return model.assistantSpeechMuted ? Color.secondary.opacity(0.86) : Color.accentColor.opacity(0.86)
        }
        if model.assistantSpeechMuted {
            return Color.secondary.opacity(0.24)
        }
        return Color.primary.opacity(0.10)
    }
}

private struct CompanionAvatar: View {
    var activity: RocaActivity
    var isSpeaking: Bool
    var speechLevel: Double
    var warmth: CompanionWarmth
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 24.0)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breathing = reduceMotion ? 0 : sin(phase * 2.0) * 1.5

            ZStack {
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: palette.body,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .stroke(.white.opacity(0.34), lineWidth: 2)
                    )
                    .shadow(color: palette.shadow, radius: 16, x: 0, y: 8)
                    .scaleEffect(1 + breathing / 100)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.black.opacity(0.18))
                    .frame(width: 106, height: 86)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.24), lineWidth: 1)
                    )
                    .offset(y: 2)

                HStack(spacing: 26) {
                    eye
                    eye
                }
                .offset(y: -14)

                mouth(level: speechLevel)
                    .offset(y: 28)

                statusGlyph
                    .offset(x: 48, y: -50)
            }
        }
    }

    private var eye: some View {
        Capsule()
            .fill(.white.opacity(activity.isSoftened ? 0.68 : 0.92))
            .frame(width: activity.isThinking ? 22 : 18, height: activity.isBlocked ? 8 : 18)
            .overlay(
                Capsule()
                    .fill(palette.accent.opacity(0.9))
                    .frame(width: 7, height: activity.isBlocked ? 4 : 8)
            )
    }

    private func mouth(level: Double) -> some View {
        let openness = reduceMotion ? min(0.62, max(0.16, level)) : min(1, max(0, level))
        let height = isSpeaking ? 5 + (openness * 17) : activity.restingMouthHeight
        let width = isSpeaking ? 24 + (openness * 13) : activity.restingMouthWidth

        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(activity.isMuted ? 0.34 : 0.88))
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(palette.accent.opacity(0.5), lineWidth: activity.isMuted ? 1 : 0)
            )
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if let symbol = activity.symbolName {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(7)
                .background(palette.accent.opacity(0.82), in: Circle())
                .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 2)
        }
    }

    private var palette: CompanionPalette {
        CompanionPalette(activity: activity, warmth: warmth)
    }
}

private struct CompanionPalette {
    var body: [Color]
    var accent: Color
    var shadow: Color

    init(activity: RocaActivity, warmth: CompanionWarmth) {
        switch activity {
        case .listening, .transcribing:
            body = [Color(red: 0.12, green: 0.53, blue: 0.95), Color(red: 0.11, green: 0.72, blue: 0.77)]
            accent = Color(red: 0.33, green: 0.95, blue: 0.98)
            shadow = Color.blue.opacity(0.24)
        case .thinking, .preparingSpeech, .readingSelection:
            body = [Color(red: 0.35, green: 0.34, blue: 0.90), Color(red: 0.78, green: 0.42, blue: 0.92)]
            accent = Color(red: 0.98, green: 0.75, blue: 0.26)
            shadow = Color.purple.opacity(0.22)
        case .speaking:
            body = [Color(red: 0.17, green: 0.58, blue: 0.46), Color(red: 0.23, green: 0.76, blue: 0.58)]
            accent = Color(red: 1.0, green: 0.86, blue: 0.34)
            shadow = Color.green.opacity(0.22)
        case .offline, .waitingForPermission:
            body = [Color(red: 0.74, green: 0.25, blue: 0.29), Color(red: 0.93, green: 0.49, blue: 0.23)]
            accent = Color(red: 1.0, green: 0.83, blue: 0.47)
            shadow = Color.red.opacity(0.22)
        case .interrupted, .muted:
            body = [Color(red: 0.44, green: 0.46, blue: 0.52), Color(red: 0.30, green: 0.34, blue: 0.42)]
            accent = Color(red: 0.80, green: 0.85, blue: 0.92)
            shadow = Color.gray.opacity(0.20)
        case .idle:
            if warmth == .quiet {
                body = [Color(red: 0.34, green: 0.42, blue: 0.50), Color(red: 0.22, green: 0.29, blue: 0.36)]
                accent = Color(red: 0.66, green: 0.78, blue: 0.88)
                shadow = Color.gray.opacity(0.18)
            } else {
                body = [Color(red: 0.20, green: 0.44, blue: 0.88), Color(red: 0.58, green: 0.42, blue: 0.92)]
                accent = Color(red: 0.99, green: 0.78, blue: 0.28)
                shadow = Color.indigo.opacity(0.22)
            }
        }
    }
}

extension CompanionWarmth {
    var title: String {
        switch self {
        case .quiet:
            "Quiet"
        case .warm:
            "Warm"
        }
    }

    var description: String {
        switch self {
        case .quiet:
            "Minimal motion and fewer warm flourishes."
        case .warm:
            "Friendly presence with light delight and recovery cues."
        }
    }
}

private extension RocaActivity {
    var companionTitle: String {
        switch self {
        case .idle:
            "Ready"
        case .readingSelection:
            "Reading"
        case .listening:
            "Listening"
        case .transcribing:
            "Transcribing"
        case .thinking:
            "Thinking"
        case .preparingSpeech:
            "Preparing Voice"
        case .speaking:
            "Speaking"
        case .interrupted:
            "Interrupted"
        case .muted:
            "Muted"
        case .offline:
            "Needs Attention"
        case .waitingForPermission:
            "Permission Needed"
        }
    }

    var warmHint: String {
        switch self {
        case .idle:
            "Here when you need me."
        case .readingSelection:
            "I've got this."
        case .listening:
            "Go ahead."
        case .transcribing:
            "Catching that."
        case .thinking:
            "One moment."
        case .preparingSpeech:
            "Warming up my voice."
        case .speaking:
            "Talking it through."
        case .interrupted:
            "No problem."
        case .muted:
            "Quiet mode."
        case .offline, .waitingForPermission:
            "We'll sort it out."
        }
    }

    var symbolName: String? {
        switch self {
        case .idle:
            nil
        case .readingSelection:
            "text.book.closed"
        case .listening:
            "waveform"
        case .transcribing:
            "captions.bubble"
        case .thinking, .preparingSpeech:
            "sparkles"
        case .speaking:
            "speaker.wave.2.fill"
        case .interrupted:
            "pause.fill"
        case .muted:
            "speaker.slash.fill"
        case .offline:
            "exclamationmark"
        case .waitingForPermission:
            "lock.fill"
        }
    }

    var statusColor: Color {
        switch self {
        case .idle:
            .secondary
        case .readingSelection, .thinking, .preparingSpeech:
            Color(red: 0.98, green: 0.70, blue: 0.24)
        case .listening, .transcribing:
            Color(red: 0.25, green: 0.78, blue: 1.0)
        case .speaking:
            Color(red: 0.24, green: 0.78, blue: 0.48)
        case .interrupted, .muted:
            .secondary
        case .offline, .waitingForPermission:
            Color(red: 0.92, green: 0.32, blue: 0.28)
        }
    }

    var restingMouthWidth: Double {
        switch self {
        case .idle, .readingSelection:
            28
        case .thinking, .preparingSpeech, .transcribing:
            18
        case .offline, .waitingForPermission:
            22
        case .interrupted, .muted:
            30
        case .listening, .speaking:
            24
        }
    }

    var restingMouthHeight: Double {
        switch self {
        case .offline, .waitingForPermission:
            12
        case .thinking, .preparingSpeech, .transcribing:
            8
        case .interrupted, .muted:
            4
        case .idle, .readingSelection, .listening, .speaking:
            6
        }
    }

    var isThinking: Bool {
        switch self {
        case .thinking, .preparingSpeech, .readingSelection:
            true
        default:
            false
        }
    }

    var isBlocked: Bool {
        switch self {
        case .offline, .waitingForPermission:
            true
        default:
            false
        }
    }

    var isMuted: Bool {
        switch self {
        case .muted, .interrupted:
            true
        default:
            false
        }
    }

    var isSoftened: Bool {
        switch self {
        case .muted, .interrupted, .offline, .waitingForPermission:
            true
        default:
            false
        }
    }
}
