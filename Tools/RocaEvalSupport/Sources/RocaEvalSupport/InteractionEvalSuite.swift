import Foundation
import RocaCore

public struct InteractionEvalSuite: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var description: String
    public var scenarios: [InteractionEvalScenario]

    public init(
        schemaVersion: Int,
        id: String,
        title: String,
        description: String,
        scenarios: [InteractionEvalScenario]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.description = description
        self.scenarios = scenarios
    }

    public static func load(from url: URL) throws -> InteractionEvalSuite {
        let data = try Data(contentsOf: url)
        let suite = try JSONDecoder().decode(InteractionEvalSuite.self, from: data)
        try suite.validate()
        return suite
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw EvalError.invalidSuite("Unsupported interaction suite schema version \(schemaVersion).")
        }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvalError.invalidSuite("Interaction suite id is required.")
        }
        guard !scenarios.isEmpty else {
            throw EvalError.invalidSuite("Interaction suite must contain at least one scenario.")
        }

        var scenarioIDs = Set<String>()
        for scenario in scenarios {
            guard !scenario.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EvalError.invalidSuite("Interaction scenario id is required.")
            }
            guard scenarioIDs.insert(scenario.id).inserted else {
                throw EvalError.invalidSuite("Duplicate interaction scenario id: \(scenario.id).")
            }
            guard !scenario.turns.isEmpty else {
                throw EvalError.invalidSuite("Interaction scenario \(scenario.id) must contain at least one turn.")
            }

            var turnIDs = Set<String>()
            for turn in scenario.turns {
                guard !turn.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw EvalError.invalidSuite("Interaction scenario \(scenario.id) contains an empty turn id.")
                }
                guard turnIDs.insert(turn.id).inserted else {
                    throw EvalError.invalidSuite("Duplicate turn id \(turn.id) in interaction scenario \(scenario.id).")
                }
                guard turn.approvalPrompt != nil
                        || turn.questionPrompt != nil
                        || !turn.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw EvalError.invalidSuite("Interaction turn \(turn.id) needs user text, an approval prompt, or a question prompt.")
                }
            }
        }
    }
}

public struct InteractionEvalScenario: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var description: String?
    public var tags: [String]
    public var projects: [InteractionProjectFixture]
    public var agent: InteractionAgentFixture?
    public var turns: [InteractionEvalTurn]

    public init(
        id: String,
        title: String,
        description: String? = nil,
        tags: [String] = [],
        projects: [InteractionProjectFixture] = [],
        agent: InteractionAgentFixture? = nil,
        turns: [InteractionEvalTurn]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.tags = tags
        self.projects = projects
        self.agent = agent
        self.turns = turns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.projects = try container.decodeIfPresent([InteractionProjectFixture].self, forKey: .projects) ?? []
        self.agent = try container.decodeIfPresent(InteractionAgentFixture.self, forKey: .agent)
        self.turns = try container.decode([InteractionEvalTurn].self, forKey: .turns)
    }
}

public struct InteractionEvalTurn: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var user: String
    public var inputMode: AssistantInputMode
    public var outputMode: AssistantOutputMode
    public var brain: InteractionBrainFixture?
    public var approvalPrompt: InteractionApprovalPromptFixture?
    public var questionPrompt: InteractionQuestionPromptFixture?
    public var cancelAfterAgentStarts: Bool
    public var expectedFailureReason: String?
    public var expectations: InteractionTurnExpectations?

    public init(
        id: String,
        user: String,
        inputMode: AssistantInputMode = .typed,
        outputMode: AssistantOutputMode = .textOnly,
        brain: InteractionBrainFixture? = nil,
        approvalPrompt: InteractionApprovalPromptFixture? = nil,
        questionPrompt: InteractionQuestionPromptFixture? = nil,
        cancelAfterAgentStarts: Bool = false,
        expectedFailureReason: String? = nil,
        expectations: InteractionTurnExpectations? = nil
    ) {
        self.id = id
        self.user = user
        self.inputMode = inputMode
        self.outputMode = outputMode
        self.brain = brain
        self.approvalPrompt = approvalPrompt
        self.questionPrompt = questionPrompt
        self.cancelAfterAgentStarts = cancelAfterAgentStarts
        self.expectedFailureReason = expectedFailureReason
        self.expectations = expectations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        self.inputMode = try container.decodeIfPresent(AssistantInputMode.self, forKey: .inputMode) ?? .typed
        self.outputMode = try container.decodeIfPresent(AssistantOutputMode.self, forKey: .outputMode) ?? .textOnly
        self.brain = try container.decodeIfPresent(InteractionBrainFixture.self, forKey: .brain)
        self.approvalPrompt = try container.decodeIfPresent(InteractionApprovalPromptFixture.self, forKey: .approvalPrompt)
        self.questionPrompt = try container.decodeIfPresent(InteractionQuestionPromptFixture.self, forKey: .questionPrompt)
        self.cancelAfterAgentStarts = try container.decodeIfPresent(Bool.self, forKey: .cancelAfterAgentStarts) ?? false
        self.expectedFailureReason = try container.decodeIfPresent(String.self, forKey: .expectedFailureReason)
        self.expectations = try container.decodeIfPresent(InteractionTurnExpectations.self, forKey: .expectations)
    }
}

