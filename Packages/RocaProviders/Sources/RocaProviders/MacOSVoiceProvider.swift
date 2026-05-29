@preconcurrency import AVFoundation
import Foundation
import RocaCore

public final class MacOSVoiceProvider: TTSProvider, @unchecked Sendable {
    public let id: ProviderID
    public let displayName: String

    private let synthesizers = MacSpeechSynthesizerStore()

    public var capabilities: TTSCapabilities {
        TTSCapabilities(
            supportsStreaming: false,
            supportedFormats: [.wav16Mono],
            locality: .local
        )
    }

    public init(id: ProviderID = BuiltInProviderIDs.macOSVoice, displayName: String = "macOS Voices") {
        self.id = id
        self.displayName = displayName
    }

    public func prepare() async throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if voices.isEmpty {
            throw RocaError.providerUnavailable(id)
        }
    }

    public func listVoices() async throws -> [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language == rhs.language {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.language.localizedCaseInsensitiveCompare(rhs.language) == .orderedAscending
            }
            .map(Self.mapVoice)
    }

    public func synthesize(_ request: TTSRequest) async throws -> AsyncThrowingStream<TTSEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(utteranceID: request.utteranceID))

            let task = Task {
                do {
                    let voice = Self.voice(for: request.voice) ?? Self.defaultVoice()
                    let wav = try await synthesizeWAV(text: request.text, voice: voice, rateMultiplier: request.speed, utteranceID: request.utteranceID)
                    let descriptor = AudioDescriptor(
                        encoding: .wav,
                        mimeType: "audio/wav",
                        sampleRate: wav.sampleRate,
                        channels: wav.channels,
                        bitDepth: 16
                    )

                    continuation.yield(
                        .audioChunk(
                            AudioChunk(
                                utteranceID: request.utteranceID,
                                data: wav.data,
                                format: descriptor,
                                sequenceNumber: 0
                            )
                        )
                    )
                    continuation.yield(.finished(utteranceID: request.utteranceID))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.cancelled(utteranceID: request.utteranceID))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RocaError.synthesisFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { [synthesizers] _ in
                task.cancel()
                synthesizers.cancel(request.utteranceID)
            }
        }
    }

    public func cancel(_ utteranceID: UtteranceID) async {
        synthesizers.cancel(utteranceID)
    }

    private func synthesizeWAV(
        text: String,
        voice: AVSpeechSynthesisVoice?,
        rateMultiplier: Double,
        utteranceID: UtteranceID
    ) async throws -> WAVResult {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(max(0.5, min(rateMultiplier, 2.0)))

        let synthesizer = AVSpeechSynthesizer()
        synthesizers.set(synthesizer, for: utteranceID)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accumulator = PCMAccumulator()

                synthesizer.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else {
                        accumulator.finish(throwing: RocaError.synthesisFailed("macOS returned a non-PCM speech buffer."), continuation: continuation)
                        return
                    }

                    if pcm.frameLength == 0 {
                        do {
                            let wav = try accumulator.makeWAV()
                            accumulator.finish(returning: wav, continuation: continuation)
                        } catch {
                            accumulator.finish(throwing: error, continuation: continuation)
                        }
                        self.synthesizers.remove(utteranceID)
                        return
                    }

                    do {
                        try accumulator.append(pcm)
                    } catch {
                        accumulator.finish(throwing: error, continuation: continuation)
                        self.synthesizers.remove(utteranceID)
                    }
                }
            }
        } onCancel: {
            self.synthesizers.cancel(utteranceID)
        }
    }

    private static func mapVoice(_ voice: AVSpeechSynthesisVoice) -> TTSVoice {
        var traits = ["system"]
        switch voice.quality {
        case .premium:
            traits.append("premium")
        case .enhanced:
            traits.append("enhanced")
        default:
            traits.append("standard")
        }
        if noveltyVoiceNames.contains(voice.name.lowercased()) {
            traits.append("novelty")
        }

        return TTSVoice(
            id: VoiceID(rawValue: voice.identifier),
            displayName: voice.name,
            locale: voice.language,
            traits: traits
        )
    }

    private static func voice(for voiceID: VoiceID?) -> AVSpeechSynthesisVoice? {
        guard let voiceID else {
            return nil
        }
        return AVSpeechSynthesisVoice(identifier: voiceID.rawValue)
    }

    private static func defaultVoice() -> AVSpeechSynthesisVoice? {
        let localePrefix = Locale.current.identifier.prefix(2).lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { !noveltyVoiceNames.contains($0.name.lowercased()) }

        return voices.first { voice in
            voice.language.lowercased().hasPrefix(localePrefix) && voice.quality == .premium
        } ?? voices.first { voice in
            voice.language.lowercased().hasPrefix(localePrefix) && voice.quality == .enhanced
        } ?? voices.first { voice in
            voice.language.lowercased().hasPrefix(localePrefix)
        } ?? voices.first
    }

    private static let noveltyVoiceNames: Set<String> = [
        "albert",
        "bad news",
        "bahh",
        "bells",
        "boing",
        "bubbles",
        "cellos",
        "deranged",
        "good news",
        "hysterical",
        "junior",
        "organ",
        "superstar",
        "trinoids",
        "whisper",
        "wobble",
        "zarvox"
    ]
}

