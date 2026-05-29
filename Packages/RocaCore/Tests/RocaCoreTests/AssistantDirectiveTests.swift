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
        try AssistantDirectiveEnvelope(type: .unsupported, message: "Not yet.").directive()
            == .unsupported("Not yet.")
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
}
