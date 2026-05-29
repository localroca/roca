import AppKit
import Combine

@MainActor
final class StatusBarController {
    private let model: RocaAppModel
    private let requestQuit: @MainActor () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var settingsWindowController = SettingsWindowController(model: model)
    private var cancellables: Set<AnyCancellable> = []

    init(model: RocaAppModel, requestQuit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.model = model
        self.requestQuit = requestQuit
    }

    func install() {
        statusItem.length = NSStatusItem.variableLength
        configureButton()
        rebuildMenu()

        model.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$isKokoroModelInstalled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$speechProviderMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$isSpeechActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$isDictationActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$isAssistantActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$isAssistantTurnActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$dictationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$assistantStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$hasRecoverableDictationTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$companionVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$companionWarmth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }

        button.toolTip = "Roca"
        button.title = "Roca"
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("Roca")

        if let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Roca") {
            image.isTemplate = true
            button.image = image
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Status: \(model.statusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let provider = NSMenuItem(title: "Voice Provider: \(model.voiceProviderMenuDescription)", action: nil, keyEquivalent: "")
        provider.isEnabled = false
        menu.addItem(provider)

        let dictation = NSMenuItem(title: "Voice Input: \(model.dictationStatus)", action: nil, keyEquivalent: "")
        dictation.isEnabled = false
        menu.addItem(dictation)

        let assistant = NSMenuItem(title: "Assistant: \(model.assistantStatus)", action: nil, keyEquivalent: "")
        assistant.isEnabled = false
        menu.addItem(assistant)
        menu.addItem(.separator())

        menu.addItem(
            menuItem(
                title: "Open Chat",
                action: #selector(openChat)
            )
        )

        if model.isSpeechActive && !model.isAssistantTurnActive {
            menu.addItem(
                menuItem(
                    title: "Stop Speaking",
                    action: #selector(stopSpeaking)
                )
            )
        }

        menu.addItem(
            menuItem(
                title: model.voiceInputMenuActionTitle,
                action: #selector(toggleVoiceInput)
            )
        )

        if model.hasRecoverableDictationTranscript {
            menu.addItem(
                menuItem(
                    title: "Copy Recovered Dictation",
                    action: #selector(copyRecoverableDictation)
                )
            )
        }
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: "Settings...",
                action: #selector(openSettings)
            )
        )
        menu.addItem(
            menuItem(
                title: model.companionVisible ? "Hide Companion" : "Show Companion",
                action: #selector(toggleCompanion)
            )
        )
        if model.companionWarmth == .warm {
            menu.addItem(
                menuItem(
                    title: "Make Companion Quieter",
                    action: #selector(makeCompanionQuieter)
                )
            )
        }
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: "Quit Roca",
                action: #selector(quit)
            )
        )

        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func stopSpeaking() {
        model.stopSpeechFromMenu()
    }

    @objc private func toggleVoiceInput() {
        model.toggleVoiceInput()
    }

    @objc private func copyRecoverableDictation() {
        model.copyRecoverableDictation()
    }

    @objc private func openSettings() {
        settingsWindowController.showSettings()
    }

    @objc private func openChat() {
        model.showChatPanel()
    }

    @objc private func toggleCompanion() {
        model.toggleCompanionVisibility()
    }

    @objc private func makeCompanionQuieter() {
        model.makeCompanionQuieter()
    }

    @objc private func quit() {
        requestQuit()
    }
}
