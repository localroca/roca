import Foundation
import RocaCore

public struct InteractionEvalRunConfiguration: Sendable {
    public var suite: InteractionEvalSuite
    public var mode: InteractionEvalMode
    public var outputDirectory: URL
    public var runID: String
    public var modelID: String?
    public var baseURL: URL

    public init(
        suite: InteractionEvalSuite,
        mode: InteractionEvalMode,
        outputDirectory: URL,
        runID: String = EvalRunConfiguration.defaultRunID(),
        modelID: String? = nil,
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!
    ) {
        self.suite = suite
        self.mode = mode
        self.outputDirectory = outputDirectory
        self.runID = runID
        self.modelID = modelID
        self.baseURL = baseURL
    }
}

public enum InteractionEvalMode: String, Codable, Equatable, Sendable {
    case scripted
    case modelInLoop = "model-in-loop"
}

public struct InteractionEvalRunOutput: Sendable {
    public var run: InteractionEvalRunRecord
    public var turns: [InteractionEvalRecord]
    public var outputDirectory: URL

    public init(run: InteractionEvalRunRecord, turns: [InteractionEvalRecord], outputDirectory: URL) {
        self.run = run
        self.turns = turns
        self.outputDirectory = outputDirectory
    }

    public var failedTurns: [InteractionEvalRecord] {
        turns.filter { !$0.passed }
    }
}

public struct InteractionEvalRunRecord: Codable, Equatable, Sendable {
    public var runID: String
    public var suiteID: String
    public var suiteTitle: String
    public var startedAt: Date
    public var completedAt: Date
    public var mode: InteractionEvalMode
    public var modelID: String?
    public var scenarioCount: Int
    public var turnCount: Int
    public var passedTurnCount: Int
    public var failedTurnCount: Int
    public var expectedFailureCount: Int
    public var promptVersions: EvalPromptVersions

    public init(
        runID: String,
        suiteID: String,
        suiteTitle: String,
        startedAt: Date,
        completedAt: Date,
        mode: InteractionEvalMode,
        modelID: String?,
        scenarioCount: Int,
        turnCount: Int,
        passedTurnCount: Int,
        failedTurnCount: Int,
        expectedFailureCount: Int,
        promptVersions: EvalPromptVersions = EvalPromptVersions()
    ) {
        self.runID = runID
        self.suiteID = suiteID
        self.suiteTitle = suiteTitle
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.mode = mode
        self.modelID = modelID
        self.scenarioCount = scenarioCount
        self.turnCount = turnCount
        self.passedTurnCount = passedTurnCount
        self.failedTurnCount = failedTurnCount
        self.expectedFailureCount = expectedFailureCount
        self.promptVersions = promptVersions
    }
}

public struct InteractionEvalRecord: Codable, Equatable, Sendable {
    public var runID: String
    public var suiteID: String
    public var scenarioID: String
    public var scenarioTitle: String
    public var scenarioTags: [String]
    public var turnID: String
    public var turnIndex: Int
    public var userText: String
    public var inputMode: AssistantInputMode
    public var outputMode: AssistantOutputMode
    public var passed: Bool
    public var expectedFailureReason: String?
    public var failures: [String]
    public var messages: [ChatMessage]
    public var spokenTexts: [String]
    public var agentRequests: [InteractionAgentRequestRecord]
    public var projectWrites: [ProjectIdentity]
    public var diagnostics: [AssistantDiagnosticEvent]
    public var brainRequests: [InteractionBrainRequestRecord]

