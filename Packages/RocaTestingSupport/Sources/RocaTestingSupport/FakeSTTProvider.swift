import Foundation
import RocaCore

public actor FakeSTTProvider: STTProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: STTCapabilities
    public private(set) var prepareCallCount = 0
    public var prepareError: Error?

    public init(
        id: ProviderID,
        displayName: String,
        capabilities: STTCapabilities = STTCapabilities(supportsStreaming: true, supportedLocales: ["en-US"], locality: .local),
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

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        request: STTRequest
    ) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .final(
                    TranscriptSegment(
                        text: "hello",
                        segmentIndex: 0,
                        startTime: nil,
                        endTime: nil,
                        confidence: nil
                    )
                )
            )
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    public func cancel(_ transcriptionID: TranscriptionID) async {}
}
