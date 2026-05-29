import Foundation

public protocol SelectionReading: Sendable {
    func readSelection() async throws -> SelectionReadResult
}

public enum SelectionReadResult: Equatable, Sendable {
    case text(String)
    case empty
    case permissionDenied
    case failed(String)
}

public protocol ClipboardGuarding: Sendable {
    func preservingClipboard<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T
}
