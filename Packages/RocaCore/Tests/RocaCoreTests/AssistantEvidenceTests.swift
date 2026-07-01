import RocaCore
import Testing

@Test
func answerAdmissionVerifiesCodebaseFactWhenEvidenceIsPartial() {
    let result = AssistantAgentResultContext(
        providerID: "local-skill",
        providerName: "Codebase Skill",
        mode: .ask,
        project: ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend"),
        summary: "Nova Backend is mostly Go.",
        detailsMarkdown: nil,
        evidence: AssistantEvidenceSummary(
            sourceKind: .localSkill,
            sourceID: "codebase",
            sourceName: "Codebase Skill",
            grade: .partial
        )
    )

    let decision = AnswerAdmissionPolicy.decision(
        userInput: "So no JavaScript then?",
        priorResult: result
    )

    #expect(decision.action == .verifyWithSkill)
    #expect(decision.requiredSkillID == SkillID(rawValue: "codebase"))
    #expect(decision.reason.contains("partial"))
}

@Test
func answerAdmissionAllowsReadingPriorDetailsWithoutVerification() {
    let result = AssistantAgentResultContext(
        providerID: "local-skill",
        providerName: "Codebase Skill",
        mode: .ask,
        project: ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth"),
        summary: "I found the endpoint flow.",
        detailsMarkdown: "## Flow\n- begin\n- finish",
        evidence: AssistantEvidenceSummary(
            sourceKind: .localSkill,
            sourceID: "codebase",
            sourceName: "Codebase Skill",
            grade: .partial
        )
    )

    let decision = AnswerAdmissionPolicy.decision(
        userInput: "Can you tell it to me out loud?",
        priorResult: result
    )

    #expect(decision.action == .answerFromContext)
    #expect(decision.reason == "readPriorDetails")
}

@Test
func contextBudgeterKeepsEvidenceContractAndMarksTruncation() {
    let largeSection = String(repeating: "- evidence line\n", count: 2_000)
    let markdown = """
    # Codebase Skill Evidence

    ## Workspace
    - Project: Roca

    ## Targeted File Evidence
    \(largeSection)

    ## Evidence Contract
    Answer only from gathered evidence.
    """
    let summary = AssistantEvidenceSummary(
        sourceKind: .localSkill,
        sourceID: "codebase",
        sourceName: "Codebase Skill",
        grade: .verified
    )

    let budgeted = AssistantContextBudgeter.budgetEvidence(
        markdown: markdown,
        summary: summary,
        budget: AssistantContextBudget(maxEvidenceCharacters: 2_000)
    )

    #expect(budgeted.isTruncated)
    #expect(budgeted.markdown.contains("## Workspace"))
    #expect(budgeted.markdown.contains("## Evidence Contract"))
    #expect(budgeted.summary.isTruncated)
    #expect(budgeted.summary.originalCharacterCount == markdown.trimmingCharacters(in: .whitespacesAndNewlines).count)
    #expect(budgeted.summary.limitations.contains("Some evidence was omitted to fit the selected model context."))
}
