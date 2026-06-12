import Foundation
import RocaCore
import RocaProviders

public protocol EvalBrainClient: Sendable {
    func fetchModelNames() async throws -> [String]
    func complete(_ request: BrainRequest) async throws -> String
}

public final class OllamaEvalBrainClient: EvalBrainClient, @unchecked Sendable {
    public static let defaultRequestTimeoutSeconds: TimeInterval = 300

    private let provider: OllamaBrainProvider
    private let requestTimeoutSeconds: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared,
        requestTimeoutSeconds: TimeInterval = OllamaEvalBrainClient.defaultRequestTimeoutSeconds
    ) {
        self.provider = OllamaBrainProvider(baseURL: baseURL, session: session)
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public func fetchModelNames() async throws -> [String] {
        let models = try await provider.fetchModels()
        return models.map(\.name)
    }

    public func complete(_ request: BrainRequest) async throws -> String {
        var request = request
        let timeoutSeconds = Self.timeoutSeconds(
            from: request.metadata[OllamaBrainProvider.requestTimeoutSecondsMetadataKey],
            fallback: requestTimeoutSeconds
        )
        if request.metadata[OllamaBrainProvider.requestTimeoutSecondsMetadataKey] == nil,
           requestTimeoutSeconds > 0,
           requestTimeoutSeconds.isFinite {
            request.metadata[OllamaBrainProvider.requestTimeoutSecondsMetadataKey] = "\(requestTimeoutSeconds)"
        }
        let provider = self.provider
        let requestID = request.requestID
        let events = try await provider.complete(request)
        do {
            return try await Self.withWallClockTimeout(
                seconds: timeoutSeconds,
                onTimeout: { await provider.cancel(requestID) },
                operation: { try await Self.finalText(from: events) }
            )
        } catch is EvalRequestTimedOut {
            throw RocaError.providerTimedOut(
                providerID: provider.id,
                modelID: request.modelID ?? "unknown"
            )
        }
    }

    private static func finalText(from events: AsyncThrowingStream<BrainEvent, Error>) async throws -> String {
        var accumulated = ""
        var finalText: String?
        for try await event in events {
            switch event {
            case .started:
                continue
            case .textDelta(let delta):
                accumulated += delta
            case .final(let response):
                finalText = response.text
            case .cancelled:
                throw RocaError.cancelled
            }
        }
        return (finalText ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func withWallClockTimeout<T: Sendable>(
        seconds: TimeInterval?,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let seconds, seconds > 0, seconds.isFinite else {
            return try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer {
                group.cancelAll()
            }
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds(for: seconds))
                await onTimeout()
                throw EvalRequestTimedOut()
            }
            guard let result = try await group.next() else {
                throw RocaError.cancelled
            }
            return result
        }
    }

    private static func timeoutSeconds(from rawValue: String?, fallback: TimeInterval) -> TimeInterval? {
        if let rawValue,
           let seconds = TimeInterval(rawValue),
           seconds > 0,
           seconds.isFinite {
            return seconds
        }
        guard fallback > 0, fallback.isFinite else {
            return nil
        }
        return fallback
    }

    private static func timeoutNanoseconds(for seconds: TimeInterval) -> UInt64 {
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(nanoseconds.rounded(.up))
    }

    private struct EvalRequestTimedOut: Error {}
}

public enum EvalModelSelection: Equatable, Sendable {
    case all
    case names([String])

    public static func parse(_ rawValue: String) -> EvalModelSelection {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "all" {
            return .all
        }
        let names = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? .all : .names(names)
    }
}
