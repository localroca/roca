import Foundation
import RocaCore

public actor FakeTTSProvider: TTSProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: TTSCapabilities
    public private(set) var prepareCallCount = 0
    public var prepareError: Error?

    public init(
        id: ProviderID,
        displayName: String,
        capabilities: TTSCapabilities = TTSCapabilities(supportsStreaming: false, supportedFormats: [.mp3], locality: .local),
        prepareError: Error? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.prepareError = prepareError
    }

    public func prepare() async throws {
        prepareCallCount += 1
        if let prepareError {
            throw prepareError
        }
    }

    public func listVoices() async throws -> [TTSVoice] {
        []
    }

    public func synthesize(_ request: TTSRequest) async throws -> AsyncThrowingStream<TTSEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(utteranceID: request.utteranceID))
            continuation.yield(
                .audioChunk(
                    AudioChunk(
                        utteranceID: request.utteranceID,
                        data: Data(),
                        format: request.format,
                        sequenceNumber: 0
                    )
                )
            )
            continuation.yield(.finished(utteranceID: request.utteranceID))
            continuation.finish()
        }
    }

    public func cancel(_ utteranceID: UtteranceID) async {}
}
