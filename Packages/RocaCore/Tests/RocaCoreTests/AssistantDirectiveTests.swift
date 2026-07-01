import RocaCore
import Testing

@Test
func assistantDirectiveEnvelopeValidatesSupportedActions() throws {
    #expect(try AssistantDirectiveEnvelope(type: .respond).directive() == .respond)

    #expect(
        try AssistantDirectiveEnvelope(type: .openApplication, appName: "Safari").directive()
            == .openApplication(ApplicationCommandTarget(appName: "Safari"))
    )

    #expect(
        try AssistantDirectiveEnvelope(type: .quitApplication, bundleID: "com.apple.Safari").directive()
            == .quitApplication(ApplicationCommandTarget(bundleID: "com.apple.Safari"))
    )

    #expect(
        try AssistantDirectiveEnvelope(type: .insertText, text: "Hello").directive()
            == .insertText("Hello")
    )

    #expect(try AssistantDirectiveEnvelope(type: .readSelection).directive() == .readSelection)

    #expect(
        try AssistantDirectiveEnvelope(
            type: .runAgent,
            providerID: "codex-agent",
            projectName: "sample-auth",
            prompt: "what login endpoints exist?",
            mode: .ask
        ).directive()
            == .runAgent(
                AgentDirectiveRequest(
                    providerID: ProviderID(rawValue: "codex-agent"),
                    projectName: "sample-auth",
                    prompt: "what login endpoints exist?",
                    mode: .ask
                )
            )
    )

    #expect(
        try AssistantDirectiveEnvelope(type: .unsupported, message: "Not yet.").directive()
            == .unsupported("Not yet.")
    )

    #expect(
        try AssistantDirectiveEnvelope(
            type: .runSkill,
            skillID: "codebase",
            projectName: "roca",
            prompt: "summarize architecture",
            mode: .ask
        ).directive()
            == .runSkill(
                SkillDirectiveRequest(
                    skillID: "codebase",
                    projectName: "roca",
                    prompt: "summarize architecture",
                    mode: .ask
                )
            )
    )
}

@Test
func assistantDirectiveEnvelopeRejectsMissingRequiredFields() throws {
    #expect(throws: RocaError.selectionUnavailable("Open app directive needs an app name or bundle ID.")) {
        _ = try AssistantDirectiveEnvelope(type: .openApplication).directive()
    }

    #expect(throws: RocaError.selectionUnavailable("Quit app directive needs an app name or bundle ID.")) {
        _ = try AssistantDirectiveEnvelope(type: .quitApplication).directive()
    }

    #expect(throws: RocaError.selectionUnavailable("Insert text directive needs text.")) {
        _ = try AssistantDirectiveEnvelope(type: .insertText, text: " ").directive()
    }

    #expect(throws: RocaError.selectionUnavailable("Agent directive needs a prompt.")) {
        _ = try AssistantDirectiveEnvelope(type: .runAgent, providerID: "codex-agent").directive()
    }

    #expect(throws: RocaError.selectionUnavailable("Skill directive needs a prompt.")) {
        _ = try AssistantDirectiveEnvelope(type: .runSkill, skillID: "codebase").directive()
    }

    #expect(throws: RocaError.selectionUnavailable("Skill directive needs a skill.")) {
        _ = try AssistantDirectiveEnvelope(type: .runSkill, prompt: "inspect this").directive()
    }
}

@Test
func assistantDirectiveEnvelopeAllowsAgentProviderToBeResolvedLater() throws {
    #expect(
        try AssistantDirectiveEnvelope(type: .runAgent, projectName: "roca", prompt: "inspect this").directive()
            == .runAgent(
                AgentDirectiveRequest(
                    providerID: nil,
                    projectName: "roca",
                    prompt: "inspect this",
                    mode: .ask
                )
            )
    )
}
