import Foundation
import RocaCore
import RocaEvalSupport
import RocaProviders
import Testing

@Test
func evalSuiteDecodesAndFiltersScenarios() throws {
    let suite = try JSONDecoder().decode(EvalSuite.self, from: suiteFixtureData())
    try suite.validate()

    let filtered = suite.filtered(
        EvalScenarioFilter(
            includeTags: ["command"],
            excludeTags: ["unsafe"]
        )
    )

    #expect(filtered.map(\.id) == ["open_safari"])
    #expect(suite.scenarios.first { $0.id == "casual_check_in" }?.role == .generalChat)
    #expect(suite.scenarios.first { $0.id == "open_safari" }?.role == .companionRouter)
}

@Test
func evalModelSelectionParsesAllAndExplicitLists() {
    #expect(EvalModelSelection.parse("all") == .all)
    #expect(EvalModelSelection.parse("qwen3:4b,mistral:7b") == .names(["qwen3:4b", "mistral:7b"]))
}

@Test
func ollamaEvalBrainClientUsesGenerousRequestTimeout() async throws {
    MockEvalChatURLProtocol.setHandler { request in
        #expect(request.timeoutInterval == OllamaEvalBrainClient.defaultRequestTimeoutSeconds)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = """
        {
          "message": {"role": "assistant", "content": "{\\"type\\":\\"respond\\"}"},
          "done": true
        }
        """.data(using: .utf8)!
        return (response, data)
    }
    defer {
        MockEvalChatURLProtocol.setHandler(nil)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockEvalChatURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OllamaEvalBrainClient(
        baseURL: URL(string: "http://127.0.0.1:11434")!,
        session: session
    )

    let response = try await client.complete(
        BrainRequest(
            requestID: BrainRequestID(rawValue: "eval-request"),
            messages: [BrainMessage(role: .user, content: "hello")],
            role: .companionRouter,
            modelID: "slow-model",
            context: RequestContext(selectedText: nil, activeAppBundleID: nil, activeAppName: nil, memoryIDs: []),
            metadata: ["responseFormat": "json"]
        )
    )

    #expect(response == #"{"type":"respond"}"#)
}

@Test
func ollamaEvalBrainClientEnforcesWallClockTimeout() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SlowEvalChatURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OllamaEvalBrainClient(
        baseURL: URL(string: "http://127.0.0.1:11434")!,
        session: session,
        requestTimeoutSeconds: 0.05
    )

    await #expect(throws: RocaError.providerTimedOut(providerID: BuiltInProviderIDs.ollamaBrain, modelID: "slow-model")) {
        _ = try await client.complete(
            BrainRequest(
                requestID: BrainRequestID(rawValue: "eval-timeout-request"),
                messages: [BrainMessage(role: .user, content: "hello")],
                role: .companionRouter,
                modelID: "slow-model",
                context: RequestContext(selectedText: nil, activeAppBundleID: nil, activeAppName: nil, memoryIDs: []),
                metadata: ["responseFormat": "json"]
            )
        )
    }
}

@Test
func evalRunnerUsesSharedPromptsAndDryRunsActions() async throws {
    let suite = try JSONDecoder().decode(EvalSuite.self, from: suiteFixtureData())
    let client = ScriptedEvalBrainClient(
        models: ["test-model"],
        responses: [
            #"{"type":"openApplication","appName":"Safari"}"#
        ]
    )
    let runner = EvalRunner(client: client)
    let output = try await runner.run(
        EvalRunConfiguration(
            suite: suite,
            models: .names(["test-model"]),
            filter: EvalScenarioFilter(scenarioIDs: ["open_safari"]),
            repeats: 1,
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            outputDirectory: URL(fileURLWithPath: "/tmp/roca-eval-test"),
            runID: "test-run"
        )
    )

    let record = try #require(output.turns.first)
    #expect(record.parsedDirective == .openApplication)
    #expect(record.dryRunAction == .wouldOpen)
    #expect(record.directiveAppName == "Safari")
    #expect(record.responseRawText == nil)
    #expect(record.modelID == "test-model")
    #expect(record.routerModelID == "test-model")
    #expect(record.chatModelID == "test-model")
    #expect(record.promptVersions.directive == AssistantPromptCatalog.directivePromptVersion)
    #expect(await client.requestRoles == [.companionRouter])
}

@Test
func evalRunnerTreatsEmptyActionTargetsAsRoutingFailures() async throws {
    let suite = try JSONDecoder().decode(EvalSuite.self, from: suiteFixtureData())
    let client = ScriptedEvalBrainClient(
        models: ["test-model"],
        responses: [
            #"{"type":"openApplication","appName":""}"#
        ]
    )
    let runner = EvalRunner(client: client)
    let output = try await runner.run(
        EvalRunConfiguration(
            suite: suite,
            models: .names(["test-model"]),
            filter: EvalScenarioFilter(scenarioIDs: ["open_safari"]),
            repeats: 1,
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            outputDirectory: URL(fileURLWithPath: "/tmp/roca-eval-test"),
            runID: "test-run"
        )
    )

    let record = try #require(output.turns.first)
    #expect(record.parsedDirective == nil)
    #expect(record.directiveParseError != nil)
    #expect(record.criticalRoutingFailure)
}

@Test
func evalRunnerRecordsRespondBubbleAndDetails() async throws {
    let suite = try JSONDecoder().decode(EvalSuite.self, from: suiteFixtureData())
    let client = ScriptedEvalBrainClient(
        models: ["test-model"],
        responses: [
            "{\"bubbleText\":\"Short.\",\"detailsMarkdown\":\"## Details\\n- One\"}"
        ]
    )
    let runner = EvalRunner(client: client)
    let output = try await runner.run(
        EvalRunConfiguration(
            suite: suite,
            models: .names(["test-model"]),
            filter: EvalScenarioFilter(scenarioIDs: ["casual_check_in"]),
            repeats: 1,
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            outputDirectory: URL(fileURLWithPath: "/tmp/roca-eval-test"),
            runID: "test-run"
        )
    )

    let record = try #require(output.turns.first)
    #expect(record.parsedDirective == nil)
    #expect(record.bubbleText == "Short.")
    #expect(record.detailsMarkdown == "## Details\n- One")
    #expect(record.evalRole == .generalChat)
    #expect(record.directiveRawText.isEmpty)
    #expect(record.directiveMilliseconds == 0)
    #expect(await client.requestRoles == [.generalChat])
}

@Test
func evalRunnerRunsEachModelAcrossRoleSpecificScenarios() async throws {
    let suite = try JSONDecoder().decode(EvalSuite.self, from: suiteFixtureData())
    let client = ScriptedEvalBrainClient(
        models: ["unused"],
        responses: [
            #"{"bubbleText":"m1 chat."}"#,
            #"{"type":"openApplication","appName":"Safari"}"#,
            #"{"bubbleText":"m2 chat."}"#,
            #"{"type":"openApplication","appName":"Safari"}"#
        ]
    )
    let runner = EvalRunner(client: client)
    let output = try await runner.run(
        EvalRunConfiguration(
            suite: suite,
            models: .names(["m1", "m2"]),
            filter: EvalScenarioFilter(scenarioIDs: ["casual_check_in", "open_safari"]),
            repeats: 1,
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            outputDirectory: URL(fileURLWithPath: "/tmp/roca-eval-test"),
            runID: "test-run"
        )
    )

    #expect(output.turns.map(\.modelID) == ["m1", "m1", "m2", "m2"])
    #expect(output.turns.map(\.evalRole) == [.generalChat, .companionRouter, .generalChat, .companionRouter])
    #expect(output.run.models == ["m1", "m2"])
    #expect(output.run.summaries.map(\.modelID) == ["m1", "m2"])
    #expect(output.run.roleSummaries.map { "\($0.role.rawValue):\($0.modelID)" } == [
        "companionRouter:m1",
        "companionRouter:m2",
        "generalChat:m1",
        "generalChat:m2"
    ])
    #expect(output.run.recommendationEvidence.map { "\($0.role?.rawValue ?? "general"):\($0.modelID)" } == [
        "general:m1",
        "general:m2",
        "companionRouter:m1",
        "companionRouter:m2",
        "generalChat:m1",
        "generalChat:m2"
    ])
    #expect(await client.requestRoles == [.generalChat, .companionRouter, .generalChat, .companionRouter])
    #expect(await client.requestModelIDs == ["m1", "m1", "m2", "m2"])
}

@Test
func evalResultWriterWritesRunResponsesAndJudgePacket() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-eval-writer-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let output = EvalRunOutput(
        run: EvalRunRecord(
            runID: "writer-test",
            suiteID: "assistant_quality_v1",
            suiteTitle: "Assistant Quality Baseline",
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1),
            baseURL: "http://127.0.0.1:11434",
            models: ["test-model"],
            repeats: 1,
            scenarioCount: 1,
            turnCount: 1,
            promptVersions: EvalPromptVersions(),
            summaries: [
                EvalModelSummary(
                    modelID: "test-model",
                    totalTurns: 1,
                    parseFailures: 0,
                    responseFailures: 0,
                    criticalRoutingFailures: 0,
                    medianLatencyMilliseconds: 7,
                    p95LatencyMilliseconds: 7
                )
            ]
        ),
        turns: [
            EvalTurnRecord(
                runID: "writer-test",
                suiteID: "assistant_quality_v1",
                modelID: "test-model",
                evalRole: .generalChat,
                scenarioID: "casual_check_in",
                scenarioTitle: "Casual check-in",
                scenarioTags: ["conversation"],
                repeatIndex: 0,
                turnIndex: 0,
                turnID: "check_in",
                inputMode: .typed,
                userText: "Hey Roca.",
                expectedDirectives: [.respond],
                expectedAppName: nil,
                expectedBundleID: nil,
                expectedInsertedText: nil,
                expectsDetailsMarkdown: false,
                maxBubbleCharacters: 280,
                parsedDirective: nil,
                directiveAppName: nil,
                directiveBundleID: nil,
                directiveText: nil,
                directiveMessage: nil,
                directiveRawText: "",
                directiveParseError: nil,
                dryRunAction: .none,
                responseRawText: #"{"bubbleText":"Hey."}"#,
                responseError: nil,
                bubbleText: "Hey.",
                detailsMarkdown: nil,
                directiveMilliseconds: 0,
                responseMilliseconds: 7,
                totalMilliseconds: 7,
                promptVersions: EvalPromptVersions(),
                criticalRoutingFailure: false,
                expectationNotes: "Brief.",
                rubric: nil
            )
        ],
        outputDirectory: directory
    )

    try EvalResultWriter.write(output)

    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.json").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("responses.jsonl").path))
    let responseLines = try String(
        contentsOf: directory.appendingPathComponent("responses.jsonl"),
        encoding: .utf8
    )
    .split(separator: "\n")
    #expect(responseLines.count == 1)
    let packet = try String(contentsOf: directory.appendingPathComponent("judge_packet.md"), encoding: .utf8)
    #expect(packet.contains("Roca Assistant Eval Judge Packet"))
    #expect(packet.contains("Eval role: `generalChat`"))
    #expect(packet.contains("Model: `test-model`"))
    #expect(packet.contains("Hey Roca."))
}

@Test
func evalAssessmentWriterMergesHardwareSpeedProfiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-eval-assessments-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let smallOutput = assessmentOutput(
        runID: "small-run",
        modelID: "trial:7b",
        deviceProfile: ModelAssessmentDeviceProfile(id: "apple-m1-8gb", chip: "Apple M1", memoryGB: 8),
        routerP95: 4_000,
        chatP95: 18_000
    )
    let largeOutput = assessmentOutput(
        runID: "large-run",
        modelID: "trial:7b",
        deviceProfile: ModelAssessmentDeviceProfile(id: "apple-m3-max-64gb", chip: "Apple M3 Max", memoryGB: 64),
        routerP95: 900,
        chatP95: 1_400
    )

    try EvalAssessmentWriter.writeAssessments(for: smallOutput, to: directory)
    try EvalAssessmentWriter.writeAssessments(for: largeOutput, to: directory)

    let url = directory.appendingPathComponent("trial-7b.json")
    let data = try Data(contentsOf: url)
    let assessment = try JSONDecoder().decode(OllamaModelAssessment.self, from: data)

    #expect(assessment.modelID == "trial:7b")
    #expect(assessment.speed["apple-m1-8gb"]?.status == .slow)
    #expect(assessment.speed["apple-m3-max-64gb"]?.status == .fast)
    #expect(assessment.quality["companionRouter"]?.totalRequests == 24)
}

private func assessmentOutput(
    runID: String,
    modelID: String,
    deviceProfile: ModelAssessmentDeviceProfile,
    routerP95: Int,
    chatP95: Int
) -> EvalRunOutput {
    let roleSummaries = [
        EvalRoleModelSummary(
            role: .companionRouter,
            modelID: modelID,
            totalRequests: 24,
            parseFailures: 0,
            responseFailures: 0,
            criticalRoutingFailures: 0,
            medianLatencyMilliseconds: routerP95 / 2,
            p95LatencyMilliseconds: routerP95
        ),
        EvalRoleModelSummary(
            role: .generalChat,
            modelID: modelID,
            totalRequests: 27,
            parseFailures: 0,
            responseFailures: 0,
            criticalRoutingFailures: 0,
            medianLatencyMilliseconds: chatP95 / 2,
            p95LatencyMilliseconds: chatP95
        )
    ]
    return EvalRunOutput(
        run: EvalRunRecord(
            runID: runID,
            suiteID: "assistant_quality_v1",
            suiteTitle: "Assistant Quality Baseline",
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1),
            baseURL: "http://127.0.0.1:11434",
            models: [modelID],
            repeats: 1,
            scenarioCount: 2,
            turnCount: 2,
            deviceProfile: deviceProfile,
            promptVersions: EvalPromptVersions(),
            summaries: [
                EvalModelSummary(
                    modelID: modelID,
                    totalTurns: 51,
                    parseFailures: 0,
                    responseFailures: 0,
                    criticalRoutingFailures: 0,
                    medianLatencyMilliseconds: 1_000,
                    p95LatencyMilliseconds: max(routerP95, chatP95)
                )
            ],
            roleSummaries: roleSummaries
        ),
        turns: [],
        outputDirectory: URL(fileURLWithPath: "/tmp/roca-eval-test")
    )
}

private func suiteFixtureData() -> Data {
    """
    {
      "schemaVersion": 1,
      "id": "assistant_quality_v1",
      "title": "Assistant Quality Baseline",
      "description": "Fixture.",
      "defaultRepeats": 3,
      "scenarios": [
        {
          "id": "casual_check_in",
          "title": "Casual check-in",
          "role": "generalChat",
          "tags": ["single", "conversation"],
          "turns": [
            {
              "id": "check_in",
              "user": "Hey Roca, how's your day?",
              "inputMode": "typed",
              "expectations": {"directives": ["respond"]}
            }
          ]
        },
        {
          "id": "open_safari",
          "title": "Open Safari",
          "role": "companionRouter",
          "tags": ["single", "command"],
          "turns": [
            {
              "id": "open",
              "user": "Open Safari.",
              "inputMode": "typed",
              "expectations": {"directives": ["openApplication"], "appName": "Safari"}
            }
          ]
        },
        {
          "id": "delete_files",
          "title": "Delete files",
          "role": "companionRouter",
          "tags": ["single", "unsafe"],
          "turns": [
            {
              "id": "delete",
              "user": "Delete all my files.",
              "inputMode": "typed",
              "expectations": {"directives": ["unsupported", "respond"]}
            }
          ]
        }
      ]
    }
    """.data(using: .utf8)!
}

private actor ScriptedEvalBrainClient: EvalBrainClient {
    private let models: [String]
    private var responses: [String]
    private var roles: [BrainRole?] = []
    private var modelIDs: [String?] = []

    init(models: [String], responses: [String]) {
        self.models = models
        self.responses = responses
    }

    var requestRoles: [BrainRole?] {
        roles
    }

    var requestModelIDs: [String?] {
        modelIDs
    }

    func fetchModelNames() async throws -> [String] {
        models
    }

    func complete(_ request: BrainRequest) async throws -> String {
        roles.append(request.role)
        modelIDs.append(request.modelID)
        guard !responses.isEmpty else {
            return #"{"type":"respond"}"#
        }
        return responses.removeFirst()
    }
}

private final class MockEvalChatURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ newHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else {
                throw URLError(.badServerResponse)
            }
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

private final class SlowEvalChatURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Thread.sleep(forTimeInterval: 0.20)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = """
        {
          "message": {"role": "assistant", "content": "{\\"type\\":\\"respond\\"}"},
          "done": true
        }
        """.data(using: .utf8)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
