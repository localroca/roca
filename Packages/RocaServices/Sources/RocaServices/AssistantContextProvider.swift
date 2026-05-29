@preconcurrency import ApplicationServices
import AppKit
import Foundation
import RocaCore

public protocol AssistantContextProviding: Sendable {
    func currentContext() async -> AssistantLocalContext
}

public final class DefaultAssistantContextProvider: AssistantContextProviding, @unchecked Sendable {
    public init() {}

    public func currentContext() async -> AssistantLocalContext {
        await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return AssistantLocalContext(
                activeAppName: app?.localizedName,
                activeAppBundleID: app?.bundleIdentifier,
                hasFocusedTextInput: focusedElementAcceptsText()
            )
        }
    }
}

@MainActor
private func focusedElementAcceptsText() -> Bool {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
          let focusedValue
    else {
        return false
    }

    let focusedElement = focusedValue as! AXUIElement
    var valueRef: CFTypeRef?
    return AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &valueRef) == .success
        && valueRef is String
}
