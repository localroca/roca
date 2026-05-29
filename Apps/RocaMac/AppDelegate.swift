import AppKit
import RocaCore
import RocaProviders
import RocaServices
import RocaStorage

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var appModel: RocaAppModel?
    private var hotkeyController: HotkeyController?
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

        let statusBarController = StatusBarController(model: model) { [weak self] in
            self?.requestFullQuit()
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
                setDockIconVisible: { visible in
                    self?.setDockIconVisible(visible)
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
                let setup = AssistantSetupWindowController(model: model)
                self?.assistantSetupWindowController = setup
                setup.show()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isFullQuitRequested, chatPanelWindowController?.isOpen == true {
            chatPanelWindowController?.closeChat()
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
    @objc private func requestChatQuit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @MainActor
    private func requestFullQuit() {
        isFullQuitRequested = true
        NSApp.terminate(nil)
    }

    @MainActor
    private func setDockIconVisible(_ visible: Bool) {
        if visible {
            installMainMenu()
        }
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    @MainActor
    private func installMainMenu() {
        guard NSApp.mainMenu == nil else {
            return
        }

        let mainMenu = NSMenu()
        mainMenu.addItem(makeApplicationMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func makeApplicationMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem(title: "Roca", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Roca")
        let quitItem = NSMenuItem(
            title: "Close Chat",
            action: #selector(requestChatQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        return appMenuItem
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
