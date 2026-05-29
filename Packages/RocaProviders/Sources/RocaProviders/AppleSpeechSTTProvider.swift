import AVFoundation
import Foundation
import RocaCore
@preconcurrency import Speech

public final class AppleSpeechSTTProvider: STTProvider, @unchecked Sendable {
    public let id = BuiltInProviderIDs.appleSpeechSTT
    public let displayName = "Apple Speech"
    public let capabilities = STTCapabilities(
        supportsStreaming: true,
        supportedLocales: ["en-US", "en"],
        locality: .local
    )

    private let defaultLocaleID: String
    private let lock = NSLock()
    private var activeSession: AppleSpeechRecognitionSession?

    public init(defaultLocaleID: String = "en-US") {
        self.defaultLocaleID = defaultLocaleID
    }

    public func prepare() async throws {
        try await prepare(localeID: defaultLocaleID)
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        request: STTRequest
    ) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let localeID = request.locale ?? defaultLocaleID
        try await prepare(localeID: localeID)

        return AsyncThrowingStream { continuation in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
                continuation.finish(throwing: RocaError.providerUnavailable(self.id))
                return
            }

            let speechRequest = SFSpeechAudioBufferRecognitionRequest()
            speechRequest.requiresOnDeviceRecognition = true
            speechRequest.shouldReportPartialResults = true
            if #available(macOS 13.0, *) {
                speechRequest.addsPunctuation = true
            }

            let session = AppleSpeechRecognitionSession(
                transcriptionID: request.transcriptionID,
                request: speechRequest
            )
            lock.withLock {
                activeSession?.cancel()
                activeSession = session
            }

            let recognitionTask = recognizer.recognitionTask(with: speechRequest) { [weak self, weak session] result, error in
                guard let session else {
                    return
                }

                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if result.isFinal {
                            session.finish(
                                continuation: continuation,
                                finalText: text,
                                confidence: Self.averageConfidence(from: result),
                                recognitionTaskAction: .release
                            )
                            self?.clearActiveSession(session)
                            return
                        }

                        let revision = session.updateLatestPartial(text)
                        continuation.yield(
                            .partial(
                                TranscriptRevision(
                                    text: text,
                                    revision: revision,
                                    replacesRevision: revision > 1 ? revision - 1 : nil
                                )
                            )
                        )
                    }
                }

                if let error {
                    session.finish(continuation: continuation, throwing: error)
                    self?.clearActiveSession(session)
                }
            }
            session.setRecognitionTask(recognitionTask)

            let audioTask = Task { [weak self, weak session] in
                guard let session else {
                    return
                }
                do {
                    for try await frame in audio {
                        try Task.checkCancellation()
                        try session.append(Self.audioBuffer(from: frame))
                    }
                    session.endAudio()
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    session.finishWithLatestPartial(continuation: continuation)
                    self?.clearActiveSession(session)
                } catch {
                    session.finish(continuation: continuation, throwing: error)
                    self?.clearActiveSession(session)
                }
            }
            session.setAudioTask(audioTask)

            continuation.onTermination = { @Sendable _ in
                audioTask.cancel()
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

    private func prepare(localeID: String) async throws {
        guard await Self.requestSpeechRecognitionIfNeeded() else {
            throw RocaError.permission(.speechRecognition)
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw RocaError.providerUnavailable(id)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw RocaError.providerUnavailable(id)
        }
        guard recognizer.isAvailable else {
            throw RocaError.providerUnavailable(id)
        }
    }

    private func clearActiveSession(_ session: AppleSpeechRecognitionSession) {
        lock.withLock {
            if activeSession === session {
                activeSession = nil
            }
        }
    }

    private static func requestSpeechRecognitionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .denied, .restricted:
            false
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            false
        }
    }

    private static func audioBuffer(from frame: AudioFrame) throws -> AVAudioPCMBuffer {
        let samples = try floatSamples(from: frame)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw RocaError.selectionUnavailable("Microphone audio buffer unavailable.")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let destination = buffer.floatChannelData?[0] else {
            throw RocaError.selectionUnavailable("Microphone audio format unavailable.")
        }
        samples.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                destination.update(from: baseAddress, count: pointer.count)
            }
        }
        return buffer
    }

    private static func floatSamples(from frame: AudioFrame) throws -> [Float] {
        guard frame.channels > 0 else {
            return []
        }

        let rawSamples: [Float]
        if frame.format.isFloat, frame.format.bitDepth == 32 {
            rawSamples = frame.pcm.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        } else if !frame.format.isFloat, frame.format.bitDepth == 16 {
            rawSamples = frame.pcm.withUnsafeBytes { buffer in
                buffer.bindMemory(to: Int16.self).map { sample in
                    Float(sample) / Float(Int16.max)
                }
            }
        } else {
            throw RocaError.selectionUnavailable("Unsupported microphone audio format.")
        }

        guard frame.channels > 1 else {
            return rawSamples
        }

        let frameCount = rawSamples.count / frame.channels
        var mono = Array(repeating: Float(0), count: frameCount)
        for frameIndex in 0 ..< frameCount {
            for channel in 0 ..< frame.channels {
                mono[frameIndex] += rawSamples[frameIndex * frame.channels + channel] / Float(frame.channels)
            }
        }
        return mono
    }

    private static func averageConfidence(from result: SFSpeechRecognitionResult) -> Double? {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else {
            return nil
        }
        let confidence = segments.reduce(Float(0)) { $0 + $1.confidence } / Float(segments.count)
        guard confidence.isFinite else {
            return nil
        }
        return Double(confidence)
    }
}

