import AppKit
import Foundation
import RocaCore

public final class DefaultSelectionReader: SelectionReading, @unchecked Sendable {
    private let clipboardGuard: any ClipboardGuarding
    private let permissions: any PermissionsServicing
    private let pollIntervalNanoseconds: UInt64
    private let maxPolls: Int

    public init(
        clipboardGuard: any ClipboardGuarding = DefaultClipboardGuard(),
        permissions: any PermissionsServicing = DefaultPermissionsService(),
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        maxPolls: Int = 10
    ) {
        self.clipboardGuard = clipboardGuard
        self.permissions = permissions
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPolls = maxPolls
    }

    public func readSelection() async throws -> SelectionReadResult {
        guard await permissions.requestAccessibilityIfNeeded() else {
            return .permissionDenied
        }

        return try await clipboardGuard.preservingClipboard {
            let initialChangeCount = await MainActor.run {
                NSPasteboard.general.changeCount
            }

            await MainActor.run {
                sendCommandC()
            }

            for _ in 0 ..< maxPolls {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                let result = await MainActor.run {
                    currentCopiedString(after: initialChangeCount)
                }

                if let result {
                    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? .empty : .text(trimmed)
                }
            }

            return .empty
        }
    }
}

@MainActor
private func currentCopiedString(after changeCount: Int) -> String? {
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != changeCount else {
        return nil
    }
    return pasteboard.string(forType: .string)
}

@MainActor
private func sendCommandC() {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyCodeForC: CGKeyCode = 8

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForC, keyDown: true)
    keyDown?.flags = .maskCommand
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForC, keyDown: false)
    keyUp?.flags = .maskCommand

    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}