public struct InteractionProjectFixture: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var aliases: [String]
    public var localPath: String
    public var gitRemoteURL: String?

    public init(
        id: String,
        displayName: String,
        aliases: [String] = [],
        localPath: String,
        gitRemoteURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.localPath = localPath
        self.gitRemoteURL = gitRemoteURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.localPath = try container.decode(String.self, forKey: .localPath)
        self.gitRemoteURL = try container.decodeIfPresent(String.self, forKey: .gitRemoteURL)
    }

    public var project: ProjectIdentity {
        ProjectIdentity(
            id: ProjectID(rawValue: id),
            displayName: displayName,
            aliases: aliases,
            localPath: localPath,
            gitRemoteURL: gitRemoteURL
        )
    }
}

public struct InteractionBrainFixture: Codable, Equatable, Sendable {
    public var directiveJSON: String?
    public var responseText: String?

    public init(directiveJSON: String? = nil, responseText: String? = nil) {
        self.directiveJSON = directiveJSON
        self.responseText = responseText
    }
}

public struct InteractionAgentFixture: Codable, Equatable, Sendable {
    public var providerID: String
    public var displayName: String
    public var kind: InteractionAgentFixtureKind
    public var responseText: String
    public var discoveryCandidates: [InteractionProjectDiscoveryCandidateFixture]
    public var discoveryError: String?

    public init(
        providerID: String = "codex-agent",
        displayName: String = "Codex",
        kind: InteractionAgentFixtureKind = .normal,
        responseText: String = "",
        discoveryCandidates: [InteractionProjectDiscoveryCandidateFixture] = [],
        discoveryError: String? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.kind = kind
        self.responseText = responseText
        self.discoveryCandidates = discoveryCandidates
        self.discoveryError = discoveryError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? "codex-agent"
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Codex"
        self.kind = try container.decodeIfPresent(InteractionAgentFixtureKind.self, forKey: .kind) ?? .normal
        self.responseText = try container.decodeIfPresent(String.self, forKey: .responseText) ?? ""
        self.discoveryCandidates = try container.decodeIfPresent(
            [InteractionProjectDiscoveryCandidateFixture].self,
            forKey: .discoveryCandidates
        ) ?? []
        self.discoveryError = try container.decodeIfPresent(String.self, forKey: .discoveryError)
    }
}

public enum InteractionAgentFixtureKind: String, Codable, Equatable, Sendable {
    case normal
    case noisy
    case hanging
    case setupUnavailable
}

public struct InteractionProjectDiscoveryCandidateFixture: Codable, Equatable, Sendable {
    public var project: InteractionProjectFixture
    public var confidence: ProjectDiscoveryConfidence
    public var score: Int

    public init(
        project: InteractionProjectFixture,
        confidence: ProjectDiscoveryConfidence = .high,
        score: Int
    ) {
        self.project = project
        self.confidence = confidence
        self.score = score
    }

    public var candidate: ProjectDiscoveryCandidate {
        ProjectDiscoveryCandidate(project: project.project, confidence: confidence, score: score)
    }
}

public struct InteractionApprovalPromptFixture: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var providerID: String
    public var mode: AgentMode
    public var workspacePath: String?
    public var dataScopes: [AgentDataScope]
    public var actionScopes: [AgentActionScope]
    public var decision: AgentApprovalDecision?

    public init(
        title: String,
        detail: String? = nil,
        providerID: String = "codex-agent",
        mode: AgentMode = .act,
        workspacePath: String? = nil,
        dataScopes: [AgentDataScope] = [.prompt, .workspaceFiles],
        actionScopes: [AgentActionScope] = [.readWorkspace, .runCommands, .editWorkspace],
        decision: AgentApprovalDecision? = nil
    ) {
        self.title = title
        self.detail = detail
        self.providerID = providerID
        self.mode = mode
        self.workspacePath = workspacePath
        self.dataScopes = dataScopes
        self.actionScopes = actionScopes
        self.decision = decision
    }
}

public struct InteractionQuestionPromptFixture: Codable, Equatable, Sendable {
    public var title: String
    public var providerID: String
    public var questions: [AgentQuestion]
    public var response: AgentQuestionResponse?

    public init(
        title: String,
        providerID: String = "claude-code",
        questions: [AgentQuestion],
        response: AgentQuestionResponse? = nil
    ) {
        self.title = title
        self.providerID = providerID
        self.questions = questions
        self.response = response
    }

    public var prompt: AgentQuestionPrompt {
        AgentQuestionPrompt(
            id: "interaction-question-\(providerID)",
            providerID: ProviderID(rawValue: providerID),
            title: title,
            questions: questions
        )
    }
}

