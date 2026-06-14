import Foundation

public enum ProviderKind: String, Codable, Sendable {
    case tts
    case stt
    case brain
    case agent
}

public enum ProviderLocality: String, Codable, Hashable, Sendable {
    case local
    case remote
}

public enum BrainRole: String, Codable, Sendable, CaseIterable {
    case companionRouter
    case generalChat
    case coding
    case writing
    case localPrivate
    case cloudQuality
}

public enum PermissionKind: String, Codable, Sendable {
    case accessibility
    case microphone
    case speechRecognition
}

public enum RocaActivity: Equatable, Sendable {
    case idle
    case readingSelection
    case listening
    case transcribing
    case thinking
    case preparingSpeech
    case speaking
    case interrupted
    case muted
    case offline(reason: String)
    case waitingForPermission(PermissionKind)
}

public enum RocaError: Error, Equatable, Sendable, LocalizedError {
    case permission(PermissionKind)
    case providerUnavailable(ProviderID)
    case providerTimedOut(providerID: ProviderID, modelID: String)
    case assetManifestInvalid(String)
    case assetInstallFailed(String)
    case synthesisFailed(String)
    case playbackFailed(String)
    case selectionUnavailable(String)
    case storageFailed(String)
    case approvalRequired(String)
    case approvalDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .permission(let kind):
            "Missing \(kind.displayName) permission."
        case .providerUnavailable(let id):
            "Provider unavailable: \(id.rawValue)"
        case .providerTimedOut(let providerID, let modelID):
            "Provider timed out: \(providerID.rawValue) \(modelID)"
        case .assetManifestInvalid(let message):
            "Asset manifest invalid: \(message)"
        case .assetInstallFailed(let message):
            "Asset install failed: \(message)"
        case .synthesisFailed(let message):
            "Speech synthesis failed: \(message)"
        case .playbackFailed(let message):
            "Speech playback failed: \(message)"
        case .selectionUnavailable(let message):
            "Selection unavailable: \(message)"
        case .storageFailed(let message):
            "Storage failed: \(message)"
        case .approvalRequired(let message):
            "Approval required: \(message)"
        case .approvalDenied(let message):
            "Approval denied: \(message)"
        case .cancelled:
            "Cancelled."
        }
    }
}

private extension PermissionKind {
    var displayName: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .microphone:
            "microphone"
        case .speechRecognition:
            "Speech Recognition"
        }
    }
}