private final class MacSpeechSynthesizerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var synthesizers: [UtteranceID: AVSpeechSynthesizer] = [:]

    func set(_ synthesizer: AVSpeechSynthesizer, for utteranceID: UtteranceID) {
        lock.lock()
        defer { lock.unlock() }
        synthesizers[utteranceID] = synthesizer
    }

    func cancel(_ utteranceID: UtteranceID) {
        lock.lock()
        let synthesizer = synthesizers.removeValue(forKey: utteranceID)
        lock.unlock()
        synthesizer?.stopSpeaking(at: .immediate)
    }

    func remove(_ utteranceID: UtteranceID) {
        lock.lock()
        defer { lock.unlock() }
        synthesizers.removeValue(forKey: utteranceID)
    }
}

private struct WAVResult: Sendable {
    var data: Data
    var sampleRate: Int
    var channels: Int
}

private final class PCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var sampleRate: Int?
    private var channels: Int?
    private var didFinish = false

    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return
        }

        if sampleRate == nil {
            sampleRate = Int(buffer.format.sampleRate)
            channels = channelCount
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let floatChannels = buffer.floatChannelData else {
                throw RocaError.synthesisFailed("Missing float speech samples.")
            }
            for frame in 0 ..< frameCount {
                for channel in 0 ..< channelCount {
                    let sample = max(-1.0, min(1.0, floatChannels[channel][frame]))
                    appendInt16(Int16(sample * Float(Int16.max)), to: &pcm)
                }
            }
        case .pcmFormatInt16:
            guard let int16Channels = buffer.int16ChannelData else {
                throw RocaError.synthesisFailed("Missing int16 speech samples.")
            }
            for frame in 0 ..< frameCount {
                for channel in 0 ..< channelCount {
                    appendInt16(int16Channels[channel][frame], to: &pcm)
                }
            }
        default:
            throw RocaError.synthesisFailed("Unsupported macOS speech sample format.")
        }
    }

    func makeWAV() throws -> WAVResult {
        lock.lock()
        defer { lock.unlock() }

        guard let sampleRate, let channels else {
            throw RocaError.synthesisFailed("macOS speech returned no audio.")
        }

        return WAVResult(
            data: WAVEncoder.encodePCM16(pcm, sampleRate: sampleRate, channels: channels),
            sampleRate: sampleRate,
            channels: channels
        )
    }

    func finish(returning result: WAVResult, continuation: CheckedContinuation<WAVResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else {
            return
        }
        didFinish = true
        continuation.resume(returning: result)
    }

    func finish(throwing error: Error, continuation: CheckedContinuation<WAVResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else {
            return
        }
        didFinish = true
        continuation.resume(throwing: error)
    }

    private func appendInt16(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private enum WAVEncoder {
    static func encodePCM16(_ pcm: Data, sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        let byteRate = UInt32(sampleRate * channels * 2)
        let blockAlign = UInt16(channels * 2)
        let subchunk2Size = UInt32(pcm.count)
        let chunkSize = UInt32(36 + pcm.count)

        data.appendASCII("RIFF")
        data.appendLittleEndian(chunkSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(subchunk2Size)
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
