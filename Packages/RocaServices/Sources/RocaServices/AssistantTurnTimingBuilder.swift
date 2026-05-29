import Foundation
import RocaCore

struct AssistantTurnTimingBuilder: Sendable {
    var turnID: BrainRequestID
    var startedAt = Date()
    var listeningStartedAt: Date?
    var stopRequestedAt: Date?
    var transcriptReadyAt: Date?
    var directiveStartedAt: Date?
    var directiveFinishedAt: Date?
    var directiveType: AssistantDirectiveType?
    var responseBrainStartedAt: Date?
    var responseBrainFinishedAt: Date?
    var actionStartedAt: Date?
    var actionFinishedAt: Date?
    var ttsPreparationMilliseconds: Int?
    var ttsFirstAudioMilliseconds: Int?
    var ttsSynthesisMilliseconds: Int?
    var ttsAudioDurationMilliseconds: Int?
    var ttsPlaybackMilliseconds: Int?
    var ttsUtteranceCount = 0
    var ttsAudioChunkCount = 0
    var audioMetrics: AudioInputMetrics?

    mutating func recordTTSPreparation(from start: Date, to end: Date) {
        ttsPreparationMilliseconds = (ttsPreparationMilliseconds ?? 0) + (milliseconds(from: start, to: end) ?? 0)
    }

    mutating func recordTTSPlayback(from start: Date, to end: Date) {
        ttsPlaybackMilliseconds = (ttsPlaybackMilliseconds ?? 0) + (milliseconds(from: start, to: end) ?? 0)
    }

    mutating func recordTTSUtteranceMetrics(_ metrics: SpeechUtteranceMetrics) {
        ttsUtteranceCount += 1
        ttsAudioChunkCount += metrics.audioChunkCount

        if ttsFirstAudioMilliseconds == nil {
            ttsFirstAudioMilliseconds = metrics.firstAudioMilliseconds
        }
        if let synthesisMilliseconds = metrics.synthesisMilliseconds {
            ttsSynthesisMilliseconds = (ttsSynthesisMilliseconds ?? 0) + synthesisMilliseconds
        }
        if let audioDurationMilliseconds = metrics.audioDurationMilliseconds {
            ttsAudioDurationMilliseconds = (ttsAudioDurationMilliseconds ?? 0) + audioDurationMilliseconds
        }
    }

    func snapshot(outcome: AssistantTurnOutcome, completedAt: Date = Date()) -> AssistantTurnMetrics {
        AssistantTurnMetrics(
            turnID: turnID,
            startedAt: startedAt,
            completedAt: completedAt,
            outcome: outcome,
            directiveType: directiveType,
            totalMilliseconds: milliseconds(from: startedAt, to: completedAt) ?? 0,
            setupMilliseconds: milliseconds(from: startedAt, to: listeningStartedAt),
            recordingMilliseconds: milliseconds(from: listeningStartedAt, to: stopRequestedAt),
            transcriptionMilliseconds: milliseconds(from: stopRequestedAt, to: transcriptReadyAt),
            directiveBrainMilliseconds: milliseconds(from: directiveStartedAt, to: directiveFinishedAt),
            responseBrainMilliseconds: milliseconds(from: responseBrainStartedAt, to: responseBrainFinishedAt),
            actionMilliseconds: milliseconds(from: actionStartedAt, to: actionFinishedAt),
            ttsPreparationMilliseconds: ttsPreparationMilliseconds,
            ttsFirstAudioMilliseconds: ttsFirstAudioMilliseconds,
            ttsSynthesisMilliseconds: ttsSynthesisMilliseconds,
            ttsAudioDurationMilliseconds: ttsAudioDurationMilliseconds,
            ttsPlaybackMilliseconds: ttsPlaybackMilliseconds,
            ttsUtteranceCount: ttsUtteranceCount > 0 ? ttsUtteranceCount : nil,
            ttsAudioChunkCount: ttsAudioChunkCount > 0 ? ttsAudioChunkCount : nil,
            capturedAudioFrameCount: audioMetrics?.capturedFrameCount,
            droppedAudioFrameCount: audioMetrics?.droppedFrameCount
        )
    }

    private func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else {
            return nil
        }
        return max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
