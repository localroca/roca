import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: RocaAppModel
    private let visibilityDidChange: @MainActor () -> Void
    private var isSettingsOpen = false

    init(model: RocaAppModel, visibilityDidChange: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.visibilityDidChange = visibilityDidChange

        let contentView = RocaSettingsView(model: model)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Roca Settings"
        window.setContentSize(NSSize(width: 760, height: 520))
        window.minSize = NSSize(width: 700, height: 480)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RocaSettingsWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        setOpen(true)
        model.openSettingsWindowState()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isOpen: Bool {
        isSettingsOpen
    }

    func closeSettings() {
        setOpen(false)
        window?.close()
    }

    func owns(_ candidate: NSWindow?) -> Bool {
        candidate === window
    }

    func windowWillClose(_ notification: Notification) {
        setOpen(false)
    }

    private func setOpen(_ open: Bool) {
        guard isSettingsOpen != open else {
            return
        }
        isSettingsOpen = open
        visibilityDidChange()
    }
}
