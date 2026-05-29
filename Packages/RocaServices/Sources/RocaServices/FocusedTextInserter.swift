@preconcurrency import ApplicationServices
import AppKit
import Foundation
import RocaCore

public protocol FocusedTextInserting: Sendable {
    func insertIntoFocusedApp(_ text: String) async throws
}

public final class DefaultFocusedTextInserter: FocusedTextInserting, @unchecked Sendable {
    private let clipboardGuard: any ClipboardGuarding
    private let permissions: any PermissionsServicing
    private let pasteDelayNanoseconds: UInt64

    public init(
        clipboardGuard: any ClipboardGuarding = DefaultClipboardGuard(),
        permissions: any PermissionsServicing = DefaultPermissionsService(),
        pasteDelayNanoseconds: UInt64 = 120_000_000
    ) {
        self.clipboardGuard = clipboardGuard
        self.permissions = permissions
        self.pasteDelayNanoseconds = pasteDelayNanoseconds
    }

    public func insertIntoFocusedApp(_ text: String) async throws {
        guard await permissions.requestAccessibilityIfNeeded() else {
            throw RocaError.permission(.accessibility)
        }

        if await MainActor.run(body: { insertWithAccessibility(text) }) {
            return
        }

        try await pasteWithClipboardGuard(text)
    }

    private func pasteWithClipboardGuard(_ text: String) async throws {
        try await clipboardGuard.preservingClipboard {
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                sendCommandV()
            }
            try await Task.sleep(nanoseconds: pasteDelayNanoseconds)
        }
    }
}

@MainActor
private func insertWithAccessibility(_ text: String) -> Bool {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
          let focusedValue
    else {
        return false
    }

    let focusedElement = focusedValue as! AXUIElement
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &valueRef) == .success,
          let currentValue = valueRef as? String
    else {
        return false
    }

    var selectedRangeRef: CFTypeRef?
    var replacementRange = CFRange(location: currentValue.utf16.count, length: 0)
    if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
       let selectedRange = selectedRangeRef,
       CFGetTypeID(selectedRange) == AXValueGetTypeID() {
        var range = CFRange()
        if AXValueGetValue(selectedRange as! AXValue, .cfRange, &range) {
            replacementRange = range
        }
    }

    guard replacementRange.location >= 0,
          replacementRange.length >= 0,
          replacementRange.location + replacementRange.length <= currentValue.utf16.count,
          let lower = String.Index(
            currentValue.utf16.index(currentValue.utf16.startIndex, offsetBy: replacementRange.location),
            within: currentValue
          ),
          let upper = String.Index(
            currentValue.utf16.index(
                currentValue.utf16.startIndex,
                offsetBy: replacementRange.location + replacementRange.length
            ),
            within: currentValue
          )
    else {
        return false
    }

    var updated = currentValue
    updated.replaceSubrange(lower ..< upper, with: text)
    let status = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, updated as CFTypeRef)
    guard status == .success else {
        return false
    }

    let cursorLocation = replacementRange.location + text.utf16.count
    var newRange = CFRange(location: cursorLocation, length: 0)
    if let axRange = AXValueCreate(.cfRange, &newRange) {
        _ = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, axRange)
    }
    return true
}

@MainActor
private func sendCommandV() {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyCodeForV: CGKeyCode = 9

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
    keyDown?.flags = .maskCommand
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)
    keyUp?.flags = .maskCommand

    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}