public struct InteractionTurnExpectations: Codable, Equatable, Sendable {
    public var messages: [InteractionMessageExpectation]
    public var forbiddenMessageTextContains: [String]
    public var forbiddenDetailsTextContains: [String]
    public var spokenTexts: [String]?
    public var spokenTextContains: [String]
    public var forbiddenSpeechTextContains: [String]
    public var agentRequestCount: Int?
    public var agentRequests: [InteractionAgentRequestExpectation]
    public var diagnostics: [InteractionDiagnosticExpectation]
    public var memoryContains: [String]
    public var projectWriteIDs: [String]

    public init(
        messages: [InteractionMessageExpectation] = [],
        forbiddenMessageTextContains: [String] = [],
        forbiddenDetailsTextContains: [String] = [],
        spokenTexts: [String]? = nil,
        spokenTextContains: [String] = [],
        forbiddenSpeechTextContains: [String] = [],
        agentRequestCount: Int? = nil,
        agentRequests: [InteractionAgentRequestExpectation] = [],
        diagnostics: [InteractionDiagnosticExpectation] = [],
        memoryContains: [String] = [],
        projectWriteIDs: [String] = []
    ) {
        self.messages = messages
        self.forbiddenMessageTextContains = forbiddenMessageTextContains
        self.forbiddenDetailsTextContains = forbiddenDetailsTextContains
        self.spokenTexts = spokenTexts
        self.spokenTextContains = spokenTextContains
        self.forbiddenSpeechTextContains = forbiddenSpeechTextContains
        self.agentRequestCount = agentRequestCount
        self.agentRequests = agentRequests
        self.diagnostics = diagnostics
        self.memoryContains = memoryContains
        self.projectWriteIDs = projectWriteIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.messages = try container.decodeIfPresent([InteractionMessageExpectation].self, forKey: .messages) ?? []
        self.forbiddenMessageTextContains = try container.decodeIfPresent([String].self, forKey: .forbiddenMessageTextContains) ?? []
        self.forbiddenDetailsTextContains = try container.decodeIfPresent([String].self, forKey: .forbiddenDetailsTextContains) ?? []
        self.spokenTexts = try container.decodeIfPresent([String].self, forKey: .spokenTexts)
        self.spokenTextContains = try container.decodeIfPresent([String].self, forKey: .spokenTextContains) ?? []
        self.forbiddenSpeechTextContains = try container.decodeIfPresent([String].self, forKey: .forbiddenSpeechTextContains) ?? []
        self.agentRequestCount = try container.decodeIfPresent(Int.self, forKey: .agentRequestCount)
        self.agentRequests = try container.decodeIfPresent([InteractionAgentRequestExpectation].self, forKey: .agentRequests) ?? []
        self.diagnostics = try container.decodeIfPresent([InteractionDiagnosticExpectation].self, forKey: .diagnostics) ?? []
        self.memoryContains = try container.decodeIfPresent([String].self, forKey: .memoryContains) ?? []
        self.projectWriteIDs = try container.decodeIfPresent([String].self, forKey: .projectWriteIDs) ?? []
    }
}

public struct InteractionMessageExpectation: Codable, Equatable, Sendable {
    public var role: ChatMessageRole?
    public var status: ChatMessageStatus?
    public var text: String?
    public var textContains: String?
    public var detailsContains: String?
    public var approvalTitleContains: String?
    public var approvalDecision: AgentApprovalDecision?
    public var questionTitleContains: String?

    public init(
        role: ChatMessageRole? = nil,
        status: ChatMessageStatus? = nil,
        text: String? = nil,
        textContains: String? = nil,
        detailsContains: String? = nil,
        approvalTitleContains: String? = nil,
        approvalDecision: AgentApprovalDecision? = nil,
        questionTitleContains: String? = nil
    ) {
        self.role = role
        self.status = status
        self.text = text
        self.textContains = textContains
        self.detailsContains = detailsContains
        self.approvalTitleContains = approvalTitleContains
        self.approvalDecision = approvalDecision
        self.questionTitleContains = questionTitleContains
    }
}

public struct InteractionAgentRequestExpectation: Codable, Equatable, Sendable {
    public var providerID: String?
    public var workspacePath: String?
    public var promptContains: String?
    public var mode: AgentMode?

    public init(providerID: String? = nil, workspacePath: String? = nil, promptContains: String? = nil, mode: AgentMode? = nil) {
        self.providerID = providerID
        self.workspacePath = workspacePath
        self.promptContains = promptContains
        self.mode = mode
    }
}

public struct InteractionDiagnosticExpectation: Codable, Equatable, Sendable {
    public var kind: AssistantDiagnosticEventKind
    public var phase: String?
    public var outcome: String?

    public init(kind: AssistantDiagnosticEventKind, phase: String? = nil, outcome: String? = nil) {
        self.kind = kind
        self.phase = phase
        self.outcome = outcome
    }
}
