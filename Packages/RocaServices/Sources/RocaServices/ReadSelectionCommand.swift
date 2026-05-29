import Foundation
import RocaCore

public actor ReadSelectionCommand {
    public typealias SpeechConfigurationLoader = @Sendable () async -> SpeechConfiguration

    private let selectionReader: any SelectionReading
    private let speechOrchestrator: DefaultSpeechOrchestrator
    private let speechConfiguration: SpeechConfigurationLoader
    private let defaultFormat: AudioDescriptor

    public init(
        selectionReader: any SelectionReading,
        speechOrchestrator: DefaultSpeechOrchestrator,
        defaultFormat: AudioDescriptor = .wav24Mono,
        speechConfiguration: @escaping SpeechConfigurationLoader = { .init(providerID: nil, providerVoiceSelections: [:], speed: 1.0, allowFallback: true) }
    ) {
        self.selectionReader = selectionReader
        self.speechOrchestrator = speechOrchestrator
        self.defaultFormat = defaultFormat
        self.speechConfiguration = speechConfiguration
    }

    public func run() async throws -> SelectionReadResult {
        let activeSession = await speechOrchestrator.activeSession
        if activeSession != nil {
            await speechOrchestrator.stopSpeaking()
        }

        let selection = try await selectionReader.readSelection()
        guard case .text(let text) = selection else {
            return selection
        }

        let newFingerprint = await speechOrchestrator.fingerprint(text)
        if activeSession?.source == .selectedText,
           activeSession?.normalizedTextFingerprint == newFingerprint {
            return .empty
        }

        let speechConfiguration = await speechConfiguration()
        try await speechOrchestrator.speak(
            SpeechRequest(
                utteranceID: .make(),
                text: text,
                providerID: speechConfiguration.providerID,
                voice: nil,
                providerVoiceSelections: speechConfiguration.providerVoiceSelections,
                format: defaultFormat,
                speed: speechConfiguration.speed,
                source: .selectedText,
                allowFallback: speechConfiguration.allowFallback
            )
        )
        return selection
    }
}
