import RocaCore
import Testing

@Test
func assistantPromptCatalogExposesStablePromptVersions() {
    #expect(AssistantPromptCatalog.directivePromptVersion == "assistant-router-2026-06-13-v1")
    #expect(AssistantPromptCatalog.responsePromptVersion == "companion-response-2026-05-26-v2")
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains(#"{"type":"readSelection"}"#))
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains(#"{"type":"runAgent""#))
}

@Test
func assistantPromptCatalogParsesDirectivesFromWrappedJSON() throws {
    let directive = try AssistantPromptCatalog.parseDirective(
        """
        Sure:
        {"type":"openApplication","appName":"Safari"}
        """
    )

    #expect(directive == .openApplication(ApplicationCommandTarget(appName: "Safari")))
}

@Test
func assistantPromptCatalogParsesStructuredAssistantResponse() {
    let response = AssistantPromptCatalog.parseAssistantResponse(
        "{\"bubbleText\":\"Short.\",\"detailsMarkdown\":\"## Details\\n- One\"}"
    )

    #expect(response.bubbleText == "Short.")
    #expect(response.detailsMarkdown == "## Details\n- One")
    #expect(response.conversationText == "Short.\n\n## Details\n- One")
}

@Test
func assistantPromptCatalogSplitsLongUnstructuredMarkdown() {
    let response = AssistantPromptCatalog.parseAssistantResponse(
        """
        Here is the checklist:

        - One
        - Two
        - Three
        - Four
        """
    )

    #expect(response.bubbleText == "Here is the checklist:")
    #expect(response.detailsMarkdown?.contains("- Four") == true)
}
