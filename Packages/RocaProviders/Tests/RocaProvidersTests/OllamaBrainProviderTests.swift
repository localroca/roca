import Foundation
import RocaCore
import RocaProviders
import Testing

@Test
func ollamaModelRecommendationPrefersChatLikeModels() {
    let models = [
        OllamaModel(name: "nomic-embed-text"),
        OllamaModel(name: "tiny-random"),
        OllamaModel(name: "qwen3:0.6b"),
        OllamaModel(name: "llama3.2:3b-instruct")
    ]

    #expect(OllamaBrainProvider.recommendedModel(from: models)?.name == "llama3.2:3b-instruct")
}

@Test
func ollamaModelRecommendationUsesAssistantEvalPolicy() {
    let models = [
        OllamaModel(name: "qwen3.5:4b-mlx"),
        OllamaModel(name: "qwen2.5-coder:7b"),
        OllamaModel(name: "mistral:7b"),
        OllamaModel(name: "qwen3:4b-instruct")
    ]

    #expect(OllamaBrainProvider.recommendedModel(from: models)?.name == "qwen3:4b-instruct")
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "qwen3:4b-instruct").status == .preferred
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "mistral:7b").status == .acceptable
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "qwen2.5-coder:7b").status == .discouraged
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "gemma4:12b").status == .discouraged
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "qwen3:4b-instruct", role: .companionRouter).status == .preferred
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "mistral:7b", role: .companionRouter).status == .acceptable
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "qwen2.5-coder:7b", role: .generalChat).status == .acceptable
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "qwen2.5-coder:7b", role: .companionRouter).status == .discouraged
    )
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "gemma4:12b", role: .generalChat).status == .discouraged
    )
}

@Test
func ollamaModelRecommendationPrefersUntestedModelsOverDiscouragedKnownModels() {
    let models = [
        OllamaModel(name: "qwen3:0.6b"),
        OllamaModel(name: "llama3.2:3b-instruct")
    ]

    #expect(OllamaBrainProvider.recommendedModel(from: models)?.name == "llama3.2:3b-instruct")
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "llama3.2:3b-instruct").status == .untested
    )
}

@Test
func ollamaModelRecommendationSortsModelsByProductFit() {
    let models = [
        OllamaModel(name: "qwen2.5-coder:7b"),
        OllamaModel(name: "llama3.2:3b-instruct"),
        OllamaModel(name: "nomic-embed-text"),
        OllamaModel(name: "mistral:7b"),
        OllamaModel(name: "qwen3:4b-instruct")
    ]

    let sortedNames = OllamaModelRecommendationPolicy.sortedModels(models).map(\.name)

    #expect(sortedNames == [
        "qwen3:4b-instruct",
        "mistral:7b",
        "llama3.2:3b-instruct",
        "qwen2.5-coder:7b",
        "nomic-embed-text"
    ])
    #expect(
        OllamaModelRecommendationPolicy.recommendation(for: "nomic-embed-text").status == .unsupported
    )
}

@Test
func ollamaModelRecommendationSelectableModelsHideUnsupportedModels() {
    let models = [
        OllamaModel(name: "nomic-embed-text"),
        OllamaModel(name: "mistral:7b")
    ]

    #expect(OllamaModelRecommendationPolicy.selectableModels(models).map(\.name) == ["mistral:7b"])
    #expect(OllamaModelRecommendationPolicy.isSelectable("mistral:7b"))
    #expect(!OllamaModelRecommendationPolicy.isSelectable("nomic-embed-text"))
}

@Test
func ollamaModelRecommendationUsesRoleSpecificEvidenceBeforeGeneralEvidence() {
    let evidence = [
        BrainModelRecommendationEvidence(
            modelID: "trial-model",
            totalRequests: 20,
            parseFailures: 0,
            responseFailures: 0,
            criticalRoutingFailures: 0,
            medianLatencyMilliseconds: 1_200,
            p95LatencyMilliseconds: 2_000
        ),
        BrainModelRecommendationEvidence(
            modelID: "trial-model",
            role: .companionRouter,
            totalRequests: 20,
            parseFailures: 0,
            responseFailures: 0,
            criticalRoutingFailures: 8,
            medianLatencyMilliseconds: 800,
            p95LatencyMilliseconds: 1_200
        )
    ]

    let routerRecommendation = OllamaModelRecommendationPolicy.recommendation(
        for: "trial-model",
        role: .companionRouter,
        evidence: evidence
    )
    let chatRecommendation = OllamaModelRecommendationPolicy.recommendation(
        for: "trial-model",
        role: .generalChat,
        evidence: evidence
    )

    #expect(routerRecommendation.status == .discouraged)
    #expect(chatRecommendation.status == .preferred)
    #expect(routerRecommendation.reason.contains("companion routing eval evidence"))
    #expect(chatRecommendation.reason.contains("general assistant eval evidence"))
}

