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
    public static let requestTimeoutSecondsMetadataKey = BrainRequestMetadataKeys.requestTimeoutSeconds
    public static let maxAutomaticContextWindow = 32_768

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
        let baseTimeout = Self.timeoutInterval(from: request.metadata, wantsJSON: wantsJSON)
        let urlRequest = try chatRequest(
            modelID: modelID,
            messages: request.messages,
            stream: false,
            wantsJSON: wantsJSON,
            timeoutInterval: baseTimeout
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { self.clearTask(request.requestID) }
                do {
                    continuation.yield(.started(requestID: request.requestID, providerID: self.id))
                    let response = try await self.completeChat(
                        urlRequest,
                        modelID: modelID,
                        messages: request.messages,
                        wantsJSON: wantsJSON,
                        baseTimeout: baseTimeout
                    )
                    continuation.yield(.final(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mappedCompletionError(error, providerID: self.id, modelID: modelID))
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
        try Self.validate(response, data: data)
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
        wantsJSON: Bool,
        timeoutInterval: TimeInterval,
        contextWindow: Int? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OllamaChatRequest(
            model: modelID,
            messages: messages.map { OllamaChatMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            format: wantsJSON ? "json" : nil,
            options: contextWindow.map { OllamaChatOptions(numContext: $0) }
        )
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func completeChat(
        _ request: URLRequest,
        modelID: String,
        messages: [BrainMessage],
        wantsJSON: Bool,
        baseTimeout: TimeInterval
    ) async throws -> BrainResponse {
        do {
            return try await performChat(request, modelID: modelID, metadata: ["model": modelID])
        } catch let overflow as OllamaContextOverflowError {
            guard let contextWindow = Self.retryContextWindow(for: overflow) else {
                throw overflow
            }
            let retryRequest = try chatRequest(
                modelID: modelID,
                messages: messages,
                stream: false,
                wantsJSON: wantsJSON,
                timeoutInterval: max(baseTimeout, 300),
                contextWindow: contextWindow
            )
            return try await performChat(
                retryRequest,
                modelID: modelID,
                metadata: [
                    "model": modelID,
                    "ollamaContextRetry": "true",
                    "ollamaPromptTokens": String(overflow.promptTokens),
                    "ollamaInitialContextWindow": String(overflow.contextWindow),
                    "ollamaRetriedContextWindow": String(contextWindow)
                ]
            )
        }
    }

    private func performChat(
        _ request: URLRequest,
        modelID: String,
        metadata: [String: String]
    ) async throws -> BrainResponse {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        let body = try decoder.decode(OllamaChatResponse.self, from: data)
        if let error = body.error {
            if let overflow = Self.contextOverflow(from: error) {
                throw overflow
            }
            throw RocaError.providerUnavailable(ProviderID(rawValue: "ollama: \(error)"))
        }
        let text = body.message?.content ?? ""
        return BrainResponse(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            usedProvider: id,
            metadata: metadata
        )
    }

    private static func timeoutInterval(from metadata: [String: String], wantsJSON: Bool) -> TimeInterval {
        if let rawTimeout = metadata[requestTimeoutSecondsMetadataKey],
           let timeout = TimeInterval(rawTimeout),
           timeout > 0,
           timeout.isFinite {
            return timeout
        }
        return wantsJSON ? 20 : 300
    }

    private static func retryContextWindow(for error: OllamaContextOverflowError) -> Int? {
        let reserve = 2_048
        let needed = error.promptTokens + reserve
        let candidates = [8_192, 16_384, maxAutomaticContextWindow]
        return candidates.first { $0 > error.contextWindow && $0 >= needed }
    }

    private static func mappedCompletionError(_ error: Error, providerID: ProviderID, modelID: String) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorTimedOut {
            return RocaError.providerTimedOut(providerID: providerID, modelID: modelID)
        }
        if let error = error as? OllamaHTTPError {
            return RocaError.providerUnavailable(ProviderID(rawValue: "ollama:http-\(error.statusCode)"))
        }
        if let error = error as? OllamaContextOverflowError {
            return RocaError.providerUnavailable(
                ProviderID(rawValue: "ollama:context-\(error.promptTokens)-over-\(error.contextWindow)")
            )
        }
        return error
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let error = ollamaErrorMessage(from: data),
               let overflow = contextOverflow(from: error) {
                throw overflow
            }
            throw OllamaHTTPError(statusCode: http.statusCode)
        }
    }

    private static func ollamaErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawError = object["error"] else {
            return nil
        }
        if let error = rawError as? String {
            return error
        }
        if let nested = rawError as? [String: Any],
           let message = nested["message"] as? String {
            return message
        }
        return nil
    }

    private static func contextOverflow(from error: String) -> OllamaContextOverflowError? {
        let message: String
        if let data = error.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let nestedError = object["error"] as? [String: Any],
           let nestedMessage = nestedError["message"] as? String {
            message = nestedMessage
            let promptTokens = nestedError["n_prompt_tokens"] as? Int
            let contextWindow = nestedError["n_ctx"] as? Int
            if let promptTokens, let contextWindow {
                return OllamaContextOverflowError(promptTokens: promptTokens, contextWindow: contextWindow)
            }
        } else {
            message = error
        }

        guard message.localizedCaseInsensitiveContains("exceeds the available context size") else {
            return nil
        }
        let numbers = message.matches(of: /\d+/).compactMap { Int($0.output) }
        guard numbers.count >= 2 else {
            return nil
        }
        return OllamaContextOverflowError(promptTokens: numbers[0], contextWindow: numbers[1])
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
    var options: OllamaChatOptions?
}

private struct OllamaChatOptions: Encodable {
    var numContext: Int

    enum CodingKeys: String, CodingKey {
        case numContext = "num_ctx"
    }
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

private struct OllamaHTTPError: Error {
    var statusCode: Int
}

private struct OllamaContextOverflowError: Error {
    var promptTokens: Int
    var contextWindow: Int
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
