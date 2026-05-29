@preconcurrency import AVFoundation
import Foundation
import RocaCore

@MainActor
public final class DefaultSpeechPlaybackController: NSObject, SpeechPlaybackControlling, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var currentState: SpeechPlaybackState = .idle
    private var stateContinuations: [UUID: AsyncStream<SpeechPlaybackState>.Continuation] = [:]
    private var audioLevelContinuations: [UUID: AsyncStream<Double>.Continuation] = [:]

    public var state: SpeechPlaybackState {
        currentState
    }

    public nonisolated var stateUpdates: AsyncStream<SpeechPlaybackState> {
        AsyncStream { continuation in
            let id = UUID()

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.stateContinuations[id] = continuation
            }

            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public nonisolated var audioLevelUpdates: AsyncStream<Double> {
        AsyncStream { continuation in
            let id = UUID()

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.audioLevelContinuations[id] = continuation
                continuation.yield(0)
            }

            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.audioLevelContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public override init() {
        super.init()
    }

    public func play(_ events: AsyncThrowingStream<TTSEvent, Error>) async throws {
        playbackTask?.cancel()
        setState(.loading)

        playbackTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled else {
                        break
                    }
                    await self?.handle(event)
                }

                if Task.isCancelled {
                    return
                }

                await MainActor.run {
                    guard let self,
                          self.player == nil,
                          self.currentState == .loading
                    else {
                        return
                    }

                    self.setState(.idle)
                }
            } catch {
                await MainActor.run {
                    self?.setState(.failed(error.localizedDescription))
                }
            }
        }
    }

    public func stop() async {
        playbackTask?.cancel()
        playbackTask = nil
        stopMetering()
        player?.stop()
        player = nil
        setState(.stopped)
    }

    private func handle(_ event: TTSEvent) async {
        switch event {
        case .started:
            setState(.loading)
        case .audioChunk(let chunk):
            do {
                let audioPlayer = try AVAudioPlayer(data: chunk.data)
                audioPlayer.delegate = self
                audioPlayer.isMeteringEnabled = true
                audioPlayer.prepareToPlay()
                guard audioPlayer.play() else {
                    setState(.failed("Audio player could not start."))
                    return
                }
                player = audioPlayer
                startMetering(audioPlayer)
                setState(.playing)
            } catch {
                setState(.failed(error.localizedDescription))
            }
        case .finished:
            if player == nil || player?.isPlaying == false {
                setState(.idle)
            }
        case .cancelled:
            stopMetering()
            player?.stop()
            player = nil
            setState(.stopped)
        }
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.stopMetering()
                self.player = nil
                self.setState(flag ? .idle : .failed("Audio player did not finish successfully."))
            }
        }
    }

    private func setState(_ state: SpeechPlaybackState) {
        currentState = state
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func startMetering(_ audioPlayer: AVAudioPlayer) {
        stopMetering()
        meterTask = Task { @MainActor [weak self, weak audioPlayer] in
            guard let self, let audioPlayer else {
                return
            }

            while !Task.isCancelled, self.player === audioPlayer, audioPlayer.isPlaying {
                audioPlayer.updateMeters()
                self.setAudioLevel(Self.normalizedLevel(fromDecibels: audioPlayer.averagePower(forChannel: 0)))
                try? await Task.sleep(nanoseconds: 33_000_000)
            }

            if !Task.isCancelled, self.player === audioPlayer {
                self.setAudioLevel(0)
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        setAudioLevel(0)
    }

    private func setAudioLevel(_ level: Double) {
        let clamped = min(1, max(0, level))
        for continuation in audioLevelContinuations.values {
            continuation.yield(clamped)
        }
    }

    private static func normalizedLevel(fromDecibels decibels: Float) -> Double {
        guard decibels.isFinite else {
            return 0
        }

        let silenceGate: Float = -42
        guard decibels > silenceGate else {
            return 0
        }

        let floor: Float = -52
        let ceiling: Float = -8
        let clamped = min(ceiling, max(floor, decibels))
        let linear = Double((clamped - floor) / (ceiling - floor))
        return pow(linear, 2.4)
    }
}
