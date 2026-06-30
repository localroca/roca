import Foundation

public enum AssistantEvidenceGrade: String, Codable, CaseIterable, Sendable {
    case verified
    case partial
    case stale
    case insufficient
    case none

    public var canSupportDirectAnswer: Bool {
        self == .verified
    }
}

public enum AssistantEvidenceSourceKind: String, Codable, CaseIterable, Sendable {
    case localSkill
    case externalAgent
    case conversation
    case unknown
}

public struct AssistantEvidenceSummary: Codable, Equatable, Sendable {
    public var sourceKind: AssistantEvidenceSourceKind
    public var sourceID: String
    public var sourceName: String
    public var grade: AssistantEvidenceGrade
    public var projectID: String?
    public var projectName: String?
    public var workspacePath: String?
    public var scannedFileCount: Int?
    public var manifestCount: Int?
    public var inspectedPaths: [String]
    public var searchTerms: [String]
    public var omittedPathCount: Int
    public var omittedSectionCount: Int
    public var originalCharacterCount: Int?
    public var budgetedCharacterCount: Int?
    public var isTruncated: Bool
    public var collectedAt: Date
    public var coverageNotes: [String]
    public var limitations: [String]

    public init(
        sourceKind: AssistantEvidenceSourceKind,
        sourceID: String,
        sourceName: String,
        grade: AssistantEvidenceGrade,
        projectID: String? = nil,
        projectName: String? = nil,
        workspacePath: String? = nil,
        scannedFileCount: Int? = nil,
        manifestCount: Int? = nil,
        inspectedPaths: [String] = [],
        searchTerms: [String] = [],
        omittedPathCount: Int = 0,
        omittedSectionCount: Int = 0,
        originalCharacterCount: Int? = nil,
        budgetedCharacterCount: Int? = nil,
        isTruncated: Bool = false,
        collectedAt: Date = Date(),
        coverageNotes: [String] = [],
        limitations: [String] = []
    ) {
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.grade = grade
        self.projectID = projectID
        self.projectName = projectName
        self.workspacePath = workspacePath
        self.scannedFileCount = scannedFileCount
        self.manifestCount = manifestCount
        self.inspectedPaths = inspectedPaths
        self.searchTerms = searchTerms
        self.omittedPathCount = omittedPathCount
        self.omittedSectionCount = omittedSectionCount
        self.originalCharacterCount = originalCharacterCount
        self.budgetedCharacterCount = budgetedCharacterCount
        self.isTruncated = isTruncated
        self.collectedAt = collectedAt
        self.coverageNotes = coverageNotes
        self.limitations = limitations
    }

    public var brainContextText: String {
        var parts = [
            "source=\(sourceName) (\(sourceID))",
            "grade=\(grade.rawValue)"
        ]
        if let projectName {
            parts.append("project=\(projectName)")
        }
        if let scannedFileCount {
            parts.append("filesScanned=\(scannedFileCount)")
        }
        if !inspectedPaths.isEmpty {
            parts.append("inspectedPaths=\(inspectedPaths.prefix(8).joined(separator: ", "))")
        }
        if !searchTerms.isEmpty {
            parts.append("searchTerms=\(searchTerms.prefix(8).joined(separator: ", "))")
        }
        if isTruncated || omittedPathCount > 0 || omittedSectionCount > 0 {
            parts.append("truncated=true")
            parts.append("omittedPaths=\(omittedPathCount)")
            parts.append("omittedSections=\(omittedSectionCount)")
        }
        if !limitations.isEmpty {
            parts.append("limitations=\(limitations.joined(separator: "; "))")
        }
        return parts.joined(separator: "; ")
    }
}

public struct AssistantContextBudget: Codable, Equatable, Sendable {
    public var maxEvidenceCharacters: Int
    public var maxPriorDetailsCharacters: Int

    public init(
        maxEvidenceCharacters: Int = 18_000,
        maxPriorDetailsCharacters: Int = 6_000
    ) {
        self.maxEvidenceCharacters = max(1_000, maxEvidenceCharacters)
        self.maxPriorDetailsCharacters = max(1_000, maxPriorDetailsCharacters)
    }

