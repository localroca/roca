import Carbon.HIToolbox
import Foundation
import RocaCore

@MainActor
final class HotkeyController {
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let talkAction: @MainActor () -> Void

    init(talkAction: @escaping @MainActor () -> Void) {
        self.talkAction = talkAction
    }

    func registerHotkey(_ definition: HotkeyDefinition) throws {
        unregister()
        try installEventHandler()
        try register(definition, id: Self.talkHotKeyID)
    }

    private func installEventHandler() throws {
        guard eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == HotkeyController.signature else {
                    return noErr
                }

                let controller = Unmanaged<HotkeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    if hotKeyID.id == HotkeyController.talkHotKeyID {
                        controller.talkAction()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            throw HotkeyRegistrationError.operationFailed("InstallEventHandler", handlerStatus)
        }
    }

    private func register(_ definition: HotkeyDefinition, id: UInt32) throws {
        let keyCode = try Self.keyCode(for: definition.key)
        let modifierFlags = try Self.modifierFlags(for: definition.modifiers)

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: id
        )

        var hotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw HotkeyRegistrationError.operationFailed("RegisterEventHotKey", registerStatus)
        }
        hotKeyRefs[id] = hotKeyRef
    }

    private func unregister() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private static let signature = fourCharacterCode("ROCA")
    private static let talkHotKeyID: UInt32 = 1

    private static func keyCode(for key: String) throws -> UInt32 {
        switch key.uppercased() {
        case "K":
            UInt32(kVK_ANSI_K)
        default:
            throw HotkeyRegistrationError.unsupportedKey(key)
        }
    }

    private static func modifierFlags(for modifiers: [String]) throws -> UInt32 {
        var flags = UInt32(0)
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "command":
                flags |= UInt32(cmdKey)
            case "option":
                flags |= UInt32(optionKey)
            case "control":
                flags |= UInt32(controlKey)
            case "shift":
                flags |= UInt32(shiftKey)
            default:
                throw HotkeyRegistrationError.unsupportedModifier(modifier)
            }
        }
        return flags
    }
}

private enum HotkeyRegistrationError: LocalizedError {
    case unsupportedKey(String)
    case unsupportedModifier(String)
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedKey(let key):
            "Hotkey unavailable: unsupported key \(key)."
        case .unsupportedModifier(let modifier):
            "Hotkey unavailable: unsupported modifier \(modifier)."
        case .operationFailed(let operation, let status):
            "Hotkey unavailable: \(operation) failed with status \(status)."
        }
    }
}

private func fourCharacterCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(UInt32(0)) { result, character in
        (result << 8) + UInt32(character)
    }
}