@Test
func ollamaModelRecommendationSortsWithEvidence() {
    let models = [
        OllamaModel(name: "slow-model"),
        OllamaModel(name: "strong-router")
    ]
    let evidence = [
        BrainModelRecommendationEvidence(
            modelID: "slow-model",
            role: .companionRouter,
            totalRequests: 20,
            parseFailures: 0,
            responseFailures: 0,
            criticalRoutingFailures: 6,
            medianLatencyMilliseconds: 1_000,
            p95LatencyMilliseconds: 2_000
        ),
        BrainModelRecommendationEvidence(
            modelID: "strong-router",
            role: .companionRouter,
            totalRequests: 20,
            parseFailures: 0,
            responseFailures: 0,
            criticalRoutingFailures: 0,
            medianLatencyMilliseconds: 1_000,
            p95LatencyMilliseconds: 2_000
        )
    ]

    #expect(
        OllamaModelRecommendationPolicy.sortedModels(
            models,
            role: .companionRouter,
            evidence: evidence
        ).map(\.name) == ["strong-router", "slow-model"]
    )
}

@Test
func ollamaProviderFetchesModelsFromTagsEndpoint() async throws {
    MockURLProtocol.setHandler { request in
        #expect(request.url?.path == "/api/tags")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = """
        {
          "models": [
            {"name": "qwen3:0.6b", "size": 522000000},
            {"name": "llama3.2:3b", "size": 2000000000}
          ]
        }
        """.data(using: .utf8)!
        return (response, data)
    }
    defer {
        MockURLProtocol.setHandler(nil)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let provider = OllamaBrainProvider(baseURL: URL(string: "http://127.0.0.1:11434")!, session: session)

    let models = try await provider.fetchModels()

    #expect(models.map(\.name) == ["qwen3:0.6b", "llama3.2:3b"])
    #expect(models.first?.size == 522000000)
}

@Test
func ollamaProviderUsesNonStreamingChatResponses() async throws {
    MockChatURLProtocol.setHandler { request in
        #expect(request.url?.path == "/api/chat")
        let body = try #require(httpBodyData(from: request))
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "mistral:7b")
        #expect(json?["stream"] as? Bool == false)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = """
        {
          "message": {"role": "assistant", "content": "Ready."},
          "done": true
        }
        """.data(using: .utf8)!
        return (response, data)
    }
    defer {
        MockChatURLProtocol.setHandler(nil)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockChatURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let provider = OllamaBrainProvider(baseURL: URL(string: "http://127.0.0.1:11434")!, session: session)

    let stream = try await provider.complete(
        BrainRequest(
            requestID: BrainRequestID(rawValue: "request"),
            messages: [BrainMessage(role: .user, content: "hello")],
            role: .generalChat,
            modelID: "mistral:7b",
            context: RequestContext(selectedText: nil, activeAppBundleID: nil, activeAppName: nil, memoryIDs: [])
        )
    )

    let final = try await finalText(from: stream)
    #expect(final == "Ready.")
}

@Test
func ollamaProviderMapsChatTimeoutsToModelTimeouts() async throws {
    MockTimeoutChatURLProtocol.setHandler { request in
        #expect(request.timeoutInterval == 123)
        throw URLError(.timedOut)
    }
    defer {
        MockTimeoutChatURLProtocol.setHandler(nil)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockTimeoutChatURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let provider = OllamaBrainProvider(baseURL: URL(string: "http://127.0.0.1:11434")!, session: session)

    let stream = try await provider.complete(
        BrainRequest(
            requestID: BrainRequestID(rawValue: "request"),
            messages: [BrainMessage(role: .user, content: "hello")],
            role: .companionRouter,
            modelID: "gemma4:12b",
            context: RequestContext(selectedText: nil, activeAppBundleID: nil, activeAppName: nil, memoryIDs: []),
            metadata: [
                "responseFormat": "json",
                OllamaBrainProvider.requestTimeoutSecondsMetadataKey: "123"
            ]
        )
    )

    await #expect(throws: RocaError.providerTimedOut(providerID: BuiltInProviderIDs.ollamaBrain, modelID: "gemma4:12b")) {
        _ = try await finalText(from: stream)
    }
}

private func finalText(from events: AsyncThrowingStream<BrainEvent, Error>) async throws -> String {
    var text = ""
    for try await event in events {
        if case .final(let response) = event {
            text = response.text
        }
    }
    return text
}

private func httpBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }
    guard let bodyStream = request.httpBodyStream else {
        return nil
    }

    bodyStream.open()
    defer {
        bodyStream.close()
    }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
        buffer.deallocate()
    }

    while bodyStream.hasBytesAvailable {
        let read = bodyStream.read(buffer, maxLength: bufferSize)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = MockURLProtocolStorage()

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        storage.set(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.storage.handler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MockChatURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = MockURLProtocolStorage()

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        storage.set(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.storage.handler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MockTimeoutChatURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = MockURLProtocolStorage()

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        storage.set(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.storage.handler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MockURLProtocolStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    func set(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        value = handler
        lock.unlock()
    }

    func handler() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
