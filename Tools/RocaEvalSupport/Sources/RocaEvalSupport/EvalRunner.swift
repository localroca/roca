import Foundation
import RocaCore
import RocaProviders

public struct EvalRunConfiguration: Equatable, Sendable {
    public var suite: EvalSuite
    public var models: EvalModelSelection
    public var filter: EvalScenarioFilter
    public var repeats: Int?
    public var baseURL: URL
    public var outputDirectory: URL
    public var runID: String

    public init(
        suite: EvalSuite,
        models: EvalModelSelection,
        filter: EvalScenarioFilter,
        repeats: Int?,
        baseURL: URL,
        outputDirectory: URL,
        runID: String = EvalRunConfiguration.defaultRunID()
    ) {
        self.suite = suite
        self.models = models
        self.filter = filter
        self.repeats = repeats
        self.baseURL = baseURL
        self.outputDirectory = outputDirectory
        self.runID = runID
    }

    public static func defaultRunID(date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
            .string(from: date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "T", with: "-")
            .replacingOccurrences(of: "Z", with: "Z")
    }
}

public struct EvalRunner: Sendable {
    private let client: any EvalBrainClient

    public init(client: any EvalBrainClient) {
        self.client = client
    }

    public func run(_ configuration: EvalRunConfiguration) async throws -> EvalRunOutput {
        let startedAt = Date()
        let deviceProfile = ModelAssessmentDeviceProfile.current()
        let models = try await resolveModels(configuration.models)
        guard !models.isEmpty else {
            throw EvalError.noModels
        }
        let scenarios = configuration.suite.filtered(configuration.filter)
        guard !scenarios.isEmpty else {
            throw EvalError.noScenarios
        }

        let repeats = configuration.repeats ?? configuration.suite.defaultRepeats
        guard repeats > 0 else {
            throw EvalError.invalidArguments("Repeats must be greater than zero.")
        }

        var records: [EvalTurnRecord] = []
        for modelID in models {
            for scenario in scenarios {
                for repeatIndex in 0 ..< repeats {
                    var conversationMessages: [BrainMessage] = []
                    for (turnIndex, turn) in scenario.turns.enumerated() {
                        let record = try await runTurn(
                            suite: configuration.suite,
                            scenario: scenario,
                            turn: turn,
                            turnIndex: turnIndex,
                            repeatIndex: repeatIndex,
                            modelID: modelID,
                            runID: configuration.runID,
                            conversationMessages: &conversationMessages
                        )
                        records.append(record)
                    }
                }
            }
        }

        let summaries = models.map { modelID in
            makeSummary(modelID: modelID, records: records.filter { $0.modelID == modelID })
        }
        let run = EvalRunRecord(
            runID: configuration.runID,
            suiteID: configuration.suite.id,
            suiteTitle: configuration.suite.title,
            startedAt: startedAt,
            completedAt: Date(),
            baseURL: configuration.baseURL.absoluteString,
            models: models,
            repeats: repeats,
            scenarioCount: scenarios.count,
            turnCount: records.count,
            deviceProfile: deviceProfile,
            promptVersions: EvalPromptVersions(),
            summaries: summaries,
            roleSummaries: makeRoleSummaries(records: records)
        )
        return EvalRunOutput(run: run, turns: records, outputDirectory: configuration.outputDirectory)
    }

    private func resolveModels(_ selection: EvalModelSelection) async throws -> [String] {
        let models: [String]
        switch selection {
        case .all:
            models = try await client.fetchModelNames()
        case .names(let names):
            models = names
        }
        return unique(models)
    }

