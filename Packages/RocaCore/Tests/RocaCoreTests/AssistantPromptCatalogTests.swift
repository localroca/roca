import RocaCore
import Testing

@Test
func assistantPromptCatalogExposesStablePromptVersions() {
    #expect(AssistantPromptCatalog.directivePromptVersion == "assistant-router-2026-06-29-v2")
    #expect(AssistantPromptCatalog.responsePromptVersion == "companion-response-2026-06-14-v1")
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains(#"{"type":"readSelection"}"#))
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains(#"{"type":"runAgent""#))
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains(#"{"type":"runSkill""#))
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains("explicit local developer workflow requests"))
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains("explicit local spreadsheet"))
    #expect(AssistantPromptCatalog.directiveSystemPrompt.contains("Never copy projectName values from examples"))
    #expect(!AssistantPromptCatalog.directiveSystemPrompt.contains("/Users/me/Downloads/sales.csv"))
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
func assistantPromptCatalogNormalizesDoubleEscapedMarkdownLineBreaks() {
    let response = AssistantPromptCatalog.parseAssistantResponse(
        ###"{"bubbleText":"Done.","detailsMarkdown":"- File: `README.md`\\n- Location: `/tmp/project`\\n- Line count: 313"}"###
    )

    #expect(response.bubbleText == "Done.")
    #expect(response.detailsMarkdown == "- File: `README.md`\n- Location: `/tmp/project`\n- Line count: 313")
    #expect(response.detailsMarkdown?.contains(#"\n"#) == false)
}

@Test
func assistantPromptCatalogPreservesEscapedNewlinesInsideCodeDetails() {
    let response = AssistantPromptCatalog.parseAssistantResponse(
        ###"{"bubbleText":"Snippet.","detailsMarkdown":"Use `print(\"a\\n\")` to include a newline."}"###
    )

    #expect(response.bubbleText == "Snippet.")
    #expect(response.detailsMarkdown == #"Use `print("a\n")` to include a newline."#)
}

@Test
func assistantPromptCatalogRemovesDuplicatedBubbleFromDetails() {
    let response = AssistantPromptCatalog.parseAssistantResponse(
        "{\"bubbleText\":\"Short summary.\",\"detailsMarkdown\":\"Short summary.\\n\\n## Details\\n- One\"}"
    )

    #expect(response.bubbleText == "Short summary.")
    #expect(response.detailsMarkdown == "## Details\n- One")
    #expect(response.conversationText == "Short summary.\n\n## Details\n- One")
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