private final class AppleSpeechRecognitionSession: @unchecked Sendable {
    let transcriptionID: TranscriptionID
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let lock = NSLock()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioTask: Task<Void, Never>?
    private var latestPartial = ""
    private var revision = 0
    private var isFinished = false

    init(transcriptionID: TranscriptionID, request: SFSpeechAudioBufferRecognitionRequest) {
        self.transcriptionID = transcriptionID
        self.request = request
    }

    func setRecognitionTask(_ task: SFSpeechRecognitionTask) {
        lock.withLock {
            recognitionTask = task
        }
    }

    func setAudioTask(_ task: Task<Void, Never>) {
        lock.withLock {
            audioTask = task
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.withLock {
            guard !isFinished else {
                return
            }
            request.append(buffer)
        }
    }

    func endAudio() {
        lock.withLock {
            guard !isFinished else {
                return
            }
            request.endAudio()
        }
    }

    func updateLatestPartial(_ text: String) -> Int {
        lock.withLock {
            latestPartial = text
            revision += 1
            return revision
        }
    }

    func finishWithLatestPartial(continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) {
        let text = lock.withLock {
            latestPartial
        }
        finish(
            continuation: continuation,
            finalText: text,
            confidence: nil,
            recognitionTaskAction: .finish
        )
    }

    func finish(
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation,
        finalText: String,
        confidence: Double?,
        recognitionTaskAction: RecognitionTaskAction
    ) {
        let completion = markFinished()
        guard completion.didFinish else {
            return
        }
        stopRecognitionTask(completion.recognitionTask, action: recognitionTaskAction)

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            continuation.yield(
                .final(
                    TranscriptSegment(
                        text: trimmed,
                        segmentIndex: 0,
                        startTime: nil,
                        endTime: nil,
                        confidence: confidence
                    )
                )
            )
        }
        continuation.yield(.finished)
        continuation.finish()
    }

    func finish(
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation,
        throwing error: Error
    ) {
        let completion = markFinished()
        guard completion.didFinish else {
            return
        }
        stopRecognitionTask(completion.recognitionTask, action: .cancel)
        continuation.finish(throwing: error)
    }

    func cancel() {
        let completion = markFinished()
        stopRecognitionTask(completion.recognitionTask, action: .cancel)
    }

    private func markFinished() -> (didFinish: Bool, recognitionTask: SFSpeechRecognitionTask?) {
        lock.withLock {
            guard !isFinished else {
                return (false, nil)
            }
            isFinished = true
            audioTask?.cancel()
            audioTask = nil
            request.endAudio()
            let task = recognitionTask
            recognitionTask = nil
            return (true, task)
        }
    }

    private func stopRecognitionTask(_ task: SFSpeechRecognitionTask?, action: RecognitionTaskAction) {
        switch action {
        case .release:
            break
        case .finish:
            task?.finish()
        case .cancel:
            task?.cancel()
        }
    }
}

private enum RecognitionTaskAction {
    case release
    case finish
    case cancel
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