    private func runTurn(
        suite: EvalSuite,
        scenario: EvalScenario,
        turn: EvalTurn,
        turnIndex: Int,
        repeatIndex: Int,
        modelID: String,
        runID: String,
        conversationMessages: inout [BrainMessage]
    ) async throws -> EvalTurnRecord {
        let context = turn.context ?? AssistantLocalContext(
            activeAppName: "RocaEval",
            activeAppBundleID: "ai.roca.eval",
            hasFocusedTextInput: true
        )
        let requestID = BrainRequestID(rawValue: "\(runID)-\(modelID)-\(scenario.role.rawValue)-\(scenario.id)-\(repeatIndex)-\(turnIndex)")
        var directiveRawText = ""
        var directiveParseError: String?
        var parsedDirective: AssistantDirective?
        var directiveMilliseconds = 0
        if scenario.role == .companionRouter {
            let directiveStartedAt = Date()
            do {
                directiveRawText = try await client.complete(
                    BrainRequest(
                        requestID: requestID,
                        messages: [
                            BrainMessage(role: .system, content: AssistantPromptCatalog.directiveSystemPrompt),
                            BrainMessage(
                                role: .user,
                                content: AssistantPromptCatalog.directiveUserPrompt(input: turn.user, context: context)
                            )
                        ],
                        role: .companionRouter,
                        modelID: modelID,
                        context: RequestContext(
                            selectedText: nil,
                            activeAppBundleID: context.activeAppBundleID,
                            activeAppName: context.activeAppName,
                            memoryIDs: []
                        ),
                        metadata: ["responseFormat": "json"]
                    )
                )
                parsedDirective = try AssistantPromptCatalog.parseDirective(directiveRawText)
            } catch {
                directiveParseError = error.localizedDescription
            }
            directiveMilliseconds = milliseconds(since: directiveStartedAt)
        }

        let responseStartedAt = Date()
        var responseRawText: String?
        var responseError: String?
        var responseContent: AssistantResponseContent?
        var responseMilliseconds: Int?
        let dryRunAction = dryRunAction(for: parsedDirective)

        if scenario.role == .generalChat {
            do {
                responseRawText = try await client.complete(
                    BrainRequest(
                        requestID: requestID,
                        messages: responseMessages(turn: turn, conversationMessages: conversationMessages),
                        role: .generalChat,
                        modelID: modelID,
                        context: RequestContext(
                            selectedText: nil,
                            activeAppBundleID: context.activeAppBundleID,
                            activeAppName: context.activeAppName,
                            memoryIDs: []
                        ),
                        metadata: ["responseFormat": "json"]
                    )
                )
                responseContent = AssistantPromptCatalog.parseAssistantResponse(responseRawText ?? "")
                if let responseContent {
                    remember(userText: turn.user, assistantText: responseContent.conversationText, in: &conversationMessages)
                }
            } catch {
                responseError = error.localizedDescription
            }
            responseMilliseconds = milliseconds(since: responseStartedAt)
        } else if case .unsupported(let message) = parsedDirective {
            responseContent = AssistantResponseContent(bubbleText: message, detailsMarkdown: nil)
            responseMilliseconds = nil
        }

        return EvalTurnRecord(
            runID: runID,
            suiteID: suite.id,
            modelID: modelID,
            evalRole: scenario.role,
            routerModelID: modelID,
            chatModelID: modelID,
            scenarioID: scenario.id,
            scenarioTitle: scenario.title,
            scenarioTags: scenario.tags,
            repeatIndex: repeatIndex,
            turnIndex: turnIndex,
            turnID: turn.id,
            inputMode: turn.inputMode,
            userText: turn.user,
            expectedDirectives: turn.expectations?.directives ?? [],
            expectedAppName: turn.expectations?.appName,
            expectedBundleID: turn.expectations?.bundleID,
            expectedInsertedText: turn.expectations?.insertedText,
            expectsDetailsMarkdown: turn.expectations?.expectsDetailsMarkdown,
            maxBubbleCharacters: turn.expectations?.maxBubbleCharacters,
            parsedDirective: parsedDirective?.directiveType,
            directiveAppName: parsedDirective?.appName,
            directiveBundleID: parsedDirective?.bundleID,
            directiveText: parsedDirective?.text,
            directiveMessage: parsedDirective?.message,
            directiveRawText: directiveRawText,
            directiveParseError: directiveParseError,
            dryRunAction: dryRunAction,
            responseRawText: responseRawText,
            responseError: responseError,
            bubbleText: responseContent?.bubbleText,
            detailsMarkdown: responseContent?.detailsMarkdown,
            directiveMilliseconds: directiveMilliseconds,
            responseMilliseconds: responseMilliseconds,
            totalMilliseconds: directiveMilliseconds + (responseMilliseconds ?? 0),
            promptVersions: EvalPromptVersions(),
            criticalRoutingFailure: scenario.role == .companionRouter
                ? criticalRoutingFailure(for: parsedDirective, turn: turn, parseError: directiveParseError)
                : false,
            expectationNotes: turn.expectations?.notes,
            rubric: turn.rubric
        )
    }

    private func responseMessages(turn: EvalTurn, conversationMessages: [BrainMessage]) -> [BrainMessage] {
        var messages = [
            BrainMessage(role: .system, content: AssistantPromptCatalog.responseSystemPrompt(for: turn.inputMode))
        ]
        messages.append(contentsOf: conversationMessages)
        messages.append(BrainMessage(role: .user, content: turn.user))
        return messages
    }

    private func remember(userText: String, assistantText: String, in messages: inout [BrainMessage]) {
        messages.append(BrainMessage(role: .user, content: userText))
        messages.append(BrainMessage(role: .assistant, content: assistantText))
        if messages.count > 10 {
            messages.removeFirst(messages.count - 10)
        }
    }

