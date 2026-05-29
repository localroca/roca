import Foundation
import RocaCore
import RocaEvalSupport
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
}

@Test
func evalModelSelectionParsesAllAndExplicitLists() {
    #expect(EvalModelSelection.parse("all") == .all)
    #expect(EvalModelSelection.parse("qwen3:4b,mistral:7b") == .names(["qwen3:4b", "mistral:7b"]))
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
            #"{"type":"respond"}"#,
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
    #expect(record.parsedDirective == .respond)
    #expect(record.bubbleText == "Short.")
    #expect(record.detailsMarkdown == "## Details\n- One")
    #expect(await client.requestRoles == [.companionRouter, .generalChat])
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
                medianLatencyMilliseconds: 12,
                    p95LatencyMilliseconds: 12
                )
            ]
        ),
        turns: [
            EvalTurnRecord(
                runID: "writer-test",
                suiteID: "assistant_quality_v1",
                modelID: "test-model",
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
                parsedDirective: .respond,
                directiveAppName: nil,
                directiveBundleID: nil,
                directiveText: nil,
                directiveMessage: nil,
                directiveRawText: #"{"type":"respond"}"#,
                directiveParseError: nil,
                dryRunAction: .none,
                responseRawText: #"{"bubbleText":"Hey."}"#,
                responseError: nil,
                bubbleText: "Hey.",
                detailsMarkdown: nil,
                directiveMilliseconds: 5,
                responseMilliseconds: 7,
                totalMilliseconds: 12,
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
    #expect(packet.contains("Hey Roca."))
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

    init(models: [String], responses: [String]) {
        self.models = models
        self.responses = responses
    }

    var requestRoles: [BrainRole?] {
        roles
    }

    func fetchModelNames() async throws -> [String] {
        models
    }

    func complete(_ request: BrainRequest) async throws -> String {
        roles.append(request.role)
        guard !responses.isEmpty else {
            return #"{"type":"respond"}"#
        }
        return responses.removeFirst()
    }
}
