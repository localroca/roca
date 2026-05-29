import Foundation
@preconcurrency import MoonshineVoice
import RocaCore

public final class MoonshineSTTProvider: STTProvider, @unchecked Sendable {
    public let id = BuiltInProviderIDs.moonshineSTT
    public let displayName = "Moonshine"
    public let capabilities = STTCapabilities(
        supportsStreaming: true,
        supportedLocales: ["en-US", "en"],
        locality: .local
    )

    private let modelStore: MoonshineModelStore
    private let lock = NSLock()
    private var activeSession: MoonshineTranscriptionSession?

    public init(modelStore: MoonshineModelStore) {
        self.modelStore = modelStore
    }

    public func prepare() async throws {
        _ = try await installedModel()
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        request: STTRequest
    ) async throws -> AsyncThrowingStream<RocaCore.TranscriptEvent, Error> {
        let model = try await installedModel()
        let transcriber = try Transcriber(modelPath: model.directory.path, modelArch: model.modelArch.moonshineVoiceModelArch)
        let stream = try transcriber.createStream(updateInterval: 0.25)
        let session = MoonshineTranscriptionSession(
            transcriptionID: request.transcriptionID,
            transcriber: transcriber,
            stream: stream
        )

        lock.withLock {
            activeSession?.cancel()
            activeSession = session
        }

        return AsyncThrowingStream { continuation in
            var revision = 0
            var completedLineIDs = Set<UInt64>()

            stream.addListener { event in
                if let textChanged = event as? LineTextChanged {
                    revision += 1
                    continuation.yield(
                        .partial(
                            TranscriptRevision(
                                text: textChanged.line.text,
                                revision: revision,
                                replacesRevision: revision > 1 ? revision - 1 : nil
                            )
                        )
                    )
                } else if let completed = event as? LineCompleted {
                    guard completedLineIDs.insert(completed.line.lineId).inserted else {
                        return
                    }
                    continuation.yield(
                        .segment(
                            TranscriptSegment(
                                text: completed.line.text,
                                segmentIndex: completedLineIDs.count - 1,
                                startTime: TimeInterval(completed.line.startTime),
                                endTime: TimeInterval(completed.line.startTime + completed.line.duration),
                                confidence: nil
                            )
                        )
                    )
                } else if let error = event as? TranscriptError {
                    continuation.finish(throwing: error.error)
                }
            }

            do {
                try stream.start()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let task = Task {
                do {
                    for try await frame in audio {
                        try Task.checkCancellation()
                        let samples = try Self.floatSamples(from: frame)
                        try session.addAudio(samples, sampleRate: Int32(frame.sampleRate))
                    }

                    let transcript = try session.stopAndUpdate()
                    let finalText = transcript.lines
                        .sorted { $0.startTime < $1.startTime }
                        .map(\.text)
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !finalText.isEmpty {
                        continuation.yield(
                            .final(
                                TranscriptSegment(
                                    text: finalText,
                                    segmentIndex: 0,
                                    startTime: nil,
                                    endTime: nil,
                                    confidence: nil
                                )
                            )
                        )
                    }

                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                session.close()
                self.clearActiveSession(session)
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                session.cancel()
                self.clearActiveSession(session)
            }
        }
    }

    public func cancel(_ transcriptionID: TranscriptionID) async {
        lock.withLock {
            guard activeSession?.transcriptionID == transcriptionID else {
                return
            }
            activeSession?.cancel()
            activeSession = nil
        }
    }

    private func clearActiveSession(_ session: MoonshineTranscriptionSession) {
        lock.withLock {
            if activeSession === session {
                activeSession = nil
            }
        }
    }

    private func installedModel() async throws -> MoonshineManagedModel {
        do {
            return try await modelStore.installedModel()
        } catch {
            let message = error.localizedDescription
            guard message == "Moonshine model is not installed." || message == "Provider assets are not installed." else {
                throw RocaError.assetInstallFailed(message)
            }
            throw RocaError.assetInstallFailed("Moonshine is not installed. Download it in Providers settings.")
        }
    }

    private static func floatSamples(from frame: AudioFrame) throws -> [Float] {
        guard frame.channels > 0 else {
            return []
        }

        if frame.format.isFloat, frame.format.bitDepth == 32 {
            return frame.pcm.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        }

        guard !frame.format.isFloat, frame.format.bitDepth == 16 else {
            throw RocaError.selectionUnavailable("Unsupported microphone audio format.")
        }

        return frame.pcm.withUnsafeBytes { buffer in
            buffer.bindMemory(to: Int16.self).map { sample in
                Float(sample) / Float(Int16.max)
            }
        }
    }
}

private extension MoonshineManagedModelArch {
    var moonshineVoiceModelArch: ModelArch {
        switch self {
        case .tiny:
            .tiny
        case .base:
            .base
        case .tinyStreaming:
            .tinyStreaming
        case .baseStreaming:
            .baseStreaming
        case .smallStreaming:
            .smallStreaming
        case .mediumStreaming:
            .mediumStreaming
        }
    }
}

private final class MoonshineTranscriptionSession: @unchecked Sendable {
    let transcriptionID: TranscriptionID
    private let transcriber: Transcriber
    private let stream: MoonshineVoice.Stream
    private let lock = NSLock()
    private var isClosed = false

    init(transcriptionID: TranscriptionID, transcriber: Transcriber, stream: MoonshineVoice.Stream) {
        self.transcriptionID = transcriptionID
        self.transcriber = transcriber
        self.stream = stream
    }

    func cancel() {
        lock.withLock {
            guard !isClosed else {
                return
            }
            try? stream.stop()
            stream.close()
            transcriber.close()
            isClosed = true
        }
    }

    func addAudio(_ samples: [Float], sampleRate: Int32) throws {
        try lock.withLock {
            guard !isClosed else {
                return
            }
            try stream.addAudio(samples, sampleRate: sampleRate)
        }
    }

    func stopAndUpdate() throws -> Transcript {
        try lock.withLock {
            guard !isClosed else {
                return Transcript()
            }
            try stream.stop()
            return try stream.updateTranscription()
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else {
                return
            }
            stream.close()
            transcriber.close()
            isClosed = true
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
