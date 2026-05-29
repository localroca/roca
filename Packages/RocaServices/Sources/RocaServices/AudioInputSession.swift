@preconcurrency import AVFoundation
import Foundation
import RocaCore

public final class DefaultAudioInputSession: AudioInputSession, @unchecked Sendable {
    private let permissions: any PermissionsServicing
    private let frameBufferLimit: Int
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    private var currentState: AudioInputState = .idle
    private var currentMetrics = AudioInputMetrics()
    private var sequenceNumber = 0

    public init(
        permissions: any PermissionsServicing = DefaultPermissionsService(),
        frameBufferLimit: Int = 120
    ) {
        self.permissions = permissions
        self.frameBufferLimit = frameBufferLimit
    }

    public var state: AudioInputState {
        lock.withLock { currentState }
    }

    public var metrics: AudioInputMetrics {
        lock.withLock { currentMetrics }
    }

    public func start(_ request: AudioInputRequest) async throws -> AsyncThrowingStream<AudioFrame, Error> {
        if await permissions.microphonePermissionStatus() != .allowed {
            setState(.requestingPermission)
        }
        guard await permissions.requestMicrophoneIfNeeded() else {
            setState(.failed("Microphone permission needed"))
            throw RocaError.permission(.microphone)
        }

        await stop()

        let stream = AsyncThrowingStream<AudioFrame, Error>(bufferingPolicy: .bufferingNewest(frameBufferLimit)) { continuation in
            self.lock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stop()
                }
            }
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let outputFormat = try Self.outputFormat(for: request)
        let converter = AVAudioConverter(from: format, to: outputFormat)
        lock.withLock {
            sequenceNumber = 0
            currentMetrics = AudioInputMetrics()
            self.outputFormat = outputFormat
            self.converter = converter
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else {
                return
            }
            do {
                let frame = try self.makeFrame(from: buffer)
                self.lock.withLock {
                    let result = self.continuation?.yield(frame)
                    self.currentMetrics.capturedFrameCount += 1
                    self.currentMetrics.lastSequenceNumber = frame.sequenceNumber
                    if case .some(.dropped(_)) = result {
                        self.currentMetrics.droppedFrameCount += 1
                    }
                }
            } catch {
                self.lock.withLock {
                    self.continuation?.finish(throwing: error)
                }
            }
        }

        do {
            try engine.start()
            lock.withLock {
                self.engine = engine
            }
            setState(.recording)
            return stream
        } catch {
            input.removeTap(onBus: 0)
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    public func stop() async {
        let engineToStop = lock.withLock { () -> AVAudioEngine? in
            let engine = self.engine
            self.engine = nil
            return engine
        }

        if let engineToStop {
            engineToStop.inputNode.removeTap(onBus: 0)
            engineToStop.stop()
        }

        lock.withLock {
            converter = nil
            outputFormat = nil
            continuation?.finish()
            continuation = nil
        }
        setState(.stopped)
    }

    private func makeFrame(from buffer: AVAudioPCMBuffer) throws -> AudioFrame {
        let convertedBuffer = try convertedBuffer(from: buffer)
        let samples = try monoFloatSamples(from: convertedBuffer)
        let data = samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return Data()
            }
            return Data(bytes: baseAddress, count: pointer.count * MemoryLayout<Float>.stride)
        }
        let sampleRate = Int(convertedBuffer.format.sampleRate.rounded())
        let duration = sampleRate > 0 ? Int((Double(samples.count) / Double(sampleRate) * 1000).rounded()) : 0
        let sequence = lock.withLock { () -> Int in
            defer { sequenceNumber += 1 }
            return sequenceNumber
        }

        return AudioFrame(
            pcm: data,
            sampleRate: sampleRate,
            channels: 1,
            format: PCMFormat(bitDepth: 32, isFloat: true, isInterleaved: false, endian: .little),
            frameDurationMilliseconds: duration,
            sequenceNumber: sequence,
            capturedAt: Date()
        )
    }

    private func convertedBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let conversionState = lock.withLock {
            (outputFormat: outputFormat, converter: converter)
        }
        guard let outputFormat = conversionState.outputFormat else {
            return buffer
        }

        if buffer.format.commonFormat == .pcmFormatFloat32,
           !buffer.format.isInterleaved,
           buffer.format.sampleRate == outputFormat.sampleRate,
           buffer.format.channelCount == outputFormat.channelCount {
            return buffer
        }

        guard let converter = conversionState.converter else {
            throw RocaError.selectionUnavailable("Microphone audio converter unavailable.")
        }

        let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw RocaError.selectionUnavailable("Microphone audio buffer unavailable.")
        }

        let input = AudioConversionInput(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            input.nextBuffer(outStatus: outStatus)
        }

        if status == .error {
            throw conversionError ?? RocaError.selectionUnavailable("Microphone audio conversion failed.")
        }
        return outputBuffer
    }

    private func monoFloatSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            throw RocaError.selectionUnavailable("Microphone audio format unavailable.")
        }

        let channelCount = max(1, Int(buffer.format.channelCount))
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return []
        }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        var mono = Array(repeating: Float(0), count: frameCount)
        for channel in 0 ..< channelCount {
            let samples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
            for index in 0 ..< frameCount {
                mono[index] += samples[index] / Float(channelCount)
            }
        }
        return mono
    }

    private static func outputFormat(for request: AudioInputRequest) throws -> AVAudioFormat {
        let sampleRate = max(1, request.preferredSampleRate)
        let channels = max(1, request.preferredChannels)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw RocaError.selectionUnavailable("Microphone audio output format unavailable.")
        }
        return format
    }

    private func setState(_ state: AudioInputState) {
        lock.withLock {
            currentState = state
        }
    }
}

private final class AudioConversionInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !didProvideBuffer else {
            outStatus.pointee = .noDataNow
            return nil
        }
        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
