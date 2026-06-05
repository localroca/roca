import AppKit
import RocaCore
import RocaProviders
import RocaServices
import RocaStorage

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var appModel: RocaAppModel?
    private var hotkeyController: HotkeyController?
    private var settingsWindowController: SettingsWindowController?
    private var assistantSetupWindowController: AssistantSetupWindowController?
    private var chatPanelWindowController: ChatPanelWindowController?
    private var companionWindowController: CompanionWindowController?
    private var isFullQuitRequested = false
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NSApp.setActivationPolicy(.accessory)

        let model = RocaAppModel()
        appModel = model

        let settingsWindowController = SettingsWindowController(
            model: model,
            visibilityDidChange: { [weak self] in
                self?.syncActivationPolicy()
            }
        )
        self.settingsWindowController = settingsWindowController

        let statusBarController = StatusBarController(model: model) { [weak self] in
            self?.requestFullQuit()
        } requestSettings: { [weak settingsWindowController] in
            settingsWindowController?.showSettings()
        }
        self.statusBarController = statusBarController
        statusBarController.install()

        let hotkeyController = HotkeyController(
            talkAction: {
                model.toggleVoiceInput()
            }
        )
        self.hotkeyController = hotkeyController

        Task { @MainActor [weak self] in
            await model.bootstrap()
            do {
                try self?.hotkeyController?.registerHotkey(model.hotkeyDefinition)
            } catch {
                model.reportStartupWarning(error.localizedDescription)
            }
            let chat = ChatPanelWindowController(
                model: model,
                visibilityDidChange: {
                    self?.syncActivationPolicy()
                }
            )
            self?.chatPanelWindowController = chat
            model.setChatPanelPresenter { [weak chat] in
                chat?.showChat()
            }
            let companion = CompanionWindowController(model: model)
            self?.companionWindowController = companion
            companion.install()
            if model.shouldShowAssistantOnboarding {
                let setup = AssistantSetupWindowController(
                    model: model,
                    visibilityDidChange: {
                        self?.syncActivationPolicy()
                    }
                )
                self?.assistantSetupWindowController = setup
                setup.show()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isFullQuitRequested, closeKeyOrFrontmostRocaWindow() {
            return .terminateCancel
        }

        guard !isTerminating else {
            return .terminateNow
        }

        isTerminating = true
        Task { @MainActor in
            await appModel?.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    @objc private func closeActiveRocaWindow(_ sender: Any?) {
        closeKeyOrFrontmostRocaWindow()
    }

    @MainActor
    private func requestFullQuit() {
        isFullQuitRequested = true
        NSApp.terminate(nil)
    }

    @MainActor
    @discardableResult
    private func closeKeyOrFrontmostRocaWindow() -> Bool {
        if closeWindow(matching: NSApp.keyWindow) {
            return true
        }

        if closeWindow(matching: NSApp.mainWindow) {
            return true
        }

        for window in NSApp.orderedWindows where closeWindow(matching: window) {
            return true
        }

        if chatPanelWindowController?.isOpen == true {
            chatPanelWindowController?.closeChat()
            return true
        }

        if settingsWindowController?.isOpen == true {
            settingsWindowController?.closeSettings()
            return true
        }

        if assistantSetupWindowController?.isOpen == true {
            assistantSetupWindowController?.closeSetup()
            return true
        }

        syncActivationPolicy()
        return false
    }

    @MainActor
    private func closeWindow(matching window: NSWindow?) -> Bool {
        guard let window else {
            return false
        }

        if chatPanelWindowController?.owns(window) == true {
            chatPanelWindowController?.closeChat()
            return true
        }

        if settingsWindowController?.owns(window) == true {
            settingsWindowController?.closeSettings()
            return true
        }

        if assistantSetupWindowController?.owns(window) == true {
            assistantSetupWindowController?.closeSetup()
            return true
        }

        return false
    }

    @MainActor
    private func syncActivationPolicy() {
        let hasUserFacingWindow = chatPanelWindowController?.isOpen == true
            || settingsWindowController?.isOpen == true
            || assistantSetupWindowController?.isOpen == true

        if hasUserFacingWindow {
            installMainMenu()
        }
        NSApp.setActivationPolicy(hasUserFacingWindow ? .regular : .accessory)
    }

    @MainActor
    private func installMainMenu() {
        guard NSApp.mainMenu == nil else {
            return
        }

        let mainMenu = NSMenu()
        mainMenu.addItem(makeApplicationMenuItem())
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func makeApplicationMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem(title: "Roca", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Roca")
        let closeItem = NSMenuItem(
            title: "Close Roca Window",
            action: #selector(closeActiveRocaWindow),
            keyEquivalent: "q"
        )
        closeItem.target = self
        appMenu.addItem(closeItem)
        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Close Window",
            action: #selector(closeActiveRocaWindow),
            keyEquivalent: "w"
        )
        closeItem.target = self
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        editMenuItem.submenu = editMenu
        return editMenuItem
    }
}