    public static let standard = AssistantContextBudget()
    public static let tight = AssistantContextBudget(maxEvidenceCharacters: 8_000, maxPriorDetailsCharacters: 3_000)
}

public struct AssistantBudgetedEvidence: Codable, Equatable, Sendable {
    public var markdown: String
    public var summary: AssistantEvidenceSummary
    public var originalCharacterCount: Int
    public var budgetedCharacterCount: Int
    public var omittedSectionCount: Int
    public var isTruncated: Bool

    public init(
        markdown: String,
        summary: AssistantEvidenceSummary,
        originalCharacterCount: Int,
        budgetedCharacterCount: Int,
        omittedSectionCount: Int,
        isTruncated: Bool
    ) {
        self.markdown = markdown
        self.summary = summary
        self.originalCharacterCount = originalCharacterCount
        self.budgetedCharacterCount = budgetedCharacterCount
        self.omittedSectionCount = omittedSectionCount
        self.isTruncated = isTruncated
    }
}

public enum AssistantContextBudgeter {
    public static func budgetEvidence(
        markdown: String,
        summary: AssistantEvidenceSummary,
        budget: AssistantContextBudget = .standard
    ) -> AssistantBudgetedEvidence {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalCount = trimmed.count
        let maxCharacters = budget.maxEvidenceCharacters
        guard originalCount > maxCharacters else {
            var updated = summary
            updated.originalCharacterCount = originalCount
            updated.budgetedCharacterCount = originalCount
            updated.isTruncated = false
            return AssistantBudgetedEvidence(
                markdown: trimmed,
                summary: updated,
                originalCharacterCount: originalCount,
                budgetedCharacterCount: originalCount,
                omittedSectionCount: 0,
                isTruncated: false
            )
        }

        let sections = markdownSections(from: trimmed)
        let pinnedSections = sections.filter { section in
            section.title == nil
                || section.title?.localizedCaseInsensitiveContains("Workspace") == true
                || section.title?.localizedCaseInsensitiveContains("Language And Manifest Inventory") == true
                || section.title?.localizedCaseInsensitiveContains("Evidence Contract") == true
        }
        let flexibleSections = sections.filter { section in
            !pinnedSections.contains(section)
        }

        var selected: [MarkdownSection] = []
        var used = 0
        func add(_ section: MarkdownSection) -> Bool {
            let sectionCount = section.text.count + (selected.isEmpty ? 0 : 2)
            guard used + sectionCount <= maxCharacters else {
                return false
            }
            selected.append(section)
            used += sectionCount
            return true
        }

        for section in pinnedSections {
            if !add(section) {
                selected.append(section.truncated(to: max(600, maxCharacters - used - 200)))
                used = selected.map(\.text.count).reduce(0, +) + max(0, selected.count - 1) * 2
                break
            }
        }

        for section in flexibleSections where used < maxCharacters {
            _ = add(section)
        }

        let omitted = max(0, sections.count - selected.count)
        let notice = """

        ## Omitted Evidence
        \(omitted) section(s) were omitted to fit this model context. Roca should treat missing details as unknown, not absent.
        """
        var result = selected.map(\.text).joined(separator: "\n\n")
        if result.count + notice.count <= maxCharacters {
            result += notice
        }
        if result.count > maxCharacters {
            result = String(result.prefix(maxCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n[Evidence truncated to fit context]"
        }

        var updated = summary
        updated.originalCharacterCount = originalCount
        updated.budgetedCharacterCount = result.count
        updated.omittedSectionCount += omitted
        updated.isTruncated = true
        if !updated.limitations.contains("Some evidence was omitted to fit the selected model context.") {
            updated.limitations.append("Some evidence was omitted to fit the selected model context.")
        }

        return AssistantBudgetedEvidence(
            markdown: result,
            summary: updated,
            originalCharacterCount: originalCount,
            budgetedCharacterCount: result.count,
            omittedSectionCount: omitted,
            isTruncated: true
        )
    }

    public static func budgetPriorDetails(_ detailsMarkdown: String?, budget: AssistantContextBudget = .standard) -> String? {
        guard let details = detailsMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty else {
            return nil
        }
        guard details.count > budget.maxPriorDetailsCharacters else {
            return details
        }
        return String(details.prefix(budget.maxPriorDetailsCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n[Prior details truncated to fit context]"
    }

    private struct MarkdownSection: Equatable {
        var title: String?
        var text: String

        func truncated(to maxCharacters: Int) -> MarkdownSection {
            guard text.count > maxCharacters else {
                return self
            }
            return MarkdownSection(
                title: title,
                text: String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n[Section truncated]"
            )
        }
    }

    private static func markdownSections(from markdown: String) -> [MarkdownSection] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [MarkdownSection] = []
        var currentTitle: String?
        var currentLines: [String] = []

        func flush() {
            guard !currentLines.isEmpty else {
                return
            }
            sections.append(MarkdownSection(title: currentTitle, text: currentLines.joined(separator: "\n")))
        }

        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return sections.isEmpty ? [MarkdownSection(title: nil, text: markdown)] : sections
    }
}

public enum AnswerAdmissionAction: String, Codable, Equatable, Sendable {
    case answerFromContext
    case verifyWithSkill
}

public struct AnswerAdmissionDecision: Codable, Equatable, Sendable {
    public var action: AnswerAdmissionAction
    public var reason: String
    public var requiredSkillID: SkillID?

    public init(action: AnswerAdmissionAction, reason: String, requiredSkillID: SkillID? = nil) {
        self.action = action
        self.reason = reason
        self.requiredSkillID = requiredSkillID
    }
}

public enum AnswerAdmissionPolicy {
    public static func decision(
        userInput: String,
        priorResult: AssistantAgentResultContext?
    ) -> AnswerAdmissionDecision {
        let normalized = ProjectIdentityResolver.normalizedKey(userInput)
        guard !normalized.isEmpty else {
            return AnswerAdmissionDecision(action: .answerFromContext, reason: "emptyInput")
        }
        guard let priorResult else {
            return AnswerAdmissionDecision(action: .answerFromContext, reason: "noPriorResult")
        }
        guard priorResult.providerID.rawValue == "local-skill",
              SkillDirectiveRequest.skillID(for: priorResult.providerName)?.rawValue == "codebase"
        else {
            return AnswerAdmissionDecision(action: .answerFromContext, reason: "priorResultNotLocalCodebase")
        }
        if isReadPriorDetailsRequest(normalized) {
            return AnswerAdmissionDecision(action: .answerFromContext, reason: "readPriorDetails")
        }
        guard isCodebaseFactRequest(normalized) else {
            return AnswerAdmissionDecision(action: .answerFromContext, reason: "notCodebaseFactRequest")
        }
        let grade = priorResult.evidence?.grade ?? .none
        if grade.canSupportDirectAnswer, isSimpleContinuation(normalized) {
            return AnswerAdmissionDecision(action: .answerFromContext, reason: "verifiedPriorEvidence")
        }
        return AnswerAdmissionDecision(
            action: .verifyWithSkill,
            reason: "codebaseFactNeedsFreshEvidence:\(grade.rawValue)",
            requiredSkillID: SkillID(rawValue: "codebase")
        )
    }

    private static func isReadPriorDetailsRequest(_ normalized: String) -> Bool {
        let patterns = [
            "read it", "read that", "read them", "tell it to me", "tell me out loud",
            "say it out loud", "repeat that", "can you tell me that"
        ]
        return patterns.contains { normalized.contains($0) }
    }

    private static func isSimpleContinuation(_ normalized: String) -> Bool {
        normalized.split(separator: " ").count <= 5
            && !containsAny(normalized, [
                "check", "confirm", "verify", "inspect", "look", "search", "where",
                "which", "what", "how", "endpoint", "route", "file", "language",
                "framework", "javascript", "typescript", "node", "cdk", "no ", "not "
            ])
    }

    private static func isCodebaseFactRequest(_ normalized: String) -> Bool {
        containsAny(normalized, [
            "check", "confirm", "verify", "inspect", "look", "search", "find",
            "where", "which", "what", "how many", "endpoint", "route", "handler",
            "service", "file", "folder", "language", "framework", "javascript",
            "typescript", "node", "cdk", "terraform", "go ", "swift", "python",
            "does it", "do we", "is there", "are there", "no ", "not "
        ])
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