    public init(
        runID: String,
        suiteID: String,
        scenarioID: String,
        scenarioTitle: String,
        scenarioTags: [String],
        turnID: String,
        turnIndex: Int,
        userText: String,
        inputMode: AssistantInputMode,
        outputMode: AssistantOutputMode,
        passed: Bool,
        expectedFailureReason: String?,
        failures: [String],
        messages: [ChatMessage],
        spokenTexts: [String],
        agentRequests: [InteractionAgentRequestRecord],
        projectWrites: [ProjectIdentity],
        diagnostics: [AssistantDiagnosticEvent],
        brainRequests: [InteractionBrainRequestRecord]
    ) {
        self.runID = runID
        self.suiteID = suiteID
        self.scenarioID = scenarioID
        self.scenarioTitle = scenarioTitle
        self.scenarioTags = scenarioTags
        self.turnID = turnID
        self.turnIndex = turnIndex
        self.userText = userText
        self.inputMode = inputMode
        self.outputMode = outputMode
        self.passed = passed
        self.expectedFailureReason = expectedFailureReason
        self.failures = failures
        self.messages = messages
        self.spokenTexts = spokenTexts
        self.agentRequests = agentRequests
        self.projectWrites = projectWrites
        self.diagnostics = diagnostics
        self.brainRequests = brainRequests
    }
}

public struct InteractionAgentRequestRecord: Codable, Equatable, Sendable {
    public var providerID: String
    public var prompt: String
    public var mode: AgentMode
    public var workspacePath: String?
    public var metadata: [String: String]

    public init(_ request: AgentRunRequest, providerID: ProviderID) {
        self.providerID = providerID.rawValue
        self.prompt = request.prompt
        self.mode = request.mode
        self.workspacePath = request.workspacePath
        self.metadata = request.metadata
    }
}

public struct InteractionBrainRequestRecord: Codable, Equatable, Sendable {
    public var role: BrainRole?
    public var modelID: String?
    public var messages: [BrainMessage]

    public init(_ request: BrainRequest) {
        self.role = request.role
        self.modelID = request.modelID
        self.messages = request.messages
    }

    public static func == (lhs: InteractionBrainRequestRecord, rhs: InteractionBrainRequestRecord) -> Bool {
        lhs.role == rhs.role
            && lhs.modelID == rhs.modelID
            && lhs.messages.count == rhs.messages.count
            && zip(lhs.messages, rhs.messages).allSatisfy { left, right in
                left.role == right.role && left.content == right.content
            }
    }
}

public enum InteractionEvalResultWriter {
    public static func write(
        _ output: InteractionEvalRunOutput,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: output.outputDirectory, withIntermediateDirectories: true)

        try encoder.encode(output.run).write(
            to: output.outputDirectory.appendingPathComponent("interaction_run.json"),
            options: .atomic
        )

        let jsonl = try output.turns
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
            .appending("\n")
        try jsonl.write(
            to: output.outputDirectory.appendingPathComponent("interaction_transcripts.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        try report(for: output).write(
            to: output.outputDirectory.appendingPathComponent("interaction_report.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    public static func report(for output: InteractionEvalRunOutput) -> String {
        var lines: [String] = [
            "# Assistant Interaction Eval",
            "",
            "- Run: `\(output.run.runID)`",
            "- Suite: `\(output.run.suiteID)`",
            "- Mode: `\(output.run.mode.rawValue)`",
            "- Turns: \(output.run.turnCount)",
            "- Passed: \(output.run.passedTurnCount)",
            "- Failed: \(output.run.failedTurnCount)",
            "- Expected failures: \(output.run.expectedFailureCount)"
        ]
        if let modelID = output.run.modelID {
            lines.append("- Model: `\(modelID)`")
        }

        lines.append("")
        lines.append("## Turns")
        for record in output.turns {
            let marker = record.passed ? "PASS" : "FAIL"
            let expected = record.expectedFailureReason.map { " expected: \($0)" } ?? ""
            lines.append("")
            lines.append("### \(marker) \(record.scenarioID) / \(record.turnID)\(expected)")
            lines.append("")
            lines.append("User: \(record.userText)")
            if !record.failures.isEmpty {
                lines.append("")
                lines.append("Failures:")
                for failure in record.failures {
                    lines.append("- \(failure)")
                }
            }
            if let finalAssistant = record.messages.last(where: { $0.role == .assistant }) {
                lines.append("")
                lines.append("Final assistant: \(finalAssistant.text)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
