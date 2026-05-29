import Foundation
import RocaCore

public struct EvalSuite: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var description: String
    public var defaultRepeats: Int
    public var scenarios: [EvalScenario]

    public init(
        schemaVersion: Int,
        id: String,
        title: String,
        description: String,
        defaultRepeats: Int,
        scenarios: [EvalScenario]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.description = description
        self.defaultRepeats = defaultRepeats
        self.scenarios = scenarios
    }

    public static func load(from url: URL) throws -> EvalSuite {
        let data = try Data(contentsOf: url)
        let suite = try JSONDecoder().decode(EvalSuite.self, from: data)
        try suite.validate()
        return suite
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw EvalError.invalidSuite("Unsupported suite schema version \(schemaVersion).")
        }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvalError.invalidSuite("Suite id is required.")
        }
        guard defaultRepeats > 0 else {
            throw EvalError.invalidSuite("defaultRepeats must be greater than zero.")
        }
        guard !scenarios.isEmpty else {
            throw EvalError.invalidSuite("Suite must contain at least one scenario.")
        }

        var ids = Set<String>()
        for scenario in scenarios {
            guard !scenario.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EvalError.invalidSuite("Scenario id is required.")
            }
            guard ids.insert(scenario.id).inserted else {
                throw EvalError.invalidSuite("Duplicate scenario id: \(scenario.id).")
            }
            guard !scenario.turns.isEmpty else {
                throw EvalError.invalidSuite("Scenario \(scenario.id) must contain at least one turn.")
            }
            for turn in scenario.turns {
                guard !turn.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw EvalError.invalidSuite("Scenario \(scenario.id) contains an empty user turn.")
                }
            }
        }
    }

    public func filtered(_ filter: EvalScenarioFilter) -> [EvalScenario] {
        scenarios.filter { scenario in
            if let scenarioIDs = filter.scenarioIDs, !scenarioIDs.contains(scenario.id) {
                return false
            }
            let tags = Set(scenario.tags)
            if !filter.includeTags.isEmpty && tags.isDisjoint(with: filter.includeTags) {
                return false
            }
            if !filter.excludeTags.isEmpty && !tags.isDisjoint(with: filter.excludeTags) {
                return false
            }
            return true
        }
    }
}

public struct EvalScenario: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var description: String?
    public var tags: [String]
    public var turns: [EvalTurn]

    public init(
        id: String,
        title: String,
        description: String?,
        tags: [String],
        turns: [EvalTurn]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.tags = tags
        self.turns = turns
    }
}

public struct EvalTurn: Codable, Equatable, Sendable {
    public var id: String?
    public var user: String
    public var inputMode: AssistantInputMode
    public var context: AssistantLocalContext?
    public var expectations: EvalTurnExpectations?
    public var rubric: EvalRubricNotes?

    public init(
        id: String? = nil,
        user: String,
        inputMode: AssistantInputMode = .typed,
        context: AssistantLocalContext? = nil,
        expectations: EvalTurnExpectations? = nil,
        rubric: EvalRubricNotes? = nil
    ) {
        self.id = id
        self.user = user
        self.inputMode = inputMode
        self.context = context
        self.expectations = expectations
        self.rubric = rubric
    }
}

public struct EvalTurnExpectations: Codable, Equatable, Sendable {
    public var directives: [AssistantDirectiveType]
    public var appName: String?
    public var bundleID: String?
    public var insertedText: String?
    public var expectsDetailsMarkdown: Bool?
    public var maxBubbleCharacters: Int?
    public var notes: String?

    public init(
        directives: [AssistantDirectiveType],
        appName: String? = nil,
        bundleID: String? = nil,
        insertedText: String? = nil,
        expectsDetailsMarkdown: Bool? = nil,
        maxBubbleCharacters: Int? = nil,
        notes: String? = nil
    ) {
        self.directives = directives
        self.appName = appName
        self.bundleID = bundleID
        self.insertedText = insertedText
        self.expectsDetailsMarkdown = expectsDetailsMarkdown
        self.maxBubbleCharacters = maxBubbleCharacters
        self.notes = notes
    }
}

public struct EvalRubricNotes: Codable, Equatable, Sendable {
    public var intent: String?
    public var responseQuality: String?
    public var rocaVoice: String?
    public var formatDiscipline: String?
    public var safetyHonesty: String?
    public var must: [String]
    public var mustNot: [String]

    public init(
        intent: String? = nil,
        responseQuality: String? = nil,
        rocaVoice: String? = nil,
        formatDiscipline: String? = nil,
        safetyHonesty: String? = nil,
        must: [String] = [],
        mustNot: [String] = []
    ) {
        self.intent = intent
        self.responseQuality = responseQuality
        self.rocaVoice = rocaVoice
        self.formatDiscipline = formatDiscipline
        self.safetyHonesty = safetyHonesty
        self.must = must
        self.mustNot = mustNot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.intent = try container.decodeIfPresent(String.self, forKey: .intent)
        self.responseQuality = try container.decodeIfPresent(String.self, forKey: .responseQuality)
        self.rocaVoice = try container.decodeIfPresent(String.self, forKey: .rocaVoice)
        self.formatDiscipline = try container.decodeIfPresent(String.self, forKey: .formatDiscipline)
        self.safetyHonesty = try container.decodeIfPresent(String.self, forKey: .safetyHonesty)
        self.must = try container.decodeIfPresent([String].self, forKey: .must) ?? []
        self.mustNot = try container.decodeIfPresent([String].self, forKey: .mustNot) ?? []
    }
}

public struct EvalScenarioFilter: Equatable, Sendable {
    public var scenarioIDs: Set<String>?
    public var includeTags: Set<String>
    public var excludeTags: Set<String>

    public init(
        scenarioIDs: Set<String>? = nil,
        includeTags: Set<String> = [],
        excludeTags: Set<String> = []
    ) {
        self.scenarioIDs = scenarioIDs?.isEmpty == true ? nil : scenarioIDs
        self.includeTags = includeTags
        self.excludeTags = excludeTags
    }
}

public enum EvalError: Error, LocalizedError, Equatable {
    case invalidArguments(String)
    case invalidSuite(String)
    case noModels
    case noScenarios

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .invalidSuite(let message):
            message
        case .noModels:
            "No Ollama models matched the eval request."
        case .noScenarios:
            "No eval scenarios matched the requested filters."
        }
    }
}
