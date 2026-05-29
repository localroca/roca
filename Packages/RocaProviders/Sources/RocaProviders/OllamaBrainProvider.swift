import Foundation
import RocaCore

public enum OllamaDiscoveryState: Equatable, Sendable {
    case ready(models: [OllamaModel])
    case runningWithoutModels
    case installedNotRunning(appURL: URL)
    case unavailable

    public var models: [OllamaModel] {
        if case .ready(let models) = self {
            return models
        }
        return []
    }
}

public struct OllamaModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var size: Int64?

    public init(name: String, displayName: String? = nil, size: Int64? = nil) {
        self.name = name
        self.displayName = displayName ?? name
        self.size = size
    }
}

public final class OllamaBrainProvider: BrainProvider, @unchecked Sendable {
    public let id = BuiltInProviderIDs.ollamaBrain
    public let displayName = "Ollama"
    public let capabilities = BrainCapabilities(
        supportsStreaming: true,
        supportsToolCalls: false,
        supportsLocalExecution: true,
        locality: .local
    )

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private var activeTasks: [BrainRequestID: Task<Void, Never>] = [:]

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func prepare() async throws {
        _ = try await fetchModels()
    }

    public func complete(_ request: BrainRequest) async throws -> AsyncThrowingStream<BrainEvent, Error> {
        guard let modelID = request.modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty
        else {
            throw RocaError.providerUnavailable(id)
        }

        let wantsJSON = request.metadata["responseFormat"] == "json"
        let urlRequest = try chatRequest(
            modelID: modelID,
            messages: request.messages,
            stream: false,
            wantsJSON: wantsJSON
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { self.clearTask(request.requestID) }
                do {
                    continuation.yield(.started(requestID: request.requestID, providerID: self.id))
                    let (data, response) = try await self.session.data(for: urlRequest)
                    try Self.validate(response)
                    let body = try self.decoder.decode(OllamaChatResponse.self, from: data)
                    if let error = body.error {
                        throw RocaError.providerUnavailable(ProviderID(rawValue: "ollama: \(error)"))
                    }
                    let text = body.message?.content ?? ""
                    continuation.yield(
                        .final(
                            BrainResponse(
                                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                usedProvider: self.id,
                                metadata: ["model": modelID]
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.setTask(task, for: request.requestID)
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                self.clearTask(request.requestID)
            }
        }
    }

    public func cancel(_ requestID: BrainRequestID) async {
        let task = lock.withLock {
            activeTasks.removeValue(forKey: requestID)
        }
        task?.cancel()
    }

    public func fetchModels() async throws -> [OllamaModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let tags = try decoder.decode(OllamaTagsResponse.self, from: data)
        return tags.models.map { model in
            OllamaModel(name: model.name, displayName: model.name, size: model.size)
        }
    }

    public static func discover(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) async -> OllamaDiscoveryState {
        let provider = OllamaBrainProvider(baseURL: baseURL, session: session)
        do {
            let models = try await provider.fetchModels()
            return models.isEmpty ? .runningWithoutModels : .ready(models: models)
        } catch {
            if let appURL = installedOllamaAppURL(fileManager: fileManager) {
                return .installedNotRunning(appURL: appURL)
            }
            return .unavailable
        }
    }

    public static func recommendedModel(from models: [OllamaModel]) -> OllamaModel? {
        OllamaModelRecommendationPolicy.recommendedModel(from: models, role: .companionRouter)
    }

    private func chatRequest(
        modelID: String,
        messages: [BrainMessage],
        stream: Bool,
        wantsJSON: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = wantsJSON ? 20 : 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OllamaChatRequest(
            model: modelID,
            messages: messages.map { OllamaChatMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            format: wantsJSON ? "json" : nil
        )
        request.httpBody = try encoder.encode(body)
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw RocaError.providerUnavailable(ProviderID(rawValue: "ollama:http-\(http.statusCode)"))
        }
    }

    private static func installedOllamaAppURL(fileManager: FileManager) -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("Ollama.app", isDirectory: true)
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func setTask(_ task: Task<Void, Never>, for requestID: BrainRequestID) {
        lock.withLock {
            activeTasks[requestID]?.cancel()
            activeTasks[requestID] = task
        }
    }

    private func clearTask(_ requestID: BrainRequestID) {
        _ = lock.withLock {
            activeTasks.removeValue(forKey: requestID)
        }
    }
}

private struct OllamaTagsResponse: Decodable {
    var models: [OllamaTagModel]
}

private struct OllamaTagModel: Decodable {
    var name: String
    var size: Int64?
}

private struct OllamaChatRequest: Encodable {
    var model: String
    var messages: [OllamaChatMessage]
    var stream: Bool
    var format: String?
}

private struct OllamaChatMessage: Codable {
    var role: String
    var content: String
}

private struct OllamaChatResponse: Decodable {
    var message: OllamaChatMessage?
    var done: Bool?
    var error: String?
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
