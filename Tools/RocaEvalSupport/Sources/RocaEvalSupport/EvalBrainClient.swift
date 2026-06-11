import Foundation
import RocaCore
import RocaProviders

public protocol EvalBrainClient: Sendable {
    func fetchModelNames() async throws -> [String]
    func complete(_ request: BrainRequest) async throws -> String
}

public final class OllamaEvalBrainClient: EvalBrainClient, @unchecked Sendable {
    public static let defaultRequestTimeoutSeconds: TimeInterval = 600

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
        if request.metadata[OllamaBrainProvider.requestTimeoutSecondsMetadataKey] == nil,
           requestTimeoutSeconds > 0,
           requestTimeoutSeconds.isFinite {
            request.metadata[OllamaBrainProvider.requestTimeoutSecondsMetadataKey] = "\(Int(requestTimeoutSeconds))"
        }
        let events = try await provider.complete(request)
        return try await Self.finalText(from: events)
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
