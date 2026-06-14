import RocaCore
@testable import RocaProviders
import Testing

@Test
func appleSpeechBiasesAssistantVocabularyOnlyForAssistantLikeInput() {
    #expect(AppleSpeechSTTProvider.contextualStrings(for: .assistantPrompt) == ["Roca", "Codex"])
    #expect(AppleSpeechSTTProvider.contextualStrings(for: .command) == ["Roca", "Codex"])
    #expect(AppleSpeechSTTProvider.contextualStrings(for: .dictation).isEmpty)
}
