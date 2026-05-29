import AppKit
import Foundation
import RocaCore

public final class DefaultClipboardGuard: ClipboardGuarding, @unchecked Sendable {
    public init() {}

    public func preservingClipboard<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let snapshot = await MainActor.run {
            PasteboardSnapshot.capture(from: .general)
        }

        do {
            let result = try await operation()
            await MainActor.run {
                snapshot.restore(to: .general)
            }
            return result
        } catch {
            await MainActor.run {
                snapshot.restore(to: .general)
            }
            throw error
        }
    }
}

private struct PasteboardSnapshot: Sendable {
    var items: [PasteboardItemSnapshot]

    @MainActor
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let snapshots = (pasteboard.pasteboardItems ?? []).map { item in
            let values = item.types.compactMap { type -> PasteboardTypeSnapshot? in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return PasteboardTypeSnapshot(type: type.rawValue, data: data)
            }
            return PasteboardItemSnapshot(types: values)
        }
        return PasteboardSnapshot(items: snapshots)
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { snapshot in
            let item = NSPasteboardItem()
            for value in snapshot.types {
                item.setData(value.data, forType: NSPasteboard.PasteboardType(value.type))
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}

private struct PasteboardItemSnapshot: Sendable {
    var types: [PasteboardTypeSnapshot]
}

private struct PasteboardTypeSnapshot: Sendable {
    var type: String
    var data: Data
}