    private func dryRunAction(for directive: AssistantDirective?) -> EvalDryRunAction {
        guard let directive else {
            return .none
        }
        switch directive {
        case .respond:
            return .none
        case .openApplication:
            return .wouldOpen
        case .quitApplication:
            return .wouldQuit
        case .insertText:
            return .wouldInsert
        case .readSelection:
            return .wouldReadSelection
        case .unsupported:
            return .wouldRefuseUnsupported
        }
    }

    private func criticalRoutingFailure(
        for directive: AssistantDirective?,
        turn: EvalTurn,
        parseError: String?
    ) -> Bool {
        if parseError != nil {
            return true
        }
        guard let expectations = turn.expectations,
              !expectations.directives.isEmpty,
              let directive
        else {
            return false
        }
        guard expectations.directives.contains(directive.directiveType) else {
            return true
        }
        if let appName = expectations.appName, !matches(directive.appName, appName) {
            return true
        }
        if let bundleID = expectations.bundleID, !matches(directive.bundleID, bundleID) {
            return true
        }
        if let insertedText = expectations.insertedText, directive.text != insertedText {
            return true
        }
        return false
    }

    private func matches(_ actual: String?, _ expected: String) -> Bool {
        guard let actual = actual?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actual.isEmpty
        else {
            return false
        }
        let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else {
            return false
        }
        return actual.localizedCaseInsensitiveContains(expected)
            || expected.localizedCaseInsensitiveContains(actual)
    }

    private func makeSummary(modelID: String, records: [EvalTurnRecord]) -> EvalModelSummary {
        let latencies = records.map(\.totalMilliseconds).sorted()
        return EvalModelSummary(
            modelID: modelID,
            totalTurns: records.count,
            parseFailures: records.filter { $0.directiveParseError != nil }.count,
            responseFailures: records.filter { $0.responseError != nil }.count,
            criticalRoutingFailures: records.filter(\.criticalRoutingFailure).count,
            medianLatencyMilliseconds: percentile(0.5, in: latencies),
            p95LatencyMilliseconds: percentile(0.95, in: latencies)
        )
    }

    private func makeRoleSummaries(records: [EvalTurnRecord]) -> [EvalRoleModelSummary] {
        let grouped = Dictionary(grouping: records) { record in
            RoleModelKey(role: record.evalRole, modelID: record.modelID)
        }
        return grouped.map { key, records in
            let latencies: [Int]
            switch key.role {
            case .companionRouter:
                latencies = records.map(\.directiveMilliseconds).sorted()
            case .generalChat:
                latencies = records.compactMap(\.responseMilliseconds).sorted()
            default:
                latencies = records.map(\.totalMilliseconds).sorted()
            }
            return EvalRoleModelSummary(
                role: key.role,
                modelID: key.modelID,
                totalRequests: records.count,
                parseFailures: records.filter { $0.directiveParseError != nil }.count,
                responseFailures: records.filter { $0.responseError != nil }.count,
                criticalRoutingFailures: records.filter(\.criticalRoutingFailure).count,
                medianLatencyMilliseconds: percentile(0.5, in: latencies),
                p95LatencyMilliseconds: percentile(0.95, in: latencies)
            )
        }.sorted {
            if $0.role.rawValue != $1.role.rawValue {
                return $0.role.rawValue < $1.role.rawValue
            }
            return $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard seen.insert(value).inserted else {
                continue
            }
            result.append(value)
        }
        return result
    }

    private func percentile(_ percentile: Double, in values: [Int]) -> Int? {
        guard !values.isEmpty else {
            return nil
        }
        let clamped = max(0, min(1, percentile))
        let index = Int((Double(values.count - 1) * clamped).rounded(.up))
        return values[index]
    }

    private func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private struct RoleModelKey: Hashable {
        var role: BrainRole
        var modelID: String
    }
}

private extension AssistantDirective {
    var directiveType: AssistantDirectiveType {
        switch self {
        case .respond:
            .respond
        case .openApplication:
            .openApplication
        case .quitApplication:
            .quitApplication
        case .insertText:
            .insertText
        case .readSelection:
            .readSelection
        case .unsupported:
            .unsupported
        }
    }

    var appName: String? {
        switch self {
        case .openApplication(let target), .quitApplication(let target):
            target.appName
        default:
            nil
        }
    }

    var bundleID: String? {
        switch self {
        case .openApplication(let target), .quitApplication(let target):
            target.bundleID
        default:
            nil
        }
    }

    var text: String? {
        if case .insertText(let text) = self {
            return text
        }
        return nil
    }

    var message: String? {
        if case .unsupported(let message) = self {
            return message
        }
        return nil
    }
}
