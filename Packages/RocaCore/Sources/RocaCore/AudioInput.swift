import Foundation

public protocol AudioInputSession: Sendable {
    var state: AudioInputState { get async }
    var metrics: AudioInputMetrics { get async }

    func start(_ request: AudioInputRequest) async throws -> AsyncThrowingStream<AudioFrame, Error>
    func stop() async
}

public struct AudioInputRequest: Codable, Sendable, Equatable {
    public var mode: STTMode
    public var preferredSampleRate: Int
    public var preferredChannels: Int

    public init(mode: STTMode, preferredSampleRate: Int, preferredChannels: Int) {
        self.mode = mode
        self.preferredSampleRate = preferredSampleRate
        self.preferredChannels = preferredChannels
    }
}

public enum AudioInputState: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case stopped
    case failed(String)
}

public struct AudioInputMetrics: Codable, Equatable, Sendable {
    public var capturedFrameCount: Int
    public var droppedFrameCount: Int
    public var lastSequenceNumber: Int?

    public init(capturedFrameCount: Int = 0, droppedFrameCount: Int = 0, lastSequenceNumber: Int? = nil) {
        self.capturedFrameCount = capturedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.lastSequenceNumber = lastSequenceNumber
    }
}
