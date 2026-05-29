import Foundation

public protocol CompanionStateObserving: Sendable {
    var events: AsyncStream<CompanionStateEvent> { get }
}

public struct CompanionStateEvent: Equatable, Sendable {
    public var activity: RocaActivity
    public var message: String?
    public var source: CompanionEventSource
    public var correlationID: String?
    public var sensitivity: CompanionEventSensitivity
    public var timestamp: Date

    public init(
        activity: RocaActivity,
        message: String?,
        source: CompanionEventSource,
        correlationID: String?,
        sensitivity: CompanionEventSensitivity,
        timestamp: Date = Date()
    ) {
        self.activity = activity
        self.message = message
        self.source = source
        self.correlationID = correlationID
        self.sensitivity = sensitivity
        self.timestamp = timestamp
    }
}

public enum CompanionEventSource: String, Codable, Sendable {
    case app
    case tts
    case stt
    case assistant
    case brain
    case memory
    case permissions
}

public enum CompanionEventSensitivity: String, Codable, Sendable {
    case publicStatus
    case privateStatus
}

public actor CompanionStateCenter: CompanionStateObserving {
    private var continuations: [UUID: AsyncStream<CompanionStateEvent>.Continuation] = [:]

    public init() {}

    nonisolated public var events: AsyncStream<CompanionStateEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.addContinuation(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    public func emit(_ event: CompanionStateEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func addContinuation(_ continuation: AsyncStream<CompanionStateEvent>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
